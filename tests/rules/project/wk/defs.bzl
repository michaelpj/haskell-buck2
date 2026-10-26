# An executable file as a program to run, as sh_binary() would give it but
# without its wrapper script, whose `#!/usr/bin/env bash` the nix sandbox
# can't run.
def _exe_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(default_output = ctx.attrs.exe),
        RunInfo(args = cmd_args(ctx.attrs.exe)),
    ]

exe = rule(
    impl = _exe_impl,
    attrs = {"exe": attrs.source()},
)
