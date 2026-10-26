# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

# If the target is a haskell library, the HaskellLibraryProvider
# contains its HaskellLibraryInfo. (in contrast to a HaskellLinkInfo,
# which contains the HaskellLibraryInfo for all the transitive
# dependencies). Direct dependencies are treated differently from
# indirect dependencies for the purposes of module visibility.
HaskellLibraryProvider = provider(
    fields = {
        "lib": provider_field(typing.Any, default = None),  # dict[LinkStyle, HaskellLibraryInfo]
        "prof_lib": provider_field(typing.Any, default = None),  # dict[LinkStyle, HaskellLibraryInfo]
    },
)

# The files of a module compiled per module that its dependents' modules
# read: its interface, the file of its ABI hash, and for a -dynamic-too
# compile its dynamic interface.
HaskellModuleFiles = record(
    hi = field(Artifact),
    abi = field(Artifact),
    dyn_hi = field(Artifact | None, None),
)

# A record of a Haskell library.
HaskellLibraryInfo = record(
    # The library target name: e.g. "rts"
    name = str,
    # package config database: e.g. platform009/build/ghc/lib/package.conf.d
    db = Artifact,
    # e.g. "base-4.13.0.0"
    id = str,
    # Import dirs indexed by profiling enabled/disabled
    import_dirs = dict[bool, Artifact],
    stub_dirs = list[Artifact],
    # This field is only used as hidden inputs to compilation, to
    # support Template Haskell which may need access to the libraries
    # at compile time.  The real library flags are propagated up the
    # dependency graph via MergedLinkInfo.
    libs = field(list[Artifact], []),
    # Package version, used to specify the full package when exposing it,
    # e.g. filepath-1.4.2.1, deepseq-1.4.4.0.
    # Internal packages default to 1.0.0, e.g. `fbcode-dsi-logger-hs-types-1.0.0`.
    version = str,
    is_prebuilt = bool,
    profiling_enabled = bool,
    # The rest are set for a library compiled per module only: see Note
    # [Compiling against dependencies module by module] in compile.bzl.
    # Its package db without the library, registered before anything is
    # compiled.
    early_db = field(Artifact | None, None),
    # Each module's files, by module name.
    modules = field(dict[str, HaskellModuleFiles] | None, None),
    # Each module's transitive closure of imports across packages, as JSON:
    # module -> list of [package id, module].
    closures = field(Artifact | None, None),
    # The "<package path>/__<target>__/" part of the path of its interfaces'
    # directory, by which dependents match `ghc -M` output to it.
    module_dir_tail = field(str | None, None),
)

HaskellLibraryInfoTSet = transitive_set()
