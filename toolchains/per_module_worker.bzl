load("@third-party-haskell//:tools.bzl", "GHC_WORKER_TARGET")

# The persistent worker of the per-module compiles (tools/ghc-worker), as
# `[haskell] per_module_worker` in the buckconfig says:
#
# - unset or "none": no worker; each module is compiled by a `ghc -c` of its
#   own;
# - "local": the project's own target for it (GHC_WORKER_TARGET), which
#   `cabal buck2` writes when the project builds it from source. The
#   toolchain can't depend on a target of the project, so each per-module
#   target names it (see cabal.bzl);
# - anything else: that program, a path or a name on $PATH, which the
#   toolchain uses.

def _configured() -> str:
    return read_root_config("haskell", "per_module_worker", "") or "none"

def toolchain_per_module_worker() -> str | None:
    configured = _configured()
    return None if configured in ("none", "local") else configured

def project_per_module_worker() -> str | None:
    if _configured() != "local":
        return None
    if GHC_WORKER_TARGET == None:
        fail("[haskell] per_module_worker = local, but the project doesn't build the worker: add buck2/tools/ghc-worker to the packages of its cabal.project, and run `cabal buck2` again")
    return GHC_WORKER_TARGET

def has_per_module_worker() -> bool:
    return _configured() != "none"
