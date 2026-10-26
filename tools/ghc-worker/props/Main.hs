{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Property tests of the worker against a plain `ghc -c`: generated
-- histories of a small package, built again and again through the worker as
-- buck2 would build it, each time compared with a clean one-shot build of
-- the same sources.
--
-- A history is a package (modules M0..Mn, each importing some of those
-- before it, some with a boot file that modules before them import
-- {-# SOURCE #-}, some with a Template Haskell splice that runs a module it
-- imports), perhaps a package p it depends on (modules P0..Pk, which its
-- modules import through p's early package db, as the rules have it: no
-- library, its import directory the one p's interfaces are written to one by
-- one), and a sequence of builds, with edits to the sources before each.
-- Each build has a fresh worker, as each buck2 build does, and sends it the
-- modules and boot files buck2 would compile: those never compiled, or
-- whose source or a file their dep file lists changed since they last
-- compiled (the early cut-off of Note [Early cut-off by dep files] in
-- compile.bzl), each once what it imports is done, independent ones at the
-- same time; one whose import failed isn't sent. After each build, every
-- module and boot file must agree with the clean build: whether it
-- compiles, and its ABI hash, and its object with GHC 9.12 and later, whose
-- objects are deterministic.
--
-- The worker and GHC are as in the test suite (GHC_WORKER, GHC). The
-- options are tasty's: --hedgehog-tests N runs N histories (30 by default),
-- and a failure says how to run it again (--hedgehog-replay).
module Main (main) where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, catch, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as B
import Data.IORef
import Data.List (intercalate, sort, sortOn)
import qualified Data.Map as M
import Data.Maybe (fromMaybe, isJust)
import Data.Version (showVersion, versionBranch)
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((<.>), (</>))
import System.Info (fullCompilerVersion)
import System.IO (IOMode (..), hPutStrLn, openFile, stderr)
import System.Timeout (timeout)
import System.Posix.Process (getProcessID)
import System.Process

import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (adjustOption, askOption, defaultMain, testGroup)
import Test.Tasty.Hedgehog (HedgehogTestLimit (..), testPropertyNamed)

import Client
import Contract (contract)

-- * Histories

data Ty = TInt | TInteger
  deriving (Eq, Show)

-- | A module:
--
-- - the modules it imports (qualified): of its own package, those before
--   it; of p (whose keys are 100 and up), any, from a module of the main
--   package;
-- - those it imports {-# SOURCE #-}, which come after it and have a boot
--   file;
-- - its exported values: name number, type, and the constant in its
--   definition (value 0 adds the value 0 of each import, and the value t
--   of each that has one; a value t, INLINE, the value 0 of each SOURCE
--   import), and for each SOURCE import a function that shows the
--   import's type T;
-- - whether it has a boot file, which declares its value 0 and its type T
--   with a Show instance;
-- - the import whose value 0 a Template Haskell splice of it links (without
--   evaluating it: the values may form a cycle, through SOURCE imports),
--   if any;
-- - the numbers of comment-only edits made to it and to its boot file;
-- - whether it has a type error;
-- - whether its requests have flags of their own (as a Template Haskell
--   module's package flags differ), so that it compiles in a session of
--   its own.
data Mod = Mod
  { mImports :: [Int]
  , mSourceImports :: [Int]
  , mValues :: [(Int, Ty, Int)]
  , mBoot :: Bool
  , mSplice :: Maybe Int
  , mComments :: Int
  , mBootComments :: Int
  , mBroken :: Bool
  , mOwnFlags :: Bool
  }
  deriving (Eq, Show)

data Edit
  = Comment Int
  | BootComment Int
  | Body Int Int Int -- module, value, new constant
  | AddValue Int
  | RemoveValue Int
  | Retype Int -- value 0, which the boot file declares too
  | AddImport Int Int
  | RemoveImport Int Int
  | AddSourceImport Int Int
  | RemoveSourceImport Int Int
  | Break Int -- or mend
  deriving (Show)

-- | A build: the edits before it, and whether its worker drops sessions as
-- soon as they are idle.
data Build = Build {bEdits :: [Edit], bEagerDrop :: Bool}
  deriving (Show)

-- | Whether it optimises, the modules by key (the main package's from 0,
-- p's from pkgP), and the builds.
data History = History {hOptimise :: Bool, hModules :: [(Int, Mod)], hBuilds :: [Build]}
  deriving (Show)

-- | A history, with boot files if allowed.
genHistory :: Bool -> Gen History
genHistory bootsAllowed = do
  -- Constant ranges: Hedgehog scales linear ones with its size, which
  -- stays small over a few dozen tests, and the histories need builds and
  -- edits to be worth running.
  n <- Gen.int (Range.constant 2 6)
  pn <- Gen.frequency [(1, pure 0), (2, Gen.int (Range.constant 1 3))]
  pmods <- forM [0 .. pn - 1] $ \i -> do
    imports <- Gen.subsequence [pkgP + j | j <- [0 .. i - 1]]
    k <- Gen.int (Range.constant 1 3)
    values <- forM [0 .. k - 1] $ \v -> (,,) v <$> Gen.element [TInt, TInteger] <*> Gen.int (Range.linear 0 9)
    pure (Mod imports [] values False Nothing 0 0 False False)
  boots <- forM [0 .. n - 1] $ \i -> if i == 0 || not bootsAllowed then pure False else Gen.frequency [(2, pure False), (1, pure True)]
  mods <- forM [0 .. n - 1] $ \i -> do
    own' <- if i == 0 then pure [] else Gen.subsequence [0 .. i - 1]
    fromP <- Gen.subsequence [pkgP + j | j <- [0 .. pn - 1]]
    let imports = own' ++ fromP
    sourceImports <- Gen.subsequence [j | j <- [i + 1 .. n - 1], boots !! j]
    k <- Gen.int (Range.constant 1 3)
    values <- forM [0 .. k - 1] $ \v -> (,,) v <$> Gen.element [TInt, TInteger] <*> Gen.int (Range.linear 0 9)
    -- A splice can't run p's code: its early db names no library.
    splice <- if null own' then pure Nothing else Gen.frequency [(3, pure Nothing), (1, Just <$> Gen.element own')]
    own <- Gen.frequency [(2, pure False), (1, pure True)]
    pure (Mod imports sourceImports values (boots !! i) splice 0 0 False own)
  builds <- Gen.list (Range.constant 2 6) (Build <$> Gen.list (Range.constant 1 4) (genEdit (n, pn)) <*> Gen.bool)
  History <$> Gen.bool <*> pure (zip [0 ..] mods ++ zip [pkgP ..] pmods) <*> pure builds

-- | The key of p's first module: those of the main package come before.
pkgP :: Int
pkgP = 100

inP :: Int -> Bool
inP i = i >= pkgP

genEdit :: (Int, Int) -> Gen Edit
genEdit (n, pn) =
  Gen.choice
    [ Comment <$> m
    , BootComment <$> m
    , Body <$> m <*> Gen.int (Range.linear 0 3) <*> Gen.int (Range.linear 0 9)
    , AddValue <$> m
    , RemoveValue <$> m
    , Retype <$> m
    , AddImport <$> m <*> m
    , RemoveImport <$> m <*> m
    , AddSourceImport <$> m <*> m
    , RemoveSourceImport <$> m <*> m
    , Break <$> m
    ]
  where
    m = Gen.element ([0 .. n - 1] ++ [pkgP + j | j <- [0 .. pn - 1]])

-- | An edit to the package; one that doesn't apply (to a value or import a
-- module hasn't, say) changes nothing, so that shrinking a history keeps it
-- one.
applyEdit :: M.Map Int Mod -> Edit -> M.Map Int Mod
applyEdit mods e = case e of
  Comment i -> at i $ \m -> m{mComments = mComments m + 1}
  BootComment i -> at i $ \m -> if mBoot m then m{mBootComments = mBootComments m + 1} else m
  Body i v c -> at i $ \m -> m{mValues = [if k == v then (k, t, c) else (k, t, x) | (k, t, x) <- mValues m]}
  AddValue i -> at i $ \m -> m{mValues = mValues m ++ [(1 + maximum [k | (k, _, _) <- mValues m], TInt, 0)]}
  RemoveValue i -> at i $ \m -> if length (mValues m) > 1 then m{mValues = init (mValues m)} else m
  Retype i -> at i $ \m -> m{mValues = [if k == 0 then (k, flip' t, x) else (k, t, x) | (k, t, x) <- mValues m]}
  AddImport i j -> if j < i && inP i == inP j || inP j && not (inP i) then at i (\m -> m{mImports = add j (mImports m)}) else mods
  RemoveImport i j -> at i $ \m -> m{mImports = filter (/= j) (mImports m)}
  AddSourceImport i j -> if j > i && not (inP i) && maybe False mBoot (M.lookup j mods) then at i (\m -> m{mSourceImports = add j (mSourceImports m)}) else mods
  RemoveSourceImport i j -> at i $ \m -> m{mSourceImports = filter (/= j) (mSourceImports m)}
  Break i -> at i $ \m -> m{mBroken = not (mBroken m)}
  where
    at i f = M.adjust f i mods
    add j js = if j `elem` js then js else sort (j : js)
    flip' TInt = TInteger
    flip' TInteger = TInt

-- * Sources

-- | A node of the build: a module, or its boot file.
type Node = (Int, Bool)

nodes :: M.Map Int Mod -> [Node]
nodes mods = concat [[(i, True) | mBoot m] ++ [(i, False)] | (i, m) <- M.toList mods]

-- | What a node's compile reads the results of: a boot file, nothing; a
-- module, its imports, the boot files of its SOURCE imports, and its own.
--
-- A module that runs a splice also waits for the whole modules behind the
-- boot files below its imports, which its splice may link, as the rules
-- have it (see Note [Template Haskell modules] in compile.bzl, and
-- linksOf).
--
-- A module of the main package also waits for the modules of p below those
-- it imports from p, whose interfaces GHC reads with theirs, as the rules
-- have it (see Note [Compiling against dependencies module by module] in
-- compile.bzl).
nodeDeps :: M.Map Int Mod -> Links -> Node -> [Node]
nodeDeps _ _ (_, True) = []
nodeDeps mods ls (i, False) =
  [(j, False) | j <- mImports m] ++ [(j, True) | j <- mSourceImports m] ++ [(i, True) | mBoot m]
    ++ (if inP i then [] else [(j, False) | j <- belowInP mods [x | x <- mImports m, inP x]])
    ++ [(k, False) | k <- ls M.! i]
  where
    m = mods M.! i

-- | The modules each module's splice may link past boot files.
type Links = M.Map Int [Int]

-- | The links of each module (see links), but where modules would wait for
-- one another, as the rules break the tie (in _compile_per_module): the
-- first by name of those left waiting waits for none of the others left.
linksOf :: M.Map Int Mod -> Links
linksOf mods = go (M.fromList [(i, links mods i) | i <- M.keys mods])
  where
    go ls = case sortOn modName [i | (i, False) <- left, any (`elem` leftMods) (ls M.! i)] of
      [] -> ls
      i : _ -> go (M.insert i (filter (`notElem` leftMods) (ls M.! i)) ls)
      where
        left = snd (layers (nodeDeps mods ls) (nodes mods))
        leftMods = [j | (j, False) <- left]

-- | For a module that runs a splice, the modules behind the boot files
-- below its imports, which its splice may link, as the rules name them
-- (_linked_closure in compile.bzl): those of its own package, but itself
-- and those that import it, which can't be compiled before it.
links :: M.Map Int Mod -> Int -> [Int]
links mods i
  | isJust (mSplice (mods M.! i)) = [k | k <- linkedPastBoots mods (mImports (mods M.! i)), k /= i, inP k == inP i, i `notElem` below k]
  | otherwise = []
  where
    below k = belowAll [k]
    belowAll = go []
      where
        go visited [] = visited
        go visited (x : xs)
          | x `elem` visited = go visited xs
          | otherwise = let mx = mods M.! x in go (x : visited) (mImports mx ++ mSourceImports mx ++ xs)

-- | The modules of p below the given ones of p.
belowInP :: M.Map Int Mod -> [Int] -> [Int]
belowInP mods = go []
  where
    go visited [] = visited
    go visited (x : xs)
      | x `elem` visited = go visited xs
      | otherwise = go (x : visited) (mImports (mods M.! x) ++ xs)

-- | The modules behind the boot files below the given modules.
linkedPastBoots :: M.Map Int Mod -> [Int] -> [Int]
linkedPastBoots mods = go [] []
  where
    go _ found [] = found
    go visited found (x : xs)
      | x `elem` visited = go visited found xs
      | otherwise = let mx = mods M.! x in go (x : visited) (mSourceImports mx ++ found) (mImports mx ++ mSourceImports mx ++ xs)

-- | The package as a build compiles it: without the splices that would link
-- past a boot file, unless the GHC can do that both one-shot and in the
-- worker. GHC 9.14.1's one-shot mode can't (the splice's code is linked
-- without the module behind the boot file), nor can either before GHC 9.12
-- (see the worker's README). GHC 9.12's one-shot mode can, but not when the
-- compile has read the boot interface itself: when the module imports one
-- {-# SOURCE #-}, or, with -O, when an unfolding mentions one.
compiledAs :: Config -> History -> M.Map Int Mod -> M.Map Int Mod
compiledAs cfg h mods = M.map (\m -> if linksPast m && not (oneShotLinks m) then m{mSplice = Nothing} else m) mods
  where
    linksPast m = not (null (linkedPastBoots mods (mImports m)))
    oneShotLinks m = cBootSplices cfg && not (hOptimise h) && null (mSourceImports m)

nodeName :: Node -> String
nodeName (i, boot) = modName i ++ (if boot then "-boot" else "")

modName :: Int -> String
modName i = if inP i then "P" ++ show (i - pkgP) else "M" ++ show i

-- | Where a node's package's sources and outputs are, and its dep files.
-- The outputs are under one configuration's directory, as buck2 lays them
-- out, so that the worker's one-shot sessions of both packages share their
-- external state (see 'flavour' in the worker's Session).
srcDir, outDir :: Int -> FilePath
srcDir i = if inP i then "psrc" else "src"
outDir i = "art" </> "root" </> "cfg" </> if inP i then "pout" else "out"

suffix :: Node -> String
suffix (_, boot) = if boot then "-boot" else ""

source :: Node -> FilePath
source n@(i, _) = srcDir i </> modName i <.> ("hs" ++ suffix n)

value :: Int -> Int -> String
value j k = "v" ++ show j ++ "_" ++ show k

tyName :: Ty -> String
tyName TInt = "Int"
tyName TInteger = "Integer"

render :: M.Map Int Mod -> Node -> String
render mods (i, True) =
  let m = mods M.! i
      t = case [vt | (0, vt, _) <- mValues m] of
        vt : _ -> vt
        [] -> TInt
   in unlines ["module " ++ modName i ++ " where", "-- edit " ++ show (mBootComments m), value i 0 ++ " :: " ++ tyName t, "data " ++ ty i, "instance Show " ++ ty i]
render mods (i, False) =
  unlines $
    ["{-# LANGUAGE TemplateHaskell #-}" | isJust (mSplice m)]
      ++ ["module " ++ modName i ++ " (" ++ intercalate ", " exports ++ ") where"]
      ++ ["import qualified " ++ modName j | j <- mImports m]
      ++ ["import {-# SOURCE #-} qualified " ++ modName j | j <- mSourceImports m]
      ++ ["import Language.Haskell.TH.Syntax (lift)" | isJust (mSplice m)]
      ++ ["-- edit " ++ show (mComments m)]
      ++ concat
        [ [ value i k ++ " :: " ++ tyName t
          , value i k ++ " = " ++ show c ++ concat [" + fromIntegral " ++ modName j ++ "." ++ v | k == 0, j <- mImports m, v <- value j 0 : ["t" ++ show j | hasT j]]
          ]
        | (k, t, c) <- mValues m
        ]
      ++ concat [["t" ++ show i ++ " :: Integer", "t" ++ show i ++ " = 0" ++ concat [" + fromIntegral " ++ modName j ++ "." ++ value j 0 | j <- mSourceImports m], "{-# INLINE t" ++ show i ++ " #-}"] | hasT i]
      ++ concat [[shows' j ++ " :: " ++ modName j ++ "." ++ ty j ++ " -> String", shows' j ++ " = show"] | j <- mSourceImports m]
      ++ concat [["data " ++ ty i ++ " = " ++ ty i, "instance Show " ++ ty i ++ " where show _ = " ++ show (ty i)] | mBoot m]
      ++ concat [["s" ++ show i ++ " :: Integer", "s" ++ show i ++ " = $(lift (fromIntegral (length [" ++ modName j ++ "." ++ value j 0 ++ "]) :: Integer))"] | Just j <- [mSplice m]]
      ++ (if mBroken m then ["broken :: Int", "broken = \"not an Int\""] else [])
  where
    m = mods M.! i
    exports = [value i k | (k, _, _) <- mValues m] ++ ["t" ++ show i | hasT i] ++ map shows' (mSourceImports m) ++ [ty i | mBoot m] ++ ["s" ++ show i | isJust (mSplice m)]
    hasT j = not (null (mSourceImports (mods M.! j)))
    shows' j = "show" ++ show i ++ "_" ++ show j

-- | The type a module with a boot file declares in both.
ty :: Int -> String
ty i = "T" ++ show i

-- | The flags of every compile, and those of a node's own.
commonFlags :: History -> [String]
commonFlags h =
  ["-hide-all-packages", "-package", "base"]
    ++ (if hOptimise h then ["-O"] else ["-O0"])
    -- GHC, being dynamically linked, loads dynamic objects for a splice.
    ++ ["-dynamic" | any (isJust . mSplice . snd) (hModules h)]

nodeFlags :: M.Map Int Mod -> Node -> [String]
nodeFlags mods (i, _)
  | inP i = ["-this-unit-id", "p", "-i" ++ outDir pkgP]
  | otherwise =
      ["-DOWN_SESSION" | mOwnFlags m]
        ++ (if isJust (mSplice m) then ["-package", "template-haskell"] else [])
        ++ (if any (inP . fst) (M.toList mods) then ["-package-db", "pdb", "-package", "p"] else [])
        ++ ["-iout"]
  where
    m = mods M.! i

-- * Running a history

-- | What a build left of a node: compiled (its ABI hash, its object, and
-- the usages of its imports that its interface records), failed, or not
-- compiled because what it imports failed.
data Outcome = Compiled String B.ByteString [String] | Failed String | Blocked
  deriving (Eq)

describe :: Outcome -> String
describe (Compiled abi _ us) = "compiled, ABI " ++ abi ++ (if null us then "" else ", usages " ++ intercalate "; " us)
describe (Failed err) = "failed: " ++ take 400 err
describe Blocked = "not compiled (an import failed)"

isCompiled :: Outcome -> Bool
isCompiled (Compiled _ _ _) = True
isCompiled _ = False

-- | The worker, GHC and working directory; whether the objects are compared
-- (deterministic, from GHC 9.12) or else the usages; whether a splice may
-- link past a boot file (see compiledAs).
data Config = Config {cWorker :: FilePath, cGhc :: String, cDir :: FilePath, cObjects :: Bool, cBootSplices :: Bool, cOneShot :: Bool}

-- | What a history's builds did, to see that the histories reach what they
-- are for.
data Stats = Stats {sSkipped :: Int, sRecompiled :: Int, sFailed :: Int, sBlocked :: Int}

-- | For each node, the source it was last compiled from by the worker and
-- the contents then of the files its dep file lists.
type LastOk = M.Map Node (String, [(FilePath, Maybe B.ByteString)])

-- | Run the history through the worker and the clean builds; the first
-- disagreement, if there is one.
runHistory :: Config -> History -> IO (Either String (), Stats)
runHistory cfg h = do
  stats <- newIORef (Stats 0 0 0 0)
  let dir = cDir cfg
  removePathForcibly dir
  mapM_ (createDirectoryIfMissing True . (dir </>)) ["w/src", "w" </> outDir 0, "w/psrc", "w" </> outDir pkgP, "w/dep", "w/tmp", "ref"]
  -- p's early package db (see the module's description), for the worker's
  -- builds; the clean builds register their own.
  registerP cfg (dir </> "w") [i | (i, _) <- hModules h, inP i]
  lastOk <- newIORef M.empty
  let go _ _ [] = pure (Right ())
      go mods n (b : rest) = do
        let mods' = foldl applyEdit mods (bEdits b)
            built = compiledAs cfg h mods'
        forM_ (nodes built) $ \node -> writeFileIfChanged (dir </> "w" </> source node) (render built node)
        (worker, skipped) <- workerBuild cfg h b built lastOk stats
        ref <- refBuild cfg h built
        case [(node, w, r) | (node, w) <- M.toList worker, let r = ref M.! node, not (agree w r)] of
          [] -> go mods' (n + 1) rest
          diffs ->
            pure . Left $
              unlines $
                ("after build " ++ show (n :: Int) ++ ":")
                  : [nodeName node ++ ": through the worker " ++ describe w ++ (if node `elem` skipped then " (skipped as up to date)" else "") ++ "; with ghc -c " ++ describe r | (node, w, r) <- diffs]
  result <- go (M.fromList (hModules h)) 1 (hBuilds h)
  (,) result <$> readIORef stats
  where
    agree (Compiled a o u) (Compiled a' o' u') = a == a' && (if cObjects cfg then o == o' else u == u')
    agree (Failed _) (Failed _) = True
    agree Blocked Blocked = True
    agree _ _ = False

-- | Register p's early package db in the given directory, if p has modules:
-- no library, and its import directory the one its interfaces are written
-- to.
registerP :: Config -> FilePath -> [Int] -> IO ()
registerP _ _ [] = pure ()
registerP cfg dir ps = do
  let conf = dir </> "p.conf"
  removePathForcibly (dir </> "pdb")
  writeFile conf ("name: p\nversion: 0\nid: p\nkey: p\nexposed: True\nexposed-modules: " ++ unwords (map modName ps) ++ "\nimport-dirs: " ++ dir </> outDir pkgP ++ "\n")
  _ <- readProcess (ghcPkgOf (cGhc cfg)) ["init", dir </> "pdb"] ""
  -- It warns that the interfaces are missing.
  _ <- readProcessWithExitCode (ghcPkgOf (cGhc cfg)) ["register", "--force", "--package-db", dir </> "pdb", conf] ""
  pure ()

writeFileIfChanged :: FilePath -> String -> IO ()
writeFileIfChanged path s = do
  old <- (Just <$> readFile' path) `catchAny` pure Nothing
  unless (old == Just s) (writeFile path s)
  where
    readFile' p = do t <- readFile p; length t `seq` pure t

-- | The nodes in layers, each node's dependencies in earlier ones, and those
-- left in or behind a cycle.
layers :: (Node -> [Node]) -> [Node] -> ([[Node]], [Node])
layers deps = go M.empty
  where
    go _ [] = ([], [])
    go done pending =
      let ready = [n | n <- pending, all (`M.member` done) (deps n)]
       in if null ready then ([], pending) else let (rest, left) = go (M.union done (M.fromList [(n, ()) | n <- ready])) (filter (`notElem` ready) pending) in (ready : rest, left)

-- | One build through a fresh worker, each node sent as soon as those it
-- waits for are done, as buck2 sends them. With the outcomes, the nodes it
-- skipped as up to date.
workerBuild :: Config -> History -> Build -> M.Map Int Mod -> IORef LastOk -> IORef Stats -> IO (M.Map Node Outcome, [Node])
workerBuild cfg h b mods lastOk stats = do
  let wdir = cDir cfg </> "w"
  -- Its log, of the last build, is left for a failure's inspection.
  logH <- openFile (wdir </> "worker.log") WriteMode
  let mode = if cOneShot cfg then "one-shot" else "make"
  withWorkerProcess (cWorker cfg) [] wdir ([("TMPDIR", wdir </> "tmp"), ("GHC_WORKER_VERBOSE", "1"), ("GHC_WORKER_SESSION_MODE", mode)] ++ [("GHC_WORKER_SESSIONS", "0") | bEagerDrop b]) (UseHandle logH) $ \sock -> do
      skippedRef <- newIORef []
      vars <- M.fromList <$> forM (nodes mods) (\node -> (,) node <$> newEmptyMVar)
      let result node = readMVar (vars M.! node) >>= either (\(e :: SomeException) -> throwIO e) pure
      forM_ (nodes mods) $ \node -> forkIO $ do
        r <- try $ do
          deps <- mapM result (nodeDeps mods ls node)
          decide wdir sock skippedRef (all isCompiled deps) node
        putMVar (vars M.! node) r
      (,) . M.fromList <$> forM (nodes mods) (\node -> (,) node <$> result node) <*> readIORef skippedRef
  where
    ls = linksOf mods
    count f = atomicModifyIORef' stats (\st -> (f st, ()))
    decide wdir sock skippedRef depsOk node
      | not depsOk = do
          modifyIORef' lastOk (M.delete node)
          count (\st -> st{sBlocked = sBlocked st + 1})
          pure Blocked
      | otherwise = do
          let src = render mods node
          previous <- M.lookup node <$> readIORef lastOk
          upToDate <- case previous of
            Just (s, deps) | s == src -> and <$> mapM (\(f, c) -> (== c) <$> contents (wdir </> f)) deps
            _ -> pure False
          if upToDate
            then count (\st -> st{sSkipped = sSkipped st + 1}) >> modifyIORef' skippedRef (node :) >> current wdir node
            else do
              -- A compile of these takes a second or two: a request that
              -- takes far longer is a worker that hangs.
              answer <- timeout 120000000 (grpc sock (request node))
              (code, err) <- maybe (fail ("the worker didn't answer " ++ nodeName node ++ " in two minutes (see " ++ (wdir </> "worker.log") ++ ")")) pure answer
              when (isJust previous) $ count (\st -> st{sRecompiled = sRecompiled st + 1})
              if code /= 0
                then do
                  modifyIORef' lastOk (M.delete node)
                  count (\st -> st{sFailed = sFailed st + 1})
                  pure (Failed err)
                else do
                  deps <- lines <$> readFile (wdir </> depFile node)
                  cs <- mapM (contents . (wdir </>)) deps
                  modifyIORef' lastOk (M.insert node (src, zip deps cs))
                  current wdir node
    contents f = (Just <$> B.readFile f) `catchAny` pure Nothing
    current wdir node@(i, _) = do
      let out ext = wdir </> outDir i </> modName i <.> (ext ++ suffix node)
      us <- if cObjects cfg then pure [] else usagesOf <$> readProcess (cGhc cfg) ["--show-iface", out "hi"] ""
      Compiled . trim <$> readFile (out "abi") <*> B.readFile (out "o") <*> pure us
    depFile node = "dep" </> nodeName node <.> "dep"
    request node@(i, boot) =
      [ "--request", "--contract", contract
      , "--depfile", depFile node, "--abi", outDir i </> modName i <.> ("abi" ++ suffix node), "--module", modName i
      , "--source", source node, "--outdir", outDir i, "--hisuf", "hi", "--srcroot=" ++ srcDir i
      ] ++ ["--boot" | boot] ++ ["--link=" ++ modName k | not boot, k <- ls M.! i]
      ++ ["--hidir=" ++ outDir pkgP | not (inP i)]
      ++ ["--", cGhc cfg] ++ commonFlags h ++ nodeFlags mods node
      ++ ["--", "-c", source node, "-o", outDir i </> modName i <.> ("o" ++ suffix node), "-ohi", outDir i </> modName i <.> ("hi" ++ suffix node)]

-- | A clean build of the same sources, one `ghc -c` per node.
refBuild :: Config -> History -> M.Map Int Mod -> IO (M.Map Node Outcome)
refBuild cfg h mods = do
  let rdir = cDir cfg </> "ref"
  removePathForcibly rdir
  mapM_ (createDirectoryIfMissing True . (rdir </>)) ["src", outDir 0, "psrc", outDir pkgP]
  registerP cfg rdir [i | i <- M.keys mods, inP i]
  forM_ (nodes mods) $ \node -> writeFile (rdir </> source node) (render mods node)
  outcomes <- newIORef M.empty
  let ls = linksOf mods
  forM_ (concat (fst (layers (nodeDeps mods ls) (nodes mods)))) $ \node@(i, _) -> do
    done <- readIORef outcomes
    outcome <-
      if any (\d -> not (maybe False isCompiled (M.lookup d done))) (nodeDeps mods ls node)
        then pure Blocked
        else do
          let flags = commonFlags h ++ nodeFlags mods node ++ ["-fobject-determinism" | cObjects cfg]
          (code, _, err) <- readCreateProcessWithExitCode (proc (cGhc cfg) (["-c", source node, "-odir", outDir i, "-hidir", outDir i] ++ flags)){cwd = Just rdir} ""
          case code of
            ExitSuccess -> do
              iface <- readProcess (cGhc cfg) ["--show-iface", rdir </> outDir i </> modName i <.> ("hi" ++ suffix node)] ""
              Compiled (abiOf iface) <$> B.readFile (rdir </> outDir i </> modName i <.> ("o" ++ suffix node)) <*> pure (if cObjects cfg then [] else usagesOf iface)
            _ -> pure (Failed err)
    modifyIORef' outcomes (M.insert node outcome)
  readIORef outcomes
  where
    abiOf iface = case [w | l <- lines iface, "ABI" : "hash:" : w : _ <- [words l]] of
      a : _ -> a
      [] -> "?"

-- | The usages of imported modules in an interface's text: "import -/ M
-- hash" (the first on the "usages:" line since GHC 9.14). Before GHC 9.12,
-- whose objects aren't compared, they show what a module was compiled
-- against, which its ABI hash then doesn't.
usagesOf :: String -> [String]
usagesOf iface = [unwords u | l <- lines iface, u@("import" : "-/" : _) <- [dropWhile (/= "import") (words l)]]

catchAny :: forall a. IO a -> IO a -> IO a
catchAny a b = (try a :: IO (Either SomeException a)) >>= either (const b) pure

trim :: String -> String
trim = reverse . dropWhile (`elem` ("\r\n " :: String)) . reverse

main :: IO ()
main = do
  worker <- fromMaybe "ghc-worker" <$> lookupEnv "GHC_WORKER"
  ghc <- fromMaybe "ghc" <$> lookupEnv "GHC"
  version <- trim <$> readProcess ghc ["--numeric-version"] ""
  when (version /= showVersion fullCompilerVersion) $ do
    hPutStrLn stderr ("the props were built with GHC " ++ showVersion fullCompilerVersion ++ " but `" ++ ghc ++ "` is " ++ version ++ ": set GHC")
    exitFailure
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let v = versionBranch fullCompilerVersion
      cfg = Config worker ghc (tmp </> ("ghc-worker-props-" ++ show pid)) (v >= [9, 12]) (take 2 v == [9, 12]) False
      -- (In a directory of its own, as the properties run at once.)
      oneShotCfg = cfg{cOneShot = True, cDir = cDir cfg ++ "-one-shot"}
  -- The last history's directory is kept if a property fails, for a look
  -- at what it built.
  let tree = adjustOption (\(HedgehogTestLimit n) -> HedgehogTestLimit (n <|> Just 30)) . askOption $ \(HedgehogTestLimit n) ->
        -- In each session mode but the default (see Note [One-shot
        -- sessions] in the worker's Session): --make, with boot files or
        -- not; and one-shot, without (the worker refuses boot files then).
        testGroup
          "a history built through the worker agrees with clean ghc -c builds"
          [ testPropertyNamed "with --make sessions" "historyMake" (historyProp cfg (maybe 30 fromIntegral n))
          , testPropertyNamed "with one-shot sessions" "historyOneShot" (historyProp oneShotCfg (maybe 30 fromIntegral n))
          ]
  defaultMain tree `catch` \code -> do
    when (code == ExitSuccess) (mapM_ (removePathForcibly . cDir) [cfg, oneShotCfg])
    throwIO code

-- | The property, of the given number of histories.
historyProp :: Config -> Int -> Property
historyProp cfg tests =
  -- Few shrinks: each runs a history, of a minute or more.
  withShrinks 30 . property $ do
    h <- forAll (genHistory (not (cOneShot cfg)))
    (result, st) <- liftIO (runHistory cfg h)
    -- Of the package as first generated. The minimums catch a generator
    -- that stops making what the histories are for: each is far enough
    -- below its usual share that 30 histories miss one about once in 3,000
    -- runs. Fewer histories only count them.
    let mods = compiledAs cfg h (M.fromList (hModules h))
        ms = M.elems mods
        sourced j = not (null (mSourceImports (mods M.! j)))
        cover' p l b = if tests >= 30 then cover p l b else classify l b
    cover' 50 "a module skipped as up to date" (sSkipped st > 0)
    cover' 40 "a module compiled again" (sRecompiled st > 0)
    cover' 25 "a module failed" (sFailed st > 0)
    cover' 15 "a module blocked by a failed import" (sBlocked st > 0)
    cover' 25 "a module with a session of its own" (any mOwnFlags ms)
    unless (cOneShot cfg) $ do
      cover' 25 "a boot file" (any mBoot ms)
      cover' 10 "a SOURCE import" (any (not . null . mSourceImports) ms)
      cover' 10 "an import of a module with SOURCE imports" (any (any sourced . filter (not . inP) . mImports) ms)
    cover' 10 "a splice" (any (isJust . mSplice . snd) (hModules h))
    -- (Fewer before GHC 9.12 and with 9.14: see compiledAs.)
    classify "a splice compiled" (any (isJust . mSplice) ms)
    unless (cOneShot cfg) $ classify "a splice in a module with a boot file" (any (\m -> mBoot m && isJust (mSplice m)) ms)
    cover' 10 "an import from p" (any (any inP . mImports) ms)
    cover' 45 "sessions dropped as soon as idle" (any bEagerDrop (hBuilds h))
    case result of
      Right () -> success
      Left err -> annotate err >> failure
