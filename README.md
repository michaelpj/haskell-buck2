# Buck2 prelude for Haskell projects

This is a version of the [Buck2
prelude](https://github.com/facebook/buck2/tree/main/prelude) with a
few tweaks (that will hopefully be upstreamed at some point) and some
support code for building Haskell projects.

You probably don't want this by itself---instead take a look at
[cabal-buck2](https://hackage.haskell.org/package/cabal-buck2) which
extends `cabal` with a `buck2` command so that you can use Buck2 as
the build tool for your Cabal project.

# Build modes

The Buck2 build system has two build modes:

  * `dev`: the default, builds everything with `-O0` and dynamic linking. This is intended to give you the quickest edit-compile-test turnaround.
  * `opt`: enable `-O` and link statically. This takes longer but the code runs faster.

To build with `opt`, use `-m opt`, e.g.

```
buck2 build my-package:my-program -m opt
```

There are other build options that can be selected in a similar way, such as `-m prof` to enable profiling. See `constraints/BUCK` for details.

# Per-module compilation (experimental)

By default each `haskell_library()`/`haskell_binary()` is compiled by one
`ghc --make` action. With `per_module = True` (what `cabal buck2 --per-module`
sets on every target) a target is compiled one module per action instead:
a `ghc -M` action computes the module graph, and each module's `ghc -c` gets
a symlink tree of the interfaces and objects of its transitive imports. Buck2
then schedules the modules of a target in parallel with everything else, and
each module's action records in a dep file what it read, so after an edit
only the modules whose imports' ABI changed are recompiled, within a package
and across packages. The recompilation policy is exactly the one `ghc --make`
has, taken from the usages GHC writes into each interface (the imports, by
ABI hash, and the objects a Template Haskell splice loaded), decided per
action by buck2.

The cost is that each one-shot compile starts a GHC and loads the interfaces
of its imports (and, for Template Haskell, the shared libraries of the
dependencies), which `--make` does once per target: a target's modules take
several times the CPU in total, whether or not they use Template Haskell,
and a clean compile of a target is slower than with `--make` even with every
core busy. Which way is faster for a given project depends on how its time
divides between clean builds and rebuilds after small edits. The
implementation is `_compile_per_module` in `prelude/haskell/compile.bzl`.

Two settings help the per-module build and cost nothing elsewhere: run
buck2 with `-j` set to the number of physical cores (the one-shot compiles
gain nothing from SMT siblings and each takes memory), and give GHC a
larger allocation area, `compiler_flags = +RTS -A64m -RTS` in the
`[haskell]` section of the buckconfig (see below), which took 13% off the
per-module compiles of one project.

# Compiler and linker flags from the environment

buck2 runs every build action with a clean environment, so directories that
a shell makes visible to the compiler and linker through variables such as
`LIBRARY_PATH` or `CPATH` (a Nix or Homebrew shell, say) are not seen by GHC.
Give them to the Haskell toolchain through the project's buckconfig instead,
normally in a `.buckconfig.local` next to the `.buckconfig` at the root of
the project (it is read in addition to `.buckconfig`, and is for files that
don't belong in version control):

```
[haskell]
  compiler_flags = -I/opt/homebrew/include
  linker_flags = -L/opt/homebrew/lib -L/opt/zlib/lib
```

Both are space-separated lists of flags for every GHC invocation;
`compiler_flags` go to each compile and `linker_flags` to each link.

# Testing this repo

This repository has no tests or CI of its own: it is the Buck2 support code for
[cabal-buck2](https://github.com/simonmar/cabal-buck2), which includes it as a
submodule (`buck2/`) and tests it, with an example project (`example/`:
Template Haskell, hsc2hs, C++ via FFI and a Hackage dependency) and with its
own build. Update the submodule there to test a change here.

`template/` has the `.buckconfig` and `PACKAGE` that `cabal buck2` copies to a
project that doesn't have them.
