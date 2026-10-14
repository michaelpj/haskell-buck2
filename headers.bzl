# The headers of other targets, without their libraries: for C code that
# GHC would have given the include directories of the packages it depends on.
# Depending on the packages themselves would link them in as well, and in a
# profiling build, with the wrong libraries.

load("@prelude//cxx:preprocessor.bzl", "cxx_inherited_preprocessor_infos", "cxx_merge_cpreprocessors")

def _headers_of_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        cxx_merge_cpreprocessors(ctx.actions, [], cxx_inherited_preprocessor_infos(ctx.attrs.deps)),
    ]

headers_of = rule(
    impl = _headers_of_impl,
    attrs = {"deps": attrs.list(attrs.dep(), default = [])},
)
