# The persistent worker of the per-module compiles, when the project builds
# it from source (`per_module_worker = local`, see toolchains/
# per_module_worker.bzl). buck2 starts one process for each WorkerInfo the
# actions name, so the targets share a worker by naming this one target,
# which makes it once. The toolchain makes its own the same way for a
# worker it has (see per_module_worker_info), but can't for this one (see
# Note [The persistent worker] in prelude/haskell/compile.bzl).

load("@prelude//decls:toolchains_common.bzl", "toolchains_common")
load("@prelude//haskell:toolchain.bzl", "HaskellToolchainInfo", "per_module_worker_info")

def _haskell_per_module_worker_impl(ctx: AnalysisContext) -> list[Provider]:
    worker = ctx.attrs.worker[RunInfo]
    toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    return [
        DefaultInfo(),
        per_module_worker_info(worker, toolchain.compile_env, toolchain.per_module_worker_rts_options, toolchain.per_module_worker_sessions, toolchain.per_module_worker_session_mode, toolchain.per_module_worker_build_tools_dir),
    ]

haskell_per_module_worker = rule(
    impl = _haskell_per_module_worker_impl,
    attrs = {
        # The worker program (tools/ghc-worker's executable).
        "worker": attrs.exec_dep(providers = [RunInfo]),
        "_haskell_toolchain": toolchains_common.haskell(),
    },
)
