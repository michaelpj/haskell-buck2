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
`ghc --make` action. With `per_module = True` (which
`cabal buck2 --per-module` sets on every target), each module is compiled
by an action of its own. buck2 then compiles a target's modules in
parallel with everything else it has to do, and after an edit recompiles
only the modules that GHC's own recompilation check would: a comment-only
edit recompiles the one module, and a change to a module's interface
recompiles the modules that import it.

Across targets, a module waits only for the modules it imports from a
dependency that is itself compiled per module, not for the whole
dependency, so it can start before that dependency is fully compiled, let
alone linked. The exception is a module that runs Template Haskell (or
evaluates an `ANN` pragma), which needs the dependencies' libraries and
waits for all of them to be linked. Which modules run Template Haskell is
decided by the extensions they (or their target) enable, so enabling
`TemplateHaskell` for a whole package makes all of its modules wait.

The cost is CPU. Each module's compile starts a GHC and reads the
interfaces of its imports, which `--make` does once per target, so a
target's modules take several times the CPU in total, and a clean compile
of a target is slower than with `--make` even with every core busy. Which
way is faster for a project depends on how its time divides between clean
builds and rebuilds after small edits.

Two settings help the per-module build and cost nothing elsewhere: run
buck2 with `-j` set to the number of physical cores (the compiles gain
nothing from SMT siblings, and each takes memory), and give GHC a larger
allocation area, `compiler_flags = +RTS -A64m -RTS` in the `[haskell]`
section of the buckconfig (see below), which took 13% off the per-module
compiles of one project.

The persistent worker in `tools/ghc-worker` takes away much of that CPU cost:
buck2 sends the compiles of a target to one long-running process, which
compiles them in a single GHC session and so reads each interface once.
`per_module_worker` in the `[haskell]` section of the buckconfig says
which to use:

- `local`: the project's own, which buck2 builds with the project's GHC
  (add `buck2/tools/ghc-worker` to the packages of `cabal.project`);
- a path, or a name on `$PATH`: one installed with the project's GHC (see
  `tools/ghc-worker/README.md`);
- `none`, or unset: no worker.

The worker is used when buck2 runs the compiles locally.

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
