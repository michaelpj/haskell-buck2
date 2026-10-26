{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | GHC sessions, one per set of flags, in which each request compiles its
-- module with GHC's own per-module compile (what `--make -j` runs for each
-- module), concurrently with the others, and writes the module's ABI hash
-- and buck2 dep file from the interface it produced. See Note [The
-- session's state].
module Session (Request (..), parseRequest, Pool, startWorker, compileRequest) where

import Control.Concurrent.MVar
import Control.Exception (SomeException, fromException, try)
import Control.Monad (filterM, forM, forM_, unless, when)
import Data.IORef
import Data.List (isPrefixOf, isSuffixOf, stripPrefix)
import qualified Data.Map as M
import Data.Maybe (isJust)
import qualified Data.Set as Set
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (makeRelative, takeDirectory, (<.>), (</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcess)

import GHC
import GHC.Clock (getMonotonicTime)
import GHC.Data.FastString (unpackFS)
import GHC.Driver.Env (hsc_HPT, hsc_NC, hsc_dflags, hsc_home_unit, hsc_logger)
import GHC.Driver.Errors.Types (GhcMessage (..))
import GHC.Driver.Main (initModDetails)
import GHC.Driver.Make (summariseFile)
import GHC.Driver.Monad (Ghc (..), Session (..))
import Control.Monad.IO.Class (liftIO)
import GHC.Driver.Pipeline (compileOne)
import GHC.Driver.Session (targetProfile)
import GHC.Iface.Binary (CheckHiWay (..), TraceBinIFace (..), readBinIface)

import GHC.Types.Error (MessageClass (..))
import GHC.Types.SourceError (SourceError, throwErrors)
import GHC.Types.SourceFile (HscSource (..))
import GHC.Types.SrcLoc (srcSpanFileName_maybe)
#if MIN_VERSION_ghc(9,14,0)
import Data.Maybe (fromMaybe)
import GHC.Types.Error (mkUnknownDiagnostic)
import GHC.Unit.Home.PackageTable (addHomeModInfoToHpt, lookupHpt)
#else
import GHC.Driver.Env (hscUpdateHPT)
import GHC.Unit.Home.ModInfo (addToHpt, lookupHpt)
#endif
import GHC.Unit.Finder (FindResult (..), findImportedModule, findObjectLinkableMaybe)
import GHC.Unit.Home (homeUnitId, isHomeModule)
import GHC.Unit.Home.ModInfo (HomeModInfo (..), emptyHomeModInfoLinkable, homeModInfoByteCode, homeModInfoObject, justObjects)
import GHC.Unit.Module.Deps (Usage (..), dep_direct_mods)
import GHC.Unit.Module.Location (addBootSuffixLocn, addBootSuffixLocnOut)
import GHC.Unit.Module.ModIface
import GHC.Unit.Types (GenWithIsBoot (..))
import GHC.Utils.Fingerprint (Fingerprint)
import GHC.Utils.Logger (LogFlags (..))
import GHC.Utils.Outputable (renderWithContext)

-- | One module to compile, as the rules describe it in the action's
-- arguments (see Note [The persistent worker] in compile.bzl):
--
-- > --request --contract V --depfile DEP --abi ABI --module Foo/Bar
-- >   --source Foo/Bar.hs --outdir OUT --hisuf SUF [--boot] [--ldtree TREES]
-- >   --hidir=DIR... --srcroot=SRCS --mkdir=DIR...
-- >   -- ghc SESSION_FLAGS... -- -c Foo/Bar.hs -o ... -ohi ...
--
-- The compile's flags come in two parts: those of the module's session, and
-- the module's own, which the worker ignores but for @-hiedir@, compiling
-- the module to the session's output directory instead.
data Request = Request
  { reqDepfile :: FilePath
  , reqAbi :: FilePath
  , reqModPath :: String -- Foo/Bar
  , reqSource :: FilePath
  , reqOutDir :: FilePath -- where every module's outputs are
  , reqHisuf :: String
  , reqHidirs :: [FilePath] -- the dependencies' interface (and .abi) dirs
  , reqSrcRoots :: [FilePath] -- the tree of the target's sources, where imports are found
  , reqMkdirs :: [FilePath] -- output directories to create first
  , reqBoot :: Bool
  , reqLdTree :: Maybe FilePath -- the trees of the dependencies' shared libraries, as LD_LIBRARY_PATH
  , reqCompiler :: String
  , reqSessionArgs :: [String] -- the flags of every module of the session
  , reqModuleArgs :: [String] -- the module's own: `ghc -c`'s source and outputs
  }

-- | The version of the request and of what the worker writes back, which
-- the rules name in each request (_WORKER_CONTRACT in compile.bzl): a
-- worker installed for another version of the rules says so rather than
-- misreading the request.
contract :: String
contract = "2"

-- | The request in an action's command line, which buck2 sends whole: the
-- program and its own arguments come before the "--request" marker.
parseRequest :: [String] -> Either String Request
parseRequest args = case drop 1 (dropWhile (/= "--request") args) of
  "--contract" : v : rest
    | v == contract -> go (Request "" "" "" "" "" "" [] [] [] False Nothing "" [] []) rest
    | otherwise -> Left ("ghc-worker: this worker is for version " ++ contract ++ " of the rules' requests, the rules send version " ++ v ++ ": install the worker from the rules' own tools/ghc-worker")
  _ -> Left "ghc-worker: the request names no contract version: install the worker from the rules' own tools/ghc-worker"
  where
    go r ("--depfile" : v : rest) = go r{reqDepfile = v} rest
    go r ("--abi" : v : rest) = go r{reqAbi = v} rest
    go r ("--module" : v : rest) = go r{reqModPath = v} rest
    go r ("--source" : v : rest) = go r{reqSource = v} rest
    go r ("--outdir" : v : rest) = go r{reqOutDir = v} rest
    go r ("--hisuf" : v : rest) = go r{reqHisuf = v} rest
    go r ("--boot" : rest) = go r{reqBoot = True} rest
    go r ("--ldtree" : v : rest) = go r{reqLdTree = Just v} rest
    go r ("--" : compiler : rest) =
      let (session, moduleArgs) = break (== "--") rest
       in Right r{reqCompiler = compiler, reqSessionArgs = session, reqModuleArgs = drop 1 moduleArgs}
    go r (x : rest)
      | Just v <- stripPrefix "--hidir=" x = go r{reqHidirs = reqHidirs r ++ [v]} rest
      | Just v <- stripPrefix "--srcroot=" x = go r{reqSrcRoots = reqSrcRoots r ++ [v]} rest
      | Just v <- stripPrefix "--mkdir=" x = go r{reqMkdirs = reqMkdirs r ++ [v]} rest
      | otherwise = Left ("ghc-worker: unexpected request argument " ++ show x)
    go _ [] = Left "ghc-worker: request has no compiler command"

-- | The flags of the request's session: its compile's but the module's own
-- (whose outputs go to -odir/-hidir by module name, which is where the
-- rules put them anyway), and the target's sources on the import path.
-- Object code is made deterministic (GHC 9.12 and later can): GHC's uniques
-- otherwise depend on what the session compiled before, so a module's
-- object would differ from one compile to the next, and buck2 would link
-- the library again after every edit.
sessionFlags :: Request -> [String]
sessionFlags r =
  reqSessionArgs r
    ++ ["-odir", reqOutDir r, "-hidir", reqOutDir r]
#if MIN_VERSION_ghc(9,12,0)
    ++ ["-fobject-determinism"]
#endif
    ++ ["-i" ++ d | d <- reqSrcRoots r]

-- | The worker's sessions, one per set of flags: a target's modules mostly
-- share one, but those that run Template Haskell compile against other
-- package dbs (see Note [Libraries of the early package dbs] in the rules'
-- compile.bzl). A session is made when the first request with its flags
-- comes, and each keeps its own interfaces and home package table.
data Pool = Pool
  { pLibdir :: FilePath
  , pSessions :: MVar (M.Map [String] (MVar Worker))
  , pDiagnostics :: MVar Diagnostics
  , pVerbose :: Bool
  }

-- | GHC's diagnostics, numbered as they come, and the requests being
-- compiled, by the number of the last diagnostic before they started: a
-- request's are those after that, which name its source (or no source, if
-- it fails). A diagnostic is kept only while a request that may want it is
-- being compiled.
data Diagnostics = Diagnostics
  { dSeq :: Int
  , dMessages :: [(Int, Maybe FilePath, Bool, String)] -- newest first: number, source file, is an error, text
  , dInFlight :: M.Map Int Int -- start number -> requests
  }

-- | One GHC session.
data Worker = Worker
  { wSession :: IORef HscEnv -- GHC's own
  , wLock :: MVar () -- held to change the session's home package table
  }

-- | Run the worker with the GHC of the first request. GHC's signal handlers
-- are those of the session `runGhc` makes; the sessions that compile are
-- made on demand, each with the logger that collects the diagnostics, by
-- source file.
startWorker :: Request -> (Pool -> IO a) -> IO a
startWorker first k = do
  libdir <- trim <$> readProcess (reqCompiler first) ["--print-libdir"] ""
  sessions <- newMVar M.empty
  diagnostics <- newMVar (Diagnostics 0 [] M.empty)
  verbose <- isJust <$> lookupEnv "GHC_WORKER_VERBOSE"
  runGhc (Just libdir) (liftIO (k (Pool libdir sessions diagnostics verbose)))
  where
    trim = reverse . dropWhile (`elem` "\r\n") . reverse

-- | The session for a request's flags, made if there is none yet.
sessionFor :: Pool -> Request -> IO Worker
sessionFor p r = do
  let flags = sessionFlags r
  (var, fresh) <- modifyMVar (pSessions p) $ \m -> case M.lookup flags m of
    Just v -> pure (m, (v, False))
    Nothing -> do
      v <- newEmptyMVar
      pure (M.insert flags v m, (v, True))
  when fresh $ do
    when (pVerbose p) $ hPutStrLn stderr ("ghc-worker: a session for the flags of " ++ reqModPath r)
    newSession p r >>= putMVar var
  readMVar var

newSession :: Pool -> Request -> IO Worker
newSession p r = do
  ref <- newIORef (error "ghc-worker: the session isn't made yet")
  let session = Session ref
  unGhc (initGhcMonad (Just (pLibdir p))) session
  dflags0 <- unGhc getSessionDynFlags session
  unGhc (modifyLogger (pushLogHook (\_ lf cls sp doc -> record lf cls sp doc))) session
  logger <- hsc_logger <$> readIORef ref
  (dflags, _, _) <- parseDynamicFlags logger dflags0 (map noLoc (sessionFlags r))
  unGhc (setSessionDynFlags dflags >> pure ()) session
  -- The module graph of the target: GHC's own dependency analysis over the
  -- source tree (its errors are the failing modules' own compiles' to
  -- report). See Note [The session's state].
  srcs <- concat <$> mapM sources (reqSrcRoots r)
  unGhc (do
    hsc <- getSession
    targets <- mapM (\f -> guessTarget f (Just (homeUnitId (hsc_home_unit hsc))) Nothing) srcs
    setTargets targets
#if MIN_VERSION_ghc(9,14,0)
    _ <- depanalE mkUnknownDiagnostic Nothing [] True
#else
    _ <- depanalE [] True
#endif
    pure ()) session
  Worker ref <$> newMVar ()
  where
    record lf cls sp doc = do
      let isError = case cls of
            MCDiagnostic SevError _ _ -> True
            MCFatal -> True
            _ -> False
          file = unpackFS <$> srcSpanFileName_maybe sp
          text = renderWithContext (log_default_user_context lf) doc
      modifyMVar_ (pDiagnostics p) $ \d ->
        pure d{dSeq = dSeq d + 1, dMessages = (dSeq d + 1, file, isError, text) : dMessages d}
    sources dir = do
      entries <- listDirectory dir
      fmap concat . forM entries $ \e -> do
        let path = dir </> e
        isDir <- doesDirectoryExist path
        if isDir then sources path
        else pure [path | ".hs" `isSuffixOf` e || ".hs-boot" `isSuffixOf` e || ".lhs" `isSuffixOf` e]

-- | Compile a request's module in the session for its flags; the exit code
-- and the diagnostics of the module.
compileRequest :: Pool -> Request -> IO (Int, String)
compileRequest p r = do
  n0 <- modifyMVar (pDiagnostics p) $ \d ->
    pure (d{dInFlight = M.insertWith (+) (dSeq d) 1 (dInFlight d)}, dSeq d)
  t0 <- getMonotonicTime
  result <- try (sessionFor p r >>= \w -> compile w r)
  t1 <- getMonotonicTime
  msgs <- modifyMVar (pDiagnostics p) $ \d -> do
    let inFlight = M.update (\c -> if c > 1 then Just (c - 1) else Nothing) n0 (dInFlight d)
        kept = case M.lookupMin inFlight of
          Just (oldest, _) -> takeWhile (\(n, _, _, _) -> n > oldest) (dMessages d)
          Nothing -> []
    pure (d{dMessages = kept, dInFlight = inFlight}, reverse (takeWhile (\(n, _, _, _) -> n > n0) (dMessages d)))
  let src = reqSource r
      mine = [t | (_, f, _, t) <- msgs, maybe False (matches src) f]
      bad = or [e | (_, f, e, _) <- msgs, maybe False (matches src) f]
      unattributed = [t | (_, Nothing, True, t) <- msgs]
  when (pVerbose p) $ hPutStrLn stderr ("ghc-worker: " ++ reqModPath r ++ " " ++ show (round ((t1 - t0) * 1000) :: Int) ++ "ms")
  pure $ case result of
    Right () | not bad -> (0, unlines mine)
    Right () -> (1, unlines (mine ++ unattributed))
    -- A compile's errors come as the exception (GHC's --make driver logs
    -- them itself, after the compile), as do the driver's in summarising
    -- the source; warnings were logged and are attributed above.
    Left e -> case fromException e :: Maybe SourceError of
      Just se -> (1, unlines (mine ++ unattributed ++ [show se]))
      Nothing -> (1, unlines (mine ++ unattributed ++ ["ghc-worker: " ++ show e]))
  where
    matches src f = f == src || ("/" ++ src) `isSuffixOf` f || ("/" ++ f) `isSuffixOf` src

compile :: Worker -> Request -> IO ()
compile w r = do
  mapM_ (createDirectoryIfMissing True) (reqMkdirs r)
  hsc0 <- readIORef (wSession w)
  ems <- summariseFile hsc0 (hsc_home_unit hsc0) M.empty (reqSource r) Nothing Nothing
  ms1 <- either (throwErrors . fmap GhcDriverMessage) pure ems
  -- A boot file by its name (GHC before 9.12 summarises it as a module).
  let ms0
        | reqBoot r && ms_hsc_src ms1 /= HsBootFile = ms1{ms_hsc_src = HsBootFile, ms_location = addBootSuffixLocnOut (ms_location ms1)}
        | otherwise = ms1
  -- The request's own output directory for the .hie file (the session's
  -- flags have none, and GHC would put it next to the source).
  ms <- case dropWhile (/= "-hiedir") (reqModuleArgs r) of
    _ : dir : _ -> do
      let file = dir </> reqModPath r <.> (if reqBoot r then "hie-boot" else "hie")
      createDirectoryIfMissing True (takeDirectory file)
      pure ms0{ms_location = (ms_location ms0){ml_hie_file = file}}
    _ -> pure ms0
  -- The home modules the compile needs in the session: the imports (and
  -- what they import), and the module's own boot interface if it has one,
  -- which GHC in this mode looks for there, not on disk.
  forM_ (ms_srcimps ms) $ \imp -> ensureHome w (srcImportName imp) NoPkgQual IsBoot
  forM_ (ms_textual_imps ms) $ \imp -> uncurry (ensureHome w) (importName imp) NotBoot
  unless (reqBoot r) $ do
    let bootLoc = addBootSuffixLocn (ms_location ms)
    hasBoot <- doesFileExist (ml_hi_file bootLoc)
    when hasBoot $ do
      hsc <- readIORef (wSession w)
      entry <- lookupHome hsc (ms_mod_name ms)
      case entry of
        Just hmi | mi_boot (hm_iface hmi) == IsBoot -> pure ()
        _ -> loadHome w (ms_mod ms) bootLoc True
  hsc <- readIORef (wSession w)
  -- As `ghc -c` would: against the interface and object of the last
  -- compile, which GHC may find to be up to date.
  old <- either (\(_ :: SomeException) -> Nothing) Just <$> try (readIface hsc (ml_hi_file (ms_location ms)))
  oldObj <- findObjectLinkableMaybe (ms_mod ms) (ms_location ms)
  hmi <- compileOne hsc ms 1 1 old (maybe emptyHomeModInfoLinkable justObjects oldObj)
  addHome w (ms_mod_name ms) hmi True
  writeDepFiles r (hm_iface hmi)

