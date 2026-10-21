#!/usr/bin/env python3
# Tests of what the per-module scripts (prelude/haskell/tools) read from
# their inputs: the compile script from GHC's interface dumps, and the deps
# script from the sources.
#
# dumps/M-<version>.dump-hi is the -ddump-hi of this module, compiled with
# each GHC the rules support, its imports compiled first:
#
#   {-# LANGUAGE TemplateHaskell, Trustworthy #-}
#   module Fix.M where
#   import Fix.A (a)
#   import safe Fix.S (s)
#   import {-# SOURCE #-} Fix.B (b)
#   import Data.List (sort)
#   import Language.Haskell.TH.Syntax (addDependentFile, lift)
#   m :: Int
#   m = a + s + sum (sort [1, 2]) + $(addDependentFile "data.txt" >> lift (4 :: Int))
#   mb :: () -> Int
#   mb () = b

import glob
import os
import sys
import unittest

here = os.path.dirname(os.path.abspath(__file__))
# (No __pycache__ in the prelude.)
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(here, "..", "..", "prelude", "haskell", "tools"))

from per_module_compile import Dump  # noqa: E402
from per_module_deps import extensions, splice_imports  # noqa: E402


class InterfaceDump(unittest.TestCase):
    def test_each_ghc(self):
        dumps = sorted(glob.glob(os.path.join(here, "dumps", "M-*.dump-hi")))
        self.assertTrue(dumps)
        for path in dumps:
            with self.subTest(os.path.basename(path)):
                with open(path) as f:
                    dump = Dump(f.read())
                self.assertEqual(len(dump.abi_hashes), 1)
                self.assertRegex(dump.abi_hashes[0], r"^[0-9a-f]{32}$")
                home = {i.split(":", 1)[-1] for i in dump.imports if i.endswith(("Fix.A", "Fix.B", "Fix.S"))}
                self.assertEqual(home, {"Fix.A", "Fix.B", "Fix.S"})
                self.assertEqual(dump.boots, {"Fix.B"})
                self.assertIn("data.txt", dump.dependent_files)
                self.assertTrue(dump.readable())

    def test_unreadable(self):
        # Usages in a form the script doesn't know.
        dump = Dump("  ABI hash: 0123\n  usages: [usage  -/  Fix.A 0123]\n")
        self.assertFalse(dump.readable())
        self.assertFalse(Dump("  usages: []\n").readable())
        # A module may import nothing.
        self.assertTrue(Dump("  ABI hash: 0123\n").readable())


class Sources(unittest.TestCase):
    def test_extensions(self):
        src = "{-#LANGUAGE ImplicitStagePersistence,\n  QuasiQuotes#-}\n{-# OPTIONS_GHC -XNoExplicitLevelImports #-}\nmodule M where\n"
        self.assertTrue({"ImplicitStagePersistence", "QuasiQuotes", "NoExplicitLevelImports"} <= extensions(src))
        self.assertEqual(extensions("{-# language TemplateHaskell #-}"), {"TemplateHaskell"})

    def test_splice_imports(self):
        src = "\n".join([
            "module X where",
            "import splice Foo.Bar",
            "import",
            "  qualified Baz.Q splice",
            "import {-# SOURCE #-} splice  Boot.M",
            'import "pkg" splice P.Q',
            "import safe splice S.T as U",
            "import Not.Splice",
        ])
        self.assertEqual(splice_imports(src), ["Foo.Bar", "Baz.Q", "Boot.M", "P.Q", "S.T"])


if __name__ == "__main__":
    unittest.main()
