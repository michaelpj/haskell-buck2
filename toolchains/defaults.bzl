load("@third-party-haskell//:tools.bzl", "CC_FINGERPRINT", "GHC_DYNAMIC", "GHC_FINGERPRINT", "GHC_VERSION")
load("@prelude//tests:test_toolchain.bzl", "noop_test_toolchain")
load("@prelude//toolchains:cxx.bzl", "system_cxx_toolchain")
load("@prelude//toolchains:genrule.bzl", "system_genrule_toolchain")
load("@prelude//toolchains:python.bzl", "system_python_bootstrap_toolchain")
load("@prelude//toolchains:remote_test_execution.bzl", "remote_test_execution_toolchain")
load(":haskell.bzl", "haskell_toolchain")

# The GHC that `cabal buck2` configured the project with.
CABAL_GHC = "ghc-" + GHC_VERSION
CABAL_GHC_PKG = "ghc-pkg-" + GHC_VERSION

# hsc2hs ships with GHC (as hsc2hs-<version>, e.g. hsc2hs-9.4.8).
CABAL_HSC2HS = "hsc2hs-" + GHC_VERSION

# The Haskell toolchain for a project set up by `cabal buck2`. A project can
# define its own toolchains cell and call this, overriding any attribute of
# haskell_toolchain(), e.g. to use a compiler that it builds itself.
#
# `compiler`/`packager` are resolved via $PATH at build-action time (see
# buck2/toolchains/haskell.bzl - this is a thin custom rule, not the
# prelude's own real haskell_toolchain, so there's no absolute-path
# resolution here), relying on the version-suffixed-binary convention
# most GHC install methods provide (e.g. `ghc-9.4.8` alongside the bare
# `ghc`) - not specific to any one of them (ghcup, distro packages, Nix,
# ...), see buck2/gen-haskell-prebuilt.py's own `_find_ghc()` for the same
# convention (with a bare-binary fallback) used to find GHC's own tools
# directly. GHC_VERSION itself comes from that script's own generated
# generated third-party/haskell/tools.bzl (in turn read from Cabal's
# plan.json - see that script's own comment) rather than being hardcoded
# here, so re-running that script after `cabal build all
# --only-dependencies -w ghc-<version>` retargets this too.
def default_haskell_toolchain(name, **kwargs):
    kwargs.setdefault("compiler", CABAL_GHC)
    kwargs.setdefault("packager", CABAL_GHC_PKG)
    kwargs.setdefault("haddock", "haddock")
    kwargs.setdefault("hsc2hs", CABAL_HSC2HS)
    kwargs.setdefault("compiler_flags", [])
    kwargs.setdefault("linker_flags", [])
    # GHC_DYNAMIC comes from buck2/gen-haskell-prebuilt.py's own probe
    # of this specific `ghc` binary (`ghc --info`'s `("GHC Dynamic",
    # ...)` entry) - not assumed - so retargeting GHC (per this file's
    # own comment on GHC_VERSION) picks this up automatically too.
    kwargs.setdefault("dynamic_ghc", GHC_DYNAMIC)
    # Under asan, GHC's own process needs the ASAN runtime already loaded
    # before Template Haskell dlopen's an asan-instrumented dependency
    # mid-compile (confirmed empirically - see buck2/prelude/haskell/
    # toolchain.bzl's own comment on `compile_env`, and buck2.md). The
    # runtime here must match whichever compiler actually produces this
    # project's cxx_library .so's - that's whatever `c++` resolves to via
    # `/etc/alternatives/c++` (clang, on this machine - see buck2/prelude/
    # toolchains/demo.bzl's system_cxx_toolchain, which auto-detects the
    # same way for *compiling*, even though the *link* step is hardcoded
    # to plain g++ there; mixing compile/link drivers is fine, but the
    # ASAN runtime ABI must match the *compiler*, not the linker).
    # Deliberately not a literal path: `compile_env`'s values are shell-
    # evaluated at build-action time (see haskell/compile.bzl), so this
    # tracks whatever `c++` and its runtime library layout actually are
    # on the machine doing the build, the same way `compiler`/`packager`
    # above resolve via $PATH rather than a baked-in absolute path. Only
    # actually correct while `c++` resolves to clang - if this project's
    # default cxx compiler ever moves to gcc, swap the runtime name to
    # `libasan.so` too (`gcc -print-file-name=libasan.so`).
    # CABAL_BUCK2_GHC and CABAL_BUCK2_CC are not read by anything: they are
    # there so that fingerprints of the GHC installation and of the C toolchain
    # (GHC_FINGERPRINT and CC_FINGERPRINT, see third-party/haskell/tools.bzl)
    # are part of every compile and link action, and so of its cache key.
    # `compiler` above is only a name found on the PATH, and the files of the
    # installations aren't tracked by buck2. GHC runs the C compiler to
    # preprocess a module that uses CPP, and to link.
    kwargs.setdefault("compile_env", select({
        "root//buck2/constraints:asan": {
            "CABAL_BUCK2_GHC": GHC_FINGERPRINT,
            "CABAL_BUCK2_CC": CC_FINGERPRINT,
            "LD_PRELOAD": "$(c++ -print-file-name=libclang_rt.asan-x86_64.so)",
            # This preload leaks into every subprocess GHC spawns while
            # compiling (not just the dlopen'd .so's it's actually for) -
            # including plain system tools like `ld`/`bash`/`gcc` that
            # aren't written to be leak-clean under a leak-checking
            # allocator and were never meant to be instrumented at all.
            # Disable leak detection for this incidental, build-tooling-
            # wide preload; the C++ code we actually care about checking
            # still gets real leak detection when the *final executable*
            # itself is linked with -fsanitize=address (see haskell.bzl's
            # _ASAN_LINKER_FLAGS), which is a separate, unaffected setting.
            "ASAN_OPTIONS": "detect_leaks=0",
        },
        "DEFAULT": {"CABAL_BUCK2_GHC": GHC_FINGERPRINT, "CABAL_BUCK2_CC": CC_FINGERPRINT},
    }))
    kwargs.setdefault("link_env", {"CABAL_BUCK2_GHC": GHC_FINGERPRINT, "CABAL_BUCK2_CC": CC_FINGERPRINT})
    kwargs.setdefault("visibility", ["PUBLIC"])
    haskell_toolchain(name = name, **kwargs)

# The toolchains besides Haskell's that the rules of a project set up by
# `cabal buck2` use. The project's C and C++ compiler flags (`c_flags`,
# `cxx_flags`: e.g. its language standard and target CPU) are the C/C++
# toolchain's.
def default_toolchains(c_flags = [], cxx_flags = []):
    system_cxx_toolchain(
        name = "cxx",
        c_flags = c_flags,
        cxx_flags = cxx_flags,
        linker = "g++",
        visibility = ["PUBLIC"],
    )

    # The C++ toolchain's default names this in an arm of a select() that is
    # never chosen (see _cxx_toolchain() in decls/toolchains_common.bzl), so
    # it only has to exist: for queries of the unconfigured graph (uquery),
    # which follow every arm.
    native.alias(
        name = "cxx_no_default_deps",
        actual = ":cxx",
        visibility = ["PUBLIC"],
    )

    system_genrule_toolchain(
        name = "genrule",
        visibility = ["PUBLIC"],
    )

    system_python_bootstrap_toolchain(
        name = "python_bootstrap",
        visibility = ["PUBLIC"],
    )

    remote_test_execution_toolchain(
        name = "remote_test_execution",
        visibility = ["PUBLIC"],
    )

    noop_test_toolchain(
        name = "test",
        visibility = ["PUBLIC"],
    )