-- | Have the home module in the session's home package table, as its boot
-- interface or the whole module: compiled here already, else read from
-- its interface and object on disk, with its own dependencies first. An
-- import that names another package (PackageImports) is no home module's,
-- though a home module may have its name.
ensureHome :: Worker -> ModuleName -> PkgQual -> IsBootInterface -> IO ()
ensureHome w mn pkg boot = do
  hsc <- readIORef (wSession w)
  entry <- lookupHome hsc mn
  case entry of
    Just hmi | hasCode hmi, boot == IsBoot || mi_boot (hm_iface hmi) == NotBoot -> pure ()
    _ -> do
      found <- findImportedModule hsc mn pkg
      case found of
        Found loc m | isHomeModule (hsc_home_unit hsc) m ->
          loadHome w m (if boot == IsBoot then addBootSuffixLocn loc else loc) False
        _ -> pure () -- a package module, or not found: the compile reports it

loadHome :: Worker -> Module -> ModLocation -> Bool -> IO ()
loadHome w m loc replace = do
  hsc0 <- readIORef (wSession w)
  iface <- readIface hsc0 (ml_hi_file loc)
  let home = homeUnitId (hsc_home_unit hsc0)
  forM_ (Set.toList (dep_direct_mods (mi_deps iface))) $ \d -> case directDep d of
    (uid, GWIB dep b) -> when (uid == home) (ensureHome w dep NoPkgQual b)
  -- The details are typechecked lazily, in the session as it is now:
  -- with the dependencies.
  hsc <- readIORef (wSession w)
  details <- initModDetails hsc iface
  obj <- findObjectLinkableMaybe m loc
  addHome w (moduleName m) (HomeModInfo iface details (maybe emptyHomeModInfoLinkable justObjects obj)) replace

