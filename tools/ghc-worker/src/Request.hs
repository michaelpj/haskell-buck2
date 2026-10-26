-- | The request the rules send for each module, and the flags of the session
-- it compiles in.
module Request (Request (..), parseRequest, sessionFlags) where

import Data.List (stripPrefix)

import Compat (objectDeterminism)
import Contract (contract)

-- | One module to compile, as the rules describe it in the action's
-- arguments (see Note [The persistent worker] in compile.bzl):
--
-- > --request --contract V --depfile DEP --abi ABI --module Foo/Bar
-- >   --source Foo/Bar.hs --outdir OUT --hisuf SUF [--boot] [--ldtree TREES]
-- >   --link=Foo.Baz... --hidir=DIR... --srcroot=SRCS --mkdir=DIR...
-- >   -- ghc SESSION_FLAGS... -- -c Foo/Bar.hs -o ... -ohi ...
--
-- The compile's flags come in two parts: those of the module's session, and
-- the module's own, which the worker ignores except for @-hiedir@ and
-- @-stubdir@ (the session's flags have neither), compiling the module to
-- the session's output directory instead. The same request is the compile
-- script's (prelude/haskell/tools/per_module_compile.py) when buck2 doesn't
-- use the worker.
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
  , reqLinks :: [String] -- modules with boot files that its splices may link (see Note [Each compile's home modules] in Session)
  , reqCompiler :: String
  , reqSessionArgs :: [String] -- the flags of every module of the session
  , reqModuleArgs :: [String] -- the module's own: `ghc -c`'s source and outputs, and -hiedir and -stubdir
  }

-- | The request in an action's command line, which buck2 sends whole: the
-- program and its own arguments come before the "--request" marker.
parseRequest :: [String] -> Either String Request
parseRequest args = case drop 1 (dropWhile (/= "--request") args) of
  "--contract" : v : rest
    | v == contract -> go (Request "" "" "" "" "" "" [] [] [] False [] "" [] []) rest
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
    -- The compile script's: the worker only gets modules whose trees are all
    -- of prebuilt libraries, which find their own dependencies (see Note [The
    -- persistent worker] in compile.bzl).
    go r ("--ldtree" : _ : rest) = go r rest
    go r ("--" : compiler : rest) =
      let (session, moduleArgs) = break (== "--") rest
       in Right r{reqCompiler = compiler, reqSessionArgs = session, reqModuleArgs = drop 1 moduleArgs}
    go r (x : rest)
      | Just v <- stripPrefix "--hidir=" x = go r{reqHidirs = reqHidirs r ++ [v]} rest
      | Just v <- stripPrefix "--srcroot=" x = go r{reqSrcRoots = reqSrcRoots r ++ [v]} rest
      | Just v <- stripPrefix "--mkdir=" x = go r{reqMkdirs = reqMkdirs r ++ [v]} rest
      | Just v <- stripPrefix "--link=" x = go r{reqLinks = reqLinks r ++ [v]} rest
      | otherwise = Left ("ghc-worker: unexpected request argument " ++ show x)
    go _ [] = Left "ghc-worker: request has no compiler command"

-- | The flags of the request's session: its compile's but the module's own
-- (whose outputs go to -odir/-hidir by module name, which is where the
-- rules put them anyway), and the target's sources on the import path.
-- Object code is made deterministic where GHC can (see objectDeterminism).
-- Each request is compiled, whatever GHC's recompilation check would say
-- (see Note [Compiling whenever buck2 asks] in Session). Options for the
-- ghc program's runtime (@+RTS ... -RTS@) are left out: the worker's
-- runtime is its own.
sessionFlags :: Request -> [String]
sessionFlags r =
  withoutRts (reqSessionArgs r)
    ++ ["-odir", reqOutDir r, "-hidir", reqOutDir r, "-fforce-recomp"]
    ++ objectDeterminism
    ++ ["-i" ++ d | d <- reqSrcRoots r]

withoutRts :: [String] -> [String]
withoutRts args = case break (== "+RTS") args of
  (ghc, _ : rest) -> ghc ++ withoutRts (drop 1 (dropWhile (/= "-RTS") rest))
  (ghc, []) -> ghc
