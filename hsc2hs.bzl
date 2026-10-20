# A rule for running hsc2hs.
#
load("@prelude//cxx:cxx_context.bzl", "get_cxx_toolchain_info")
load("@prelude//cxx:preprocessor.bzl", "cxx_inherited_preprocessor_infos", "cxx_merge_cpreprocessors")
load("@prelude//decls/toolchains_common.bzl", "toolchains_common")
load("@prelude//haskell:toolchain.bzl", "HaskellToolchainInfo")
load("@third-party-haskell//:tools.bzl", "CC_FINGERPRINT", "GHC_FINGERPRINT")

def _hsc2hs_include_args(pp_info):
    return [
        cmd_args(pp_info.set.project_as_args("include_dirs"), format = "--cflag={}"),
        cmd_args(pp_info.set.project_as_args("args"), format = "--cflag={}"),
    ]

def _hsc2hs_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.attrs.out)

    pp_infos = cxx_inherited_preprocessor_infos(ctx.attrs.deps)
    merged = cxx_merge_cpreprocessors(ctx.actions, [], pp_infos)

    hsc2hs_tool = ctx.attrs._haskell_toolchain[HaskellToolchainInfo].hsc2hs

    # C++, unless told otherwise: some of the .hsc files need the headers of
    # C++ code. A package that is only C (Cabal's way) must not be compiled as
    # C++, which doesn't accept what hsc2hs generates for #alignment.
    cxx_toolchain = get_cxx_toolchain_info(ctx)
    compiler_info = cxx_toolchain.cxx_compiler_info if ctx.attrs.cxx else cxx_toolchain.c_compiler_info
    compiler = compiler_info.compiler

    # hsc2hs wants a single program, but the compiler is a command (with the
    # cache, it is `env` setting a fingerprint, then the compiler).
    cc, cc_hidden = ctx.actions.write("cc.sh", ["#!/bin/sh", cmd_args("exec", compiler, '"$@"', delimiter = " ")], is_executable = True, allow_args = True)

    cmd = cmd_args(
        hsc2hs_tool,
        cmd_args("--cc=", cmd_args(cc, hidden = cc_hidden), delimiter = ""),
        # The project's flags for the language (see default_toolchains()).
        cmd_args(compiler_info.compiler_flags, format = "--cflag={}"),
        "-C",
        "-D__HSC2HS__=1",
        ctx.attrs.extra_flags,
        # The hsc file's own package dir, so `#include "foo.h"`/`<foo.h>`
        # against a local (non-exported) header resolves, same as it would
        # when compiling a sibling cxx_library() source in this package.
        "-I" + ("." if ctx.label.package == "" else ctx.label.package),
        _hsc2hs_include_args(merged),
        "-o",
        out.as_output(),
        ctx.attrs.hsc_file,
    )
    # The fingerprints are not read by hsc2hs: they make the GHC installation
    # and the C toolchain part of the action's cache key (see toolchains/BUCK).
    ctx.actions.run(cmd, category = "hsc2hs", env = {"CABAL_BUCK2_GHC": GHC_FINGERPRINT, "CABAL_BUCK2_CC": CC_FINGERPRINT})

    return [DefaultInfo(default_output = out)]

# Runs hsc2hs on `hsc_file`, producing `out`. `deps` is used purely to
# collect C/C++ include paths (via CPreprocessorInfo); it doesn't need to be
# (and usually isn't) the same as the consuming haskell_library()'s deps.
hsc2hs = rule(
    impl = _hsc2hs_impl,
    attrs = {
        "cxx": attrs.bool(default = True),
        "deps": attrs.list(attrs.dep(), default = []),
        "extra_flags": attrs.list(attrs.arg(), default = []),
        "hsc_file": attrs.source(),
        "out": attrs.string(),
        "_cxx_toolchain": toolchains_common.cxx(),
        "_haskell_toolchain": toolchains_common.haskell(),
    },
)