-- Add to the home package table, under the lock: a compile's result
-- replaces what is there (a boot interface, or the module's last
-- compile); a module read from disk doesn't replace a whole module with
-- its boot interface.
addHome :: Worker -> ModuleName -> HomeModInfo -> Bool -> IO ()
addHome w mn hmi replace = withMVar (wLock w) $ \_ -> do
  hsc <- readIORef (wSession w)
  entry <- lookupHome hsc mn
  case entry of
    Just old | not replace, hasCode old, mi_boot (hm_iface old) == NotBoot || mi_boot (hm_iface hmi) == IsBoot -> pure ()
    _ -> insertHome hsc mn hmi >>= writeIORef (wSession w)

-- Whether an entry of the home package table has the module's code, which
-- a splice that runs it loads. Since GHC 9.14, whose table is mutable,
-- initModDetails puts the module it is given in the table without code
-- (to tie the knot of its typechecking), where loadHome then puts it with
-- its object: such an entry is one being loaded, not one to keep.
hasCode :: HomeModInfo -> Bool
hasCode hmi = isJust (homeModInfoObject hmi) || isJust (homeModInfoByteCode hmi)

-- A summary's import (with the package it names, if any) and an
-- interface's direct dependency, which carry an import level since GHC 9.14.
#if MIN_VERSION_ghc(9,14,0)
importName :: (a, PkgQual, Located ModuleName) -> (ModuleName, PkgQual)
importName (_, pkg, L _ mn) = (mn, pkg)
srcImportName :: Located ModuleName -> ModuleName
srcImportName (L _ mn) = mn
directDep :: (a, b, c) -> (b, c)
directDep (_, uid, m) = (uid, m)
#else
importName :: (PkgQual, Located ModuleName) -> (ModuleName, PkgQual)
importName (pkg, L _ mn) = (mn, pkg)
srcImportName :: (a, Located ModuleName) -> ModuleName
srcImportName (_, L _ mn) = mn
directDep :: (b, c) -> (b, c)
directDep = id
#endif

