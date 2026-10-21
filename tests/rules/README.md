# Tests of the per-module rules

Builds a small project (`project/`) with `per_module = True` targets and
checks what the rules decide: which package dbs, libraries and interfaces
each module's compile gets, what its dep file lists, and which modules
compile again after an edit. Only GHC's own packages are used (`base`,
`template-haskell`), so neither Hackage nor cabal-buck2 is needed.

```
tests/rules/run.sh GHC_BIN_DIR [WORK_DIR] [-- --only CHECK ...]
```

`GHC_BIN_DIR` has `ghc` and `ghc-pkg`; `buck2`, `python3`, C compilers
(`cc` for GHC, `clang` for buck2's C toolchain, which builds `//cl:cl`) and
`g++` (that toolchain's linker) must be on `PATH`. The project is copied
to `WORK_DIR` (a new temporary directory by default), since the checks
edit its sources, and built there; each buck2 command's output is saved under
`WORK_DIR/project/buck-logs/`. It takes about 15 seconds.

Each check prints `PASS`, `FAIL` (with the missing and unexpected members
of the set it compared) or `SKIP` (the explicit level imports check,
before GHC 9.14). The script fails on any `FAIL`.

## How it works

- `test_scripts.py` tests what the per-module scripts
  (`prelude/haskell/tools`) read from GHC's interface dumps, with a dump
  from each GHC the rules support (`dumps/`), and from the sources. `run.sh`
  runs it first.
- `gen_prebuilt.py` writes the `third-party-haskell` cell: a
  `haskell_prebuilt_library()` per package of GHC's that the fixtures use,
  and the `tools.bzl` that the rest of the support code loads.
- `check.py` runs the checks in order, in one buck2 daemon (buck2 keeps dep
  files in the daemon's memory, so the early cut-off checks need it to
  live). It reads the compiles' command lines from `buck2 log what-ran
  --format json` (the per-module compiles are registered by a
  `dynamic_output`, which `buck2 aquery` doesn't show), their dep files from
  `buck2 audit dep-files`, and the package confs from `buck2 aquery`, and
  names buck-out paths by what they are: `a:A.Mid.abi` (a module's file),
  `th:early` and `th:final` (a target's package dbs), `c:ldtree:root-th-th`
  (a tree of shared libraries on `LD_LIBRARY_PATH`), `ghc:global`.

## The fixtures

| Target | What it is for |
| --- | --- |
| `//a:a` | `A.Base`; `A.Mid`, which imports it; `A.Unused` |
| `//b:b` | `B.M`, which imports `A.Mid` only; `B.Lit`, a literate source, whose instance `B.UsesLit` uses; `B.Safe`, a Safe module importing `A.Mid` |
| `//th:th` | `TH.Gen.gen`, a `Q Exp` |
| `//c:c` | `th_build_depends = [":th"]`: a splice of `gen`, a module without Template Haskell, an `ANN` pragma |
| `//c:show` | prints `C.Splice`'s value, which comes from `gen` |
| `//d:d` | `th_build_depends = []`: a splice that runs only `template-haskell` |
| `//e:e` | GHC 9.14: `import splice TH.Gen`, and `import splice Language.Haskell.TH` |
| `//elr:elr` | GHC 9.14: `import splice A.Base`, which `//rx:rx` re-exports |
| `//cyc:cyc` | two modules in an import cycle, through an hs-boot file |
| `//main:main` | a binary depending on `b`; `main-shared`, the same linked shared |
| `//waits:w` | imports a module of `//waits:s`, whose other module doesn't compile |
| `//rx:rx`, `//ux:ux` | `rx` re-exports `A.Base`; `ux` imports `A.Base` through it |
| `//tie:tie` | two Template Haskell modules, each behind a boot file below the other, and one behind them |
| `//rp:rp`, `//mk:mk` | `rp`'s flat sources (`Lib.hs`), one of which imports `Q.Lib` from `mk` (built with `--make`), whose interface path ends in `/Lib.hi` |
| `//mv:hi`, `//mv:lo`, `//mv:main` | a module that moves from `hi` to `lo`, its dependency |
| `//idx:idx` | built with `-fwrite-ide-info`, for its index (`index.bxl` prints it) |
| `//hdr:hdr` | a module that `#include`s a header in the target's `srcs` (`Hdr/value.h`) |
| `//tf:tf` | a splice without a LANGUAGE pragma, for Template Haskell enabled by the toolchain's flags |
| `//cl:cl`, `//ffi:ffi`, `//ffiuse:ffiuse` | a C library, a library that imports its function, and a splice that calls it; `//ffiuse:show` prints the splice |
