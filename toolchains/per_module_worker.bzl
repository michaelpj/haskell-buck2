load("@third-party-haskell//:tools.bzl", "GHC_WORKER_TARGET")

# The persistent worker of the per-module compiles (tools/ghc-worker), as
# `[haskell] per_module_worker` in the buckconfig says:
#
# - unset or "none": no worker; each module is compiled by a `ghc -c` of its
#   own;
# - "local": the project's own target for it (GHC_WORKER_TARGET), which
#   `cabal buck2` writes when the project builds it from source. Each
#   per-module target that cabal.bzl generates names it, since the toolchain
#   can't (see Note [The persistent worker] in prelude/haskell/compile.bzl);
#   a hand-written target sets per_module_worker itself;
# - anything else: that program, a path or a name on $PATH, which the
#   toolchain uses.

# The target that makes the shared worker of the project's own (see
# worker.bzl) is named after the worker's executable with this.
PER_MODULE_WORKER_SUFFIX = "-shared"

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
    return GHC_WORKER_TARGET + PER_MODULE_WORKER_SUFFIX

# Whether the BUCK package being loaded is the worker's own (GHC_WORKER_TARGET's
# package), whose targets compile without it.
def in_worker_package() -> bool:
    return GHC_WORKER_TARGET != None and GHC_WORKER_TARGET.split(":")[0] == "//" + native.package_name()

# Whether the target of that name in the BUCK package being loaded is the
# worker's executable, GHC_WORKER_TARGET.
def is_worker_target(name: str) -> bool:
    return GHC_WORKER_TARGET == "//{}:{}".format(native.package_name(), name)

def has_per_module_worker() -> bool:
    return _configured() != "none"

# The RTS options of the worker the targets share, `[haskell]
# per_module_worker_rts_options` in the buckconfig. The worker's heap is
# shared by all its compiles, and each collection stops them all, so the
# time a collection takes is time no module compiles. So the default:
#
# - has a large allocation area (-A64m), since the process runs many
#   compiles at once, split into chunks (-n4m) that a capability that runs
#   out can take from the others;
# - collects with 8 threads (-qn8), rather than 4, or the RTS's default of
#   one for each capability.
#
# On the worker's bench (`project`, -j8, three runs each; see
# tools/ghc-worker/DESIGN.md), 8 threads took 20.5-22.1s with 2.4-2.5s of
# collections, 4 threads 22.0-23.7s with 3.7-3.9s, and one per capability
# 21.0-21.4s with 3.5-3.6s. A larger area means fewer collections but
# costs memory: -A128m and -A256m took 1.6-3.7 GB more at peak, for no
# clear gain in time. The area is per capability and kept all the build:
# with -N on a machine of many cores, a smaller -A, or a -maxN, keeps it in
# check.
def per_module_worker_rts_options() -> list[str]:
    return (read_root_config("haskell", "per_module_worker_rts_options", "") or "-A64m -n4m -qn8").split()

# The most sessions the shared worker keeps, in use or idle, `[haskell]
# per_module_worker_sessions` in the buckconfig; unset, the worker keeps as
# many as it has capabilities. A session dropped while its target is
# part-built is made again for its next module. That is cheap for a
# one-shot session, whose interfaces the worker keeps for all of them, but
# a --make session (see per_module_worker_session_mode) holds the
# interfaces its target has read, a few hundred MB for a large one, and
# reads them again. So the limit changes little for one-shot sessions, and
# trades memory for speed for --make sessions. See Note [Dropping the idle
# sessions] in tools/ghc-worker/src/Worker.hs, which has the bench's
# figures.
def per_module_worker_sessions() -> str:
    return read_root_config("haskell", "per_module_worker_sessions", "")

# How the shared worker compiles, `[haskell] per_module_worker_session_mode`
# in the buckconfig:
#
#   - auto (the worker's default, when unset): one-shot for the targets
#     without hs-boot files, sharing the interfaces they read, and GHC's
#     --make mode for the others;
#   - make: --make for every target, each session reading its interfaces
#     itself;
#   - one-shot: one-shot for every target, failing the compiles of a target
#     with hs-boot files.
#
# See Note [One-shot sessions] in tools/ghc-worker/src/Session.hs.
def per_module_worker_session_mode() -> str:
    return read_root_config("haskell", "per_module_worker_session_mode", "")

# The build tools on the shared worker's PATH, `[haskell]
# per_module_worker_build_tools` in the buckconfig: targets, separated by
# spaces. A target whose build tools are all among them compiles in the
# shared worker; one with any other build tool compiles without a worker,
# since the worker has one PATH for all its compiles. So list the tools that
# many targets share (tasty-discover, say). A tool built with the Haskell
# toolchain can't be one, as the toolchain would depend on itself.
def per_module_worker_build_tools() -> list[str]:
    return read_root_config("haskell", "per_module_worker_build_tools", "").split()