-- The interface's ABI hash and usages, where each GHC keeps them.
abiHash :: ModIface -> Fingerprint
usages :: ModIface -> [Usage]
#if MIN_VERSION_ghc(9,14,0)
abiHash = mi_mod_hash
usages = fromMaybe [] . mi_usages
#else
abiHash = mi_mod_hash . mi_final_exts
usages = mi_usages
#endif

-- The home package table: a value in the session before GHC 9.14, a
-- mutable table in it since.
lookupHome :: HscEnv -> ModuleName -> IO (Maybe HomeModInfo)
insertHome :: HscEnv -> ModuleName -> HomeModInfo -> IO HscEnv
#if MIN_VERSION_ghc(9,14,0)
lookupHome hsc = lookupHpt (hsc_HPT hsc)
insertHome hsc _ hmi = addHomeModInfoToHpt hmi (hsc_HPT hsc) >> pure hsc
#else
lookupHome hsc mn = pure (lookupHpt (hsc_HPT hsc) mn)
insertHome hsc mn hmi = pure (hscUpdateHPT (\hpt -> addToHpt hpt mn hmi) hsc)
#endif

readIface :: HscEnv -> FilePath -> IO ModIface
readIface hsc = readBinIface (targetProfile (hsc_dflags hsc)) (hsc_NC hsc) IgnoreHiWay QuietBinIFace

