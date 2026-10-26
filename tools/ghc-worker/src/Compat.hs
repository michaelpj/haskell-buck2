{-# LANGUAGE CPP #-}
-- GHC 9.14 deprecates replacing the home package table, which emptyHome
-- does with an empty one.
{-# OPTIONS_GHC -Wno-deprecations #-}
-- | What differs between the GHC versions the worker builds with (9.6 to
-- 9.14), so that the rest of it needs no CPP.
module Compat
  ( objectDeterminism
  , analyseTargets
  , sharedFileHashes
  , withFileHashes
  , importName
  , srcImportName
  , directDep
  , abiHash
  , usages
  , usageFile
  , emptyHome
  , withModuleGraph
  , insertHome
  , addHomes
  ) where

#if MIN_VERSION_ghc(9,12,0)
import Control.Concurrent.MVar (newMVar, withMVar)
#endif

import GHC
#if MIN_VERSION_ghc(9,8,0)
import GHC.Data.FastString (unpackFS)
#endif
import GHC.Unit.Finder (initFinderCache)
import GHC.Unit.Finder.Types (FinderCache (..))
import GHC.Driver.Main (initModDetails)
import GHC.Unit.Home.ModInfo (HomeModInfo (..), HomeModLinkable)
import GHC.Unit.Module.Deps (Usage (..))
import GHC.Unit.Module.ModIface
import GHC.Utils.Fingerprint (Fingerprint)
import GHC.Types.Error (isEmptyMessages)
#if MIN_VERSION_ghc(9,14,0)
import Data.Maybe (fromMaybe)
import GHC.Types.Error (mkUnknownDiagnostic)
import GHC.Driver.Env (hscUpdateHPT, hsc_HPT, setModuleGraph)
import GHC.Unit.Home.PackageTable (addHomeModInfoToHpt, emptyHomePackageTable)
import Control.Monad (forM)
#else
import GHC.Driver.Env (hscUpdateHPT, hsc_mod_graph)
import GHC.Unit.Home.ModInfo (addListToHpt, addToHpt, emptyHomePackageTable)
import System.IO (fixIO)
#endif

-- | Flags that make object code deterministic, where GHC can (9.12 and
-- later): GHC's uniques otherwise depend on what the session compiled
-- before, so a module's object would differ from one compile to the next,
-- and buck2 would link the library again after every edit.
objectDeterminism :: [String]
#if MIN_VERSION_ghc(9,12,0)
objectDeterminism = ["-fobject-determinism"]
#else
objectDeterminism = []
#endif

-- | GHC's dependency analysis of the session's targets; whether it found
-- no errors (with errors, GHC leaves the session's module graph empty).
analyseTargets :: Ghc Bool
#if MIN_VERSION_ghc(9,14,0)
analyseTargets = isEmptyMessages . fst <$> depanalE mkUnknownDiagnostic Nothing [] True
#else
analyseTargets = isEmptyMessages . fst <$> depanalE [] True
#endif

-- | A finder cache for its file hashes, which looks each up under a lock
-- where it can (GHC 9.12 and later; before, `lookupFileCache` isn't the
-- finder cache's to replace). See Note [Hashing the libraries] in Session.
sharedFileHashes :: IO FinderCache
sharedFileHashes = do
  fc <- initFinderCache
#if MIN_VERSION_ghc(9,12,0)
  lock <- newMVar ()
  pure fc{lookupFileCache = \f -> withMVar lock (\_ -> lookupFileCache fc f)}
#else
  pure fc
#endif

-- | A session's finder cache with the shared file hashes (see
-- sharedFileHashes).
withFileHashes :: FinderCache -> FinderCache -> FinderCache
#if MIN_VERSION_ghc(9,12,0)
withFileHashes shared fc = fc{lookupFileCache = lookupFileCache shared}
#else
withFileHashes shared fc = fc{fcFileCache = fcFileCache shared}
#endif

-- | A summary's import (with the package it names, if any) and an
-- interface's direct dependency, which carry an import level since GHC
-- 9.14.
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

-- | The interface's ABI hash and usages, where each GHC keeps them.
abiHash :: ModIface -> Fingerprint
usages :: ModIface -> [Usage]
#if MIN_VERSION_ghc(9,14,0)
abiHash = mi_mod_hash
usages = fromMaybe [] . mi_usages
#else
abiHash = mi_mod_hash . mi_final_exts
usages = mi_usages
#endif

-- | The file of a usage of one (addDependentFile, or a library a splice
-- loaded).
usageFile :: Usage -> Maybe FilePath
#if MIN_VERSION_ghc(9,8,0)
usageFile UsageFile{usg_file_path = p} = Just (unpackFS p)
#else
usageFile UsageFile{usg_file_path = p} = Just p
#endif
usageFile _ = Nothing

-- | The environment with an empty home package table of its own: a value
-- before GHC 9.14, a mutable table since.
emptyHome :: HscEnv -> IO HscEnv
#if MIN_VERSION_ghc(9,14,0)
emptyHome hsc = (\hpt -> hscUpdateHPT (const hpt) hsc) <$> emptyHomePackageTable
#else
emptyHome = pure . hscUpdateHPT (const emptyHomePackageTable)
#endif

-- | The environment with the given module graph.
withModuleGraph :: ModuleGraph -> HscEnv -> HscEnv
#if MIN_VERSION_ghc(9,14,0)
withModuleGraph = setModuleGraph
#else
withModuleGraph mg hsc = hsc{hsc_mod_graph = mg}
#endif

-- | Add an entry to the environment's home package table.
insertHome :: HscEnv -> ModuleName -> HomeModInfo -> IO HscEnv
#if MIN_VERSION_ghc(9,14,0)
insertHome hsc _ hmi = addHomeModInfoToHpt hmi (hsc_HPT hsc) >> pure hsc
#else
insertHome hsc mn hmi = pure (hscUpdateHPT (\hpt -> addToHpt hpt mn hmi) hsc)
#endif

-- | Add home modules read from their interfaces that import one another
-- (through boot files), or one module, to the environment's home package
-- table: each typechecked, lazily, against the table with all of them in
-- it, as GHC's --make does a cycle of modules once it is compiled
-- (typecheckLoop). In a mutable table (since GHC 9.14), a module's
-- typechecking finds the others there when it is forced.
addHomes :: HscEnv -> [(ModIface, HomeModLinkable)] -> IO (HscEnv, [HomeModInfo])
#if MIN_VERSION_ghc(9,14,0)
addHomes hsc mods = do
  hmis <- forM mods $ \(iface, linkable) -> do
    details <- initModDetails hsc iface
    let hmi = HomeModInfo iface details linkable
    addHomeModInfoToHpt hmi (hsc_HPT hsc)
    pure hmi
  pure (hsc, hmis)
#else
addHomes hsc mods = do
  -- The table's entries are strict but for their details, which nothing
  -- forces while they are made.
  (env, details) <- fixIO $ \ ~(_, details) -> do
    let env = hscUpdateHPT (\hpt -> addListToHpt hpt [(moduleName (mi_module iface), HomeModInfo iface (details !! k) linkable) | (k, (iface, linkable)) <- zip [0 ..] mods]) hsc
    (,) env <$> mapM (initModDetails env . fst) mods
  pure (env, [HomeModInfo iface d linkable | ((iface, linkable), d) <- zip mods details])
#endif
