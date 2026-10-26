{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Compiles a small package through the worker, one request per module as
-- the rules send them (see compile.bzl's _compile_per_module), and checks
-- what the worker writes for the rules: the interfaces and objects, and
-- the ABI and dep files. Twice: each request in a process of its own (the
-- mode buck2 uses when it runs an action without a worker, in which each
-- compile finds its imports' results on disk), and through one worker
-- over buck2's socket protocol, which is also how the session's state is
-- exercised: results kept, independent modules compiled at once, a module
-- compiled again after an edit.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (bracket, finally)
import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as B8
import Data.IORef
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import qualified Network.HTTP.Types as H
import qualified Network.HTTP2.Client as H2
import Network.Socket
import System.Directory
import System.Environment (getEnvironment, lookupEnv)
import Data.Version (showVersion)
import System.Exit (ExitCode (..), exitFailure)
import System.Info (fullCompilerVersion)
import System.FilePath ((<.>), (</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.Process (getProcessID)
import System.Process

import Proto

main :: IO ()
main = do
  -- The worker on $PATH (build-tool-depends) and the GHC it was built with,
  -- which must be the `ghc` on $PATH too.
  worker <- fromMaybe "ghc-worker" <$> lookupEnv "GHC_WORKER"
  ghc <- fromMaybe "ghc" <$> lookupEnv "GHC"
  version <- trim <$> readProcess ghc ["--numeric-version"] ""
  let built = showVersion fullCompilerVersion
  unless (version == built) $
    die' ("the test was built with GHC " ++ built ++ " but `" ++ ghc ++ "` is " ++ version ++ ": set GHC")
  failures <- newIORef (0 :: Int)
  let check name ok = unless ok $ hPutStrLn stderr ("FAIL: " ++ name) >> modifyIORef' failures (+ 1)
  withPackage $ \dir -> do
    hPutStrLn stderr "one request per process"
    scenarios check (oneShot dir worker ghc) dir ghc
  withPackage $ \dir -> do
    hPutStrLn stderr "one worker, over its socket"
    withWorker dir worker $ \send -> scenarios check send dir ghc
  n <- readIORef failures
  if n == 0 then hPutStrLn stderr "ok" else hPutStrLn stderr (show n ++ " failures") >> exitFailure
  where
    trim = reverse . dropWhile (`elem` ("\r\n" :: String)) . reverse

die' :: String -> IO a
die' msg = hPutStrLn stderr msg >> exitFailure

-- | A request as the rules send it; the exit code and stderr it gets.
type Send = Req -> IO (Int, String)

data Req = Req {node :: String, modPath :: String, boot :: Bool, contractVersion :: String, extraFlags :: [String]}

argv :: FilePath -> String -> Req -> [String]
argv dir ghc r =
  [ "--request", "--contract", contractVersion r
  , "--depfile", dir </> "dep" </> node r <.> "dep", "--abi", abi, "--module", modPath r, "--source", src
  , "--outdir", out, "--hisuf", "hi"
  ] ++ ["--boot" | boot r]
  ++ ["--srcroot=" ++ dir </> "src", "--mkdir=" ++ dir </> "stubs" </> node r]
  ++ ["--", ghc, "-hide-all-packages", "-package", "base"] ++ extraFlags r
  ++ ["--", "-c", src, "-o", o, "-ohi", hi, "-stubdir", dir </> "stubs" </> node r, "-i" ++ out]
  where
    out = dir </> "out"
    suffix = if boot r then "-boot" else ""
    src = dir </> "src" </> modPath r <.> ("hs" ++ suffix)
    hi = out </> modPath r <.> ("hi" ++ suffix)
    o = out </> modPath r <.> ("o" ++ suffix)
    abi = out </> modPath r <.> ("abi" ++ suffix)

req :: String -> String -> Req
req n m = Req n m False "2" []

-- T.C has a boot file; T.D imports it SOURCE and T.C imports T.D (a cycle
-- through the boot); T.B imports both; T.E imports nothing.
withPackage :: (FilePath -> IO a) -> IO a
withPackage k = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("ghc-worker-test-" ++ show pid)
  removePathForcibly dir
  mapM_ (createDirectoryIfMissing True) [dir </> "src/T", dir </> "out", dir </> "dep", dir </> "stubs"]
  writeFile (dir </> "src/T/C.hs-boot") "module T.C where\ndata C\nsize :: C -> Int\n"
  writeFile (dir </> "src/T/D.hs") "module T.D where\nimport {-# SOURCE #-} T.C (C, size)\nnewtype D = D [C]\ndSize :: D -> Int\ndSize (D cs) = sum (map size cs)\n"
  writeFile (dir </> "src/T/C.hs") "module T.C where\nimport T.D (D (..), dSize)\ndata C = Leaf | Node D\nsize :: C -> Int\nsize Leaf = 1\nsize (Node d) = 1 + dSize d\n"
  writeFile (dir </> "src/T/B.hs") "module T.B (total) where\nimport T.C (C (..), size)\nimport T.D (D (..))\ntotal :: Int\ntotal = size (Node (D [Leaf, Leaf]))\n"
  writeFile (dir </> "src/T/E.hs") "module T.E where\ne :: Int\ne = 5\n"
  k dir `finally` removePathForcibly dir

scenarios :: (String -> Bool -> IO ()) -> Send -> FilePath -> String -> IO ()
scenarios check send dir _ghc = do
  let out = dir </> "out"
      compiled r = do
        (code, err) <- send r
        check (node r ++ " compiles: " ++ err) (code == 0)
        let suffix = if boot r then "-boot" else ""
        ok <- and <$> mapM doesFileExist [out </> modPath r <.> ("hi" ++ suffix), out </> modPath r <.> ("o" ++ suffix)]
        check (node r ++ " writes its interface and object") ok
        abi <- readFile (out </> modPath r <.> ("abi" ++ suffix))
        check (node r ++ " writes an ABI hash") (length (filter (/= '\n') abi) == 32)
      depsOf r = lines <$> readFile (dir </> "dep" </> node r <.> "dep")
      lists r files = do
        deps <- depsOf r
        forM_ files $ \f -> check (node r ++ ".dep lists " ++ f ++ ": " ++ show deps) (any (f `isInfixOf`) deps)
        check (node r ++ ".dep lists only the package's own files: " ++ show deps) (all (("out/T/" `isInfixOf`)) deps)

  -- The sequence buck2 would dispatch, with D and E ready at the same time.
  compiled (req "T.C-boot" "T/C"){boot = True}
  done <- newEmptyMVar
  _ <- forkIO (compiled (req "T.E" "T/E") `finally` putMVar done ())
  compiled (req "T.D" "T/D")
  takeMVar done
  compiled (req "T.C" "T/C")
  compiled (req "T.B" "T/B")
  lists (req "T.D" "T/D") ["out/T/C.abi-boot"]
  lists (req "T.C" "T/C") ["out/T/D.abi", "out/T/C.abi-boot"]
  lists (req "T.B" "T/B") ["out/T/C.abi", "out/T/D.abi"]
  eDeps <- depsOf (req "T.E" "T/E")
  check "T.E.dep is empty" (null eDeps)

  -- An edit that changes nothing downstream: the same ABI, the same object.
  abi <- readFile (out </> "T/C.abi")
  obj <- B.readFile (out </> "T/C.o")
  appendFile (dir </> "src/T/C.hs") "\n-- an edit\n"
  compiled (req "T.C" "T/C")
  abi' <- readFile (out </> "T/C.abi")
  check "a comment-only edit leaves the ABI" (abi == abi')
#if MIN_VERSION_GLASGOW_HASKELL(9,12,0,0)
  obj' <- B.readFile (out </> "T/C.o")
  check "a comment-only edit leaves the object" (obj == obj')
#else
  pure (obj `seq` ())
#endif

  -- An edit that changes the ABI.
  appendFile (dir </> "src/T/C.hs") "\nanother :: Int\nanother = 2\n"
  compiled (req "T.C" "T/C")
  abi'' <- readFile (out </> "T/C.abi")
  check "an exported binding changes the ABI" (abi /= abi'')
  compiled (req "T.B" "T/B")

  -- A module whose request has other flags (as a Template Haskell module's
  -- package flags differ from the rest of its target's): compiled in a
  -- session of its own, which reads its imports, compiled in the other,
  -- from disk.
  compiled (req "T.B" "T/B"){extraFlags = ["-DOTHER_FLAGS"]}
  lists (req "T.B" "T/B") ["out/T/C.abi", "out/T/D.abi"]

  -- A Template Haskell module whose splice runs a module of the package,
  -- in a session of its own too: the splice loads the object of the
  -- module, which the session read from disk. GHC, being dynamically
  -- linked, loads dynamic objects.
  let th = ["-dynamic", "-package", "template-haskell"]
  writeFile (dir </> "src/T/G.hs") "{-# LANGUAGE TemplateHaskellQuotes #-}\nmodule T.G (g) where\nimport Language.Haskell.TH (Exp, Q)\ng :: Q Exp\ng = [| 3 :: Int |]\n"
  writeFile (dir </> "src/T/H.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.H (h) where\nimport T.G (g)\nh :: Int\nh = $(g)\n"
  compiled (req "T.G" "T/G"){extraFlags = th}
  compiled (req "T.H" "T/H"){extraFlags = th ++ ["-DOTHER_FLAGS"]}

  -- An edit to the boot file, then everything that reads it, in order.
  appendFile (dir </> "src/T/C.hs-boot") "\n-- an edit\n"
  compiled (req "T.C-boot" "T/C"){boot = True}
  compiled (req "T.D" "T/D")
  compiled (req "T.C" "T/C")
  compiled (req "T.B" "T/B")

  -- A package-qualified import of a module whose name a home module has
  -- too: the package's, not the home module, which isn't compiled.
  createDirectoryIfMissing True (dir </> "src/Data")
  writeFile (dir </> "src/Data/Bool.hs") "module Data.Bool where\n"
  writeFile (dir </> "src/T/I.hs") "{-# LANGUAGE PackageImports #-}\nmodule T.I where\nimport \"base\" Data.Bool (bool)\ni :: Int\ni = bool 1 2 True\n"
  compiled (req "T.I" "T/I")

  -- A module that doesn't compile: its errors, at their source.
  writeFile (dir </> "src/T/F.hs") "module T.F where\nf :: Int\nf = \"no\"\n"
  (code, err) <- send (req "T.F" "T/F")
  check ("T.F fails: " ++ show code) (code /= 0)
  check ("T.F's error names its source and the problem: " ++ err) ("T/F.hs:3:5" `isInfixOf` err && "String" `isInfixOf` err)

  -- A request of another version of the rules.
  (code', err') <- send (req "T.E" "T/E"){contractVersion = "0"}
  check ("a contract mismatch is refused: " ++ show code' ++ " " ++ err') (code' /= 0 && "version" `isInfixOf` err')

-- | Each request as a process of the worker, without a socket.
oneShot :: FilePath -> FilePath -> String -> Send
oneShot dir worker ghc r = do
  (code, _, err) <- readProcessWithExitCode worker (argv dir ghc r) ""
  pure (either id (const 0) (case code of ExitSuccess -> Right (); ExitFailure n -> Left n), err)

-- | One worker started as buck2 starts it, each request a call of
-- /worker.Worker/Execute on its socket (on a connection of its own, as
-- buck2 doesn't, but the server treats connections alike), ended with
-- SIGTERM as buck2 ends it, which it must take quietly.
withWorker :: FilePath -> FilePath -> (Send -> IO a) -> IO a
withWorker dir worker k = do
  let sock = dir </> "w.sock"
  ghc <- fromMaybe "ghc" <$> lookupEnv "GHC"
  bracket
    (do
      environment <- getEnvironment
      (_, _, _, ph) <- createProcess (proc worker []){env = Just (("WORKER_SOCKET", sock) : filter ((/= "WORKER_SOCKET") . fst) environment)}
      pure ph)
    (\ph -> do
      terminateProcess ph
      code <- waitForProcess ph
      when (code /= ExitSuccess) $ hPutStrLn stderr ("FAIL: the worker exited with " ++ show code ++ " on SIGTERM") >> exitFailure)
    $ \_ -> do
      waitFor sock (50 :: Int)
      withEnvPath $ k (grpc sock . argv dir ghc)
  where
    waitFor sock n = do
      ok <- doesFileExist sock
      unless ok $ if n == 0 then die' "the worker opened no socket" else threadDelay 100000 >> waitFor sock (n - 1)
    withEnvPath = id

grpc :: FilePath -> [String] -> IO (Int, String)
grpc path args = do
  sock <- socket AF_UNIX Stream defaultProtocol
  connect sock (SockAddrUnix path)
  conf <- H2.allocSimpleConfig sock 4096
  (code, err) <- H2.run H2.defaultClientConfig conf client `finally` (H2.freeSimpleConfig conf >> close sock)
  pure (code, B8.unpack err)
  where
    payload = encodeExecuteCommand (map B8.pack args)
    frame = BB.word8 0 <> BB.word32BE (fromIntegral (B.length payload)) <> BB.byteString payload
    client :: H2.Client (Int, ByteString)
    client sendRequest _ = sendRequest (H2.requestBuilder H.methodPost "/worker.Worker/Execute" [("content-type", "application/grpc"), ("te", "trailers")] frame) $ \rsp -> do
      body <- readAll rsp []
      pure (decodeExecuteResponse (B.drop 5 body))
    readAll rsp acc = do
      chunk <- H2.getResponseBodyChunk rsp
      if B.null chunk then pure (B.concat (reverse acc)) else readAll rsp (chunk : acc)
