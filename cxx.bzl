_ASAN_CXX_FLAGS = select({
    "root//buck2/constraints:asan": ["-fsanitize=address"],
    "DEFAULT": [],
})

_BUILD_MODE_CXX_FLAGS = select({
    "root//buck2/constraints:opt": select({
        "root//buck2/constraints:asan": ["-g"],
        "DEFAULT": ["-O3", "-DNDEBUG"],
    }),
    "DEFAULT": ["-g"],
})

_COMMON_CXX_FLAGS = ["-fno-omit-frame-pointer"] + _ASAN_CXX_FLAGS + _BUILD_MODE_CXX_FLAGS

def cxx_library(name, compiler_flags = [], linker_flags = [], **kwargs):
    native.cxx_library(
        name = name,
        compiler_flags = compiler_flags + _COMMON_CXX_FLAGS,
        # -fsanitize=address has to reach the *linker* too
        linker_flags = _ASAN_CXX_FLAGS + linker_flags,
        **kwargs
    )

def cxx_binary(name, compiler_flags = [], linker_flags = [], **kwargs):
    native.cxx_binary(
        name = name,
        compiler_flags = compiler_flags + _COMMON_CXX_FLAGS,
        linker_flags = _ASAN_CXX_FLAGS + linker_flags,
        **kwargs
    )
