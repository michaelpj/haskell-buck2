-- | What the worker writes for the rules besides GHC's outputs.
module DepFile (writeDepFiles) where

import Control.Monad (filterM, forM)
import Data.List (isPrefixOf)
import qualified Data.Set as Set
import System.Directory (canonicalizePath, doesFileExist, getCurrentDirectory)
import System.FilePath (makeRelative, (<.>), (</>))

import GHC (moduleName, moduleNameString)
import GHC.Unit.Module.Deps (Usage (..), dep_direct_mods)
import GHC.Unit.Module.ModIface (ModIface, mi_deps)
import GHC.Unit.Types (GenWithIsBoot (..), IsBootInterface (..))
import GHC.Utils.Fingerprint (Fingerprint)

import Compat (abiHash, directDep, usageFile, usages)
import Request

-- | The ABI file and dep file of a compiled module, from its interface: the
-- ABI hash, and the usages GHC recorded (what its own recompilation check
-- reads): imports as their .abi files, and the files a splice loaded. See
-- Note [Early cut-off by dep files] in compile.bzl; the compile script
-- (prelude/haskell/tools/per_module_compile.py) writes the same from the
-- interface's text, and the two look the imports up in the same order.
writeDepFiles :: Request -> ModIface -> IO ()
writeDepFiles r iface = do
  writeFile (reqAbi r) (show (abiHash iface :: Fingerprint) ++ "\n")
  cwd <- getCurrentDirectory
  -- A module imported {-# SOURCE #-} alone is listed by its boot file's.
  let direct = [(gwib_mod d, gwib_isBoot d) | (_, d) <- map directDep (Set.toList (dep_direct_mods (mi_deps iface)))]
      ext m = if (m, IsBoot) `elem` direct && (m, NotBoot) `notElem` direct then "abi-boot" else "abi"
  entries <- fmap concat . forM (usages iface) $ \u -> case u of
    UsageHomeModule{usg_mod_name = m} -> existing [reqOutDir r </> modFile m <.> ext m]
    UsageHomeModuleInterface{usg_mod_name = m} -> existing [reqOutDir r </> modFile m <.> "abi"]
    UsagePackageModule{usg_mod = m} -> firstExisting (concat [[d </> modFile (moduleName m) <.> "abi", d </> modFile (moduleName m) <.> reqHisuf r] | d <- reqHidirs r])
    _ | Just path <- usageFile u -> do
      -- Those outside the project (the libraries of GHC's own package db)
      -- are no inputs of the action.
      ok <- doesFileExist path
      if ok then (\c -> [c | isUnder cwd c]) <$> canonicalizePath path else pure []
    _ -> pure []
  self <- if reqBoot r then pure [] else existing [reqOutDir r </> reqModPath r <.> "abi-boot"]
  rel <- mapM (fmap (makeRelative cwd) . canonicalizePath) (entries ++ self)
  writeFile (reqDepfile r) (unlines rel)
  where
    modFile = map (\c -> if c == '.' then '/' else c) . moduleNameString
    existing = filterM doesFileExist
    firstExisting = fmap (take 1) . existing
    isUnder cwd p = (cwd ++ "/") `isPrefixOf` p