-- | The ABI file and dep file of a compiled module, from its interface: the
-- ABI hash, and the usages GHC recorded (what its own recompilation check
-- reads): imports as their .abi files, and the files a splice loaded.
writeDepFiles :: Request -> ModIface -> IO ()
writeDepFiles r iface = do
  writeFile (reqAbi r) (show (abiHash iface :: Fingerprint) ++ "\n")
  cwd <- getCurrentDirectory
  entries <- fmap concat . forM (usages iface) $ \u -> case u of
    UsageHomeModule{usg_mod_name = m} -> existing [reqOutDir r </> modFile m <.> "abi", reqOutDir r </> modFile m <.> "abi-boot"]
    UsageHomeModuleInterface{usg_mod_name = m} -> existing [reqOutDir r </> modFile m <.> "abi"]
    UsagePackageModule{usg_mod = m} -> firstExisting (concat [[d </> modFile (moduleName m) <.> "abi", d </> modFile (moduleName m) <.> reqHisuf r] | d <- reqHidirs r])
    UsageFile{usg_file_path = p} -> do
#if MIN_VERSION_ghc(9,8,0)
      let path = unpackFS p
#else
      let path = p
#endif
      ok <- doesFileExist path
      if ok then (\c -> [c | isUnder cwd c]) <$> canonicalizePath path else pure []
    UsageMergedRequirement{} -> pure []
  self <- existing [reqOutDir r </> reqModPath r <.> "abi-boot"]
  rel <- mapM (fmap (makeRelative cwd) . canonicalizePath) (entries ++ self)
  writeFile (reqDepfile r) (unlines rel)
  where
    modFile = map (\c -> if c == '.' then '/' else c) . moduleNameString
    existing = filterM doesFileExist
    firstExisting = fmap (take 1) . existing
    isUnder cwd p = (cwd ++ "/") `isPrefixOf` p

{- Note [The session's state]

The session is in GHC's --make mode, in which GHC expects the home modules
a compile imports to be in the session's home package table, and finds
their instances (and, for Template Haskell, their objects) through the
session's module graph. So the worker keeps both: the table gets each
compile's result, and the modules a compile needs that this process didn't
compile, read from their interfaces on disk; the graph is GHC's dependency
analysis of the whole target, done once from its source tree (as `ghc -M`
does in the rules), and only consulted for which modules are below which.

GHC's one-shot mode (that of `ghc -c`) would need neither, reading home
interfaces into its cache of external interfaces instead, but that cache
has no notion of a module's boot interface being superseded by the module:
once a `{-# SOURCE #-}` import has put the boot interface there, the
module's own compile sees the boot's instances as another module's, and
a later import may be served the boot interface in place of the module.
-}
