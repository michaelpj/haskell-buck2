# ghc-worker

A [buck2 persistent worker](https://buck2.build/docs/users/advanced/persistent_workers/)
for the per-module compiles of `haskell_library(per_module = True)` (see
the repository README). Without it each module is compiled by its own
`ghc -c` process, which starts GHC and reads the interfaces of every import
again; with it buck2 sends the compiles of a target to one process per
target, which compiles each as it arrives, concurrently, in a single GHC
session that keeps what it has read, as `ghc --make -j` does for the
modules of a package. The per-action scheduling and early cut-off of the
per-module build are unchanged.

## Building or installing

The worker links against the `ghc` library of the GHC it compiles with, so
it is built with that GHC, dynamically (the cabal file says so). It uses
GHC's API, which changes with each major release: it supports GHC 9.6 to
9.14 (the cabal file says so too), and supporting another release means
following that release's API. Before GHC 9.12 there is no
`-fobject-determinism`, so a module's object may differ from one compile
to the next and buck2 links the library again after an edit that changed
nothing else.

The rules use it only when `per_module_worker` in the `[haskell]` section
of the project's buckconfig (`.buckconfig.local`, say) says so. With it
unset, or `none`, each module is compiled by a `ghc -c` of its own.

The simplest way to have it is as a package of the project:

```
packages: . buck2/tools/ghc-worker
```

in `cabal.project`. `cabal buck2` then generates a target for it like any
other package, and buck2 builds it with the project's GHC before the first
per-module compile, when the buckconfig says:

```
[haskell]
  per_module_worker = local
```

Its dependencies (`http2`, `http-semantics`, `network` and a few boot
packages) join the project's build plan.

Or, to keep it out of the project's plan, install it with the project's
GHC, under a name that says which GHC that is, as `ghc` itself and
`hsc2hs` are:

```
cd buck2/tools/ghc-worker
cabal install --program-suffix=-$(ghc --numeric-version) exe:ghc-worker
```

and name it in the buckconfig, by its path or its name on `$PATH`:

```
[haskell]
  per_module_worker = ghc-worker-9.10.3
```

A worker installed for another version of the rules refuses their
compiles, saying so: install it again from the rules' `tools/ghc-worker`.

buck2 sends a worker as many compiles at once as its `-j` allows, with the
other actions. `GHC_WORKER_VERBOSE=1` in the environment of the buck2
daemon makes each worker log the time of each compile to its stderr file
under `/tmp/buck2_worker/`.

## Testing

`cabal test` compiles a small package through the built worker, one
request per module as the rules send them, both in one worker process and
with a process per request, and checks what it writes. CI
(`.github/workflows/ghc-worker.yml`) builds and tests the worker with the
GHC versions it supports. The rules' use of the worker is exercised by
cabal-buck2's CI, on its example.

How the worker works is described in the code: Note [The persistent
worker] in the rules' `prelude/haskell/compile.bzl`, and Note [The
session's state] in `src/Session.hs`.
