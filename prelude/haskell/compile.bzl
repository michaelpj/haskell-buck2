# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load(
    "@prelude//cxx:preprocessor.bzl",
    "cxx_inherited_preprocessor_infos",
    "cxx_merge_cpreprocessors",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfoTSet",
    "HaskellLibraryProvider",
    "HaskellModuleFiles",
)
load(
    "@prelude//haskell:link_info.bzl",
    "HaskellLinkInfo",
)
load(
    "@prelude//linking:shared_libraries.bzl",
    "SharedLibraryInfo",
    "create_shlib_symlink_tree",
    "merge_shared_libraries",
    "traverse_shared_library_info",
)
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
    "attr_deps_haskell_lib_infos",
    "attr_deps_haskell_link_infos",
    "get_artifact_suffix",
    "haskell_library_unit_id",
    "is_haskell_src",
    "module_name_to_file",
    "output_extensions",
    "srcs_to_pairs",
)
load(
    "@prelude//linking:link_info.bzl",
    "LinkStyle",
)
load("@prelude//utils:argfile.bzl", "at_argfile")

# The type of the return value of the `_compile()` function.
CompileResultInfo = record(
    objects = field(Artifact),
    hi = field(Artifact),
    stubs = field(Artifact),
    producing_indices = field(bool),
    # Per-module compilation only: see HaskellLibraryInfo's fields of the
    # same names.
    modules = field(dict[str, HaskellModuleFiles] | None, None),
    closures = field(Artifact | None, None),
    owner = field(str | None, None),
)

CompileArgsInfo = record(
    result = field(CompileResultInfo),
    srcs = field(cmd_args),
    args_for_cmd = field(cmd_args),
    args_for_file = field(cmd_args),
)

PackagesInfo = record(
    exposed_package_args = cmd_args,
    packagedb_args = cmd_args,
    transitive_deps = field(HaskellLibraryInfoTSet),
)

def _package_flag(toolchain: HaskellToolchainInfo) -> str:
    if toolchain.support_expose_package:
        return "-expose-package"
    else:
        return "-package"

def get_packages_info(ctx: AnalysisContext, link_style: LinkStyle, specify_pkg_version: bool, enable_profiling: bool) -> PackagesInfo:
    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    libs = _dependency_libs(ctx, link_style, enable_profiling)

    exposed_package_args = cmd_args()

    packagedb_args = cmd_args()
    packagedb_set = {}

    for lib in libs.traverse():
        packagedb_set[lib.db] = None
        hidden_args = cmd_args(
            hidden = [
                lib.import_dirs.values(),
                lib.stub_dirs,
                # libs of dependencies might be needed at compile time if
                # we're using Template Haskell:
                lib.libs,
            ]
        )

        exposed_package_args.add(hidden_args)

        packagedb_args.add(hidden_args)

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add([cmd_args("-package-db", x) for x in packagedb_set])

    exposed_package_args.add(_exposed_package_args(ctx, link_style, specify_pkg_version, enable_profiling))

    return PackagesInfo(
        exposed_package_args = exposed_package_args,
        packagedb_args = packagedb_args,
        transitive_deps = libs,
    )

def _dependency_libs(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool) -> HaskellLibraryInfoTSet:
    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)
    return ctx.actions.tset(
        HaskellLibraryInfoTSet,
        children = [lib.prof_info[link_style] if enable_profiling else lib.info[link_style] for lib in direct_deps_link_info],
    )

def _exposed_package_args(ctx: AnalysisContext, link_style: LinkStyle, specify_pkg_version: bool, enable_profiling: bool) -> cmd_args:
    package_flag = _package_flag(ctx.attrs._haskell_toolchain[HaskellToolchainInfo])
    exposed_package_args = cmd_args()
    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        link_style,
        enable_profiling,
    )

    # Expose only the packages we depend on directly
    for lib in haskell_direct_deps_lib_infos:
        # The rts has no modules to import, and is a dependency to be linked
        # with. GHC warns about exposing a package that is not used
        # (-Wunused-packages), which is an error in some projects.
        if lib.name == "rts":
            continue
        if lib.id:
            # Resolve by unit id rather than by name: unambiguous even when
            # another version of the same package is visible in another
            # package db (e.g. GHC's global db vs. a cabal-store rebuild of a
            # boot package such as time or directory, or a global Cabal
            # vs. one built from source here).
            exposed_package_args.add("-package-id", lib.id)
            continue

        pkg_name = lib.name
        if specify_pkg_version:
            pkg_name += "-{}".format(lib.version)

        exposed_package_args.add(package_flag, pkg_name)

    return exposed_package_args

# The package db flags of a per-module compile for the given libraries (the
# dependencies, direct and transitive), and the inputs they bring: the final
# dbs of those in `final` (None: all of them) and of those not compiled per
# module, and the early dbs of the rest, which bring no inputs (the compile
# declares the interfaces it imports itself). Also run in the dynamic
# output, for the modules that choose their own final dbs (see
# _compile_per_module), so it takes the libraries rather than an analysis
# context. `runs_th`: for a module that runs Template Haskell, which loads
# the libraries (see Note [Template Haskell modules]).
def _package_dbs(libs: list, final: [dict[str, bool], None], import_dirs_tag, runs_th: bool):
    packagedb_args = cmd_args()
    packagedb_set = {}
    local_import_dirs = []
    early_names = {}
    for lib in libs:
        if final != None and lib.early_db != None and lib.name not in final:
            packagedb_set[lib.early_db] = None
            early_names[lib.name] = True
            continue
        packagedb_set[lib.db] = None
        import_dirs = list(lib.import_dirs.values())
        local_import_dirs += [d for d in import_dirs if not d.is_source]
        # The interfaces a module reads are in its dep file. The libraries
        # a Template Haskell module loads aren't (see Note [Template Haskell
        # modules]), so they are plain inputs of its compile; a module that
        # runs none loads none, so doesn't wait for them to be linked.
        packagedb_args.add(cmd_args(hidden = [
            lib.stub_dirs,
            import_dirs_tag.tag_artifacts(cmd_args(hidden = import_dirs)),
            lib.libs if runs_th else [],
        ]))

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add([cmd_args("-package-db", x) for x in packagedb_set])
    return struct(packagedb_args = packagedb_args, local_import_dirs = local_import_dirs, early_names = early_names)

def _ghc_flags(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname = None, dynamic_too: bool = False) -> (cmd_args, cmd_args):
    # The flags of a compile of the context's sources other than its
    # outputs, packages and sources: those for the command line, and those
    # that may go in an argsfile.
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    compile_cmd = cmd_args()
    compile_cmd.add(haskell_toolchain.compiler_flags)

    # Some rules pass in RTS (e.g. `+RTS ... -RTS`) options for GHC, which can't
    # be parsed when inside an argsfile.
    compile_cmd.add(ctx.attrs.compiler_flags)

    compile_args = cmd_args()
    compile_args.add("-no-link", "-i")
    compile_args.add("-package-env=-")

    # Without this, GHC's own implicit global package db (always loaded,
    # independent of anything passed via -package-db below) leaks in
    # alongside the deps get_packages_info() computes - normally harmless
    # (nothing there collides with an ordinary project's own package
    # names), but GHC ships boot libraries under names a project can
    # itself build from source under the same name (e.g. `Cabal`,
    # `Cabal-syntax`) - then both the boot copy (auto-exposed globally)
    # and this target's own explicitly `-package-id`-exposed one export
    # the same module name, and GHC fails with "Ambiguous module name"
    # for any of that module's importers, even though the -package-id
    # given to *this* compile is perfectly unambiguous on its own.
    # get_packages_info() already computes exactly the exposure set this
    # compile needs (direct deps + base, see its own comment) - with
    # `-hide-all-packages` GHC uses only that, ignoring the global db's
    # own default exposure entirely.
    compile_args.add("-hide-all-packages")

    if enable_profiling:
        compile_args.add("-prof")

    if link_style == LinkStyle("shared"):
        compile_args.add("-dynamic", "-fPIC")
    elif link_style == LinkStyle("static_pic"):
        compile_args.add("-fPIC", "-fexternal-dynamic-refs")

    if dynamic_too:
        # Produces .dyn_o/.dyn_hi alongside this compile's ordinary .o/.hi,
        # in the same -odir/-hidir (the only way to get both from GHC in
        # --make mode - there's no flag to write them to different
        # directories). GHC guarantees these are consistent with the
        # primary .o/.hi, since they come from the same compile pass and
        # share its frontend work - unlike reusing an *independently*
        # compiled "shared" variant's interfaces would be, which carries no
        # such guarantee. See haskell.bzl's use of this (building a
        # library's static archive and shared library from a single
        # -dynamic-too compile instead of two independent ones) for why
        # this matters enough to ask for explicitly rather than just
        # tolerating two compiles.
        compile_args.add("-dynamic-too")

    osuf, hisuf = output_extensions(link_style, enable_profiling)
    compile_args.add("-osuf", osuf, "-hisuf", hisuf)

    if getattr(ctx.attrs, "main", None) != None:
        compile_args.add(["-main-is", ctx.attrs.main])

    # Add args from preprocess-able inputs: for the C preprocessor of Haskell
    # code, and for the C that GHC compiles itself:
    #   foreign import capi "Header.h ..." ...
    # generates a C file that includes Header.h, so we need to pass the
    # preprocessor options via -optc too.
    inherited_pre = cxx_inherited_preprocessor_infos(attr_deps(ctx))
    pre = cxx_merge_cpreprocessors(ctx.actions, [], inherited_pre)
    pre_args = pre.set.project_as_args("args")
    compile_args.add(cmd_args(pre_args, format = "-optP={}"))
    compile_args.add(cmd_args(pre_args, format = "-optc={}"))

    if pkgname:
        compile_args.add(["-this-unit-id", pkgname])

    return compile_cmd, compile_args

def _producing_indices(ctx: AnalysisContext) -> bool:
    toolchain_flags = ctx.attrs._haskell_toolchain[HaskellToolchainInfo].compiler_flags or []
    return "-fwrite-ide-info" in toolchain_flags + ctx.attrs.compiler_flags

def compile_args(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname = None, suffix: str = "", native_shared_libs_dir: [Artifact, None] = None, dynamic_too: bool = False) -> CompileArgsInfo:
    compile_cmd, compile_args = _ghc_flags(ctx, link_style, enable_profiling, pkgname, dynamic_too)

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling, suffix)

    objects = ctx.actions.declare_output(
        "objects-" + artifact_suffix,
        dir = True,
        has_content_based_path = False,
    )
    hi = ctx.actions.declare_output("hi-" + artifact_suffix, dir = True, has_content_based_path = False)
    stubs = ctx.actions.declare_output("stubs-" + artifact_suffix, dir = True, has_content_based_path = False)

    compile_args.add(
        "-odir",
        objects.as_output(),
        "-hidir",
        hi.as_output(),
        "-hiedir",
        hi.as_output(),
        "-stubdir",
        stubs.as_output(),
    )

    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.
    packages_info = get_packages_info(
        ctx,
        link_style,
        specify_pkg_version = False,
        enable_profiling = enable_profiling,
    )

    compile_args.add(packages_info.exposed_package_args)
    compile_args.add(packages_info.packagedb_args)

    arg_srcs = []
    hidden_srcs = []
    for _, src in srcs_to_pairs(ctx.attrs.srcs):
        # hs-boot files aren't expected to be an argument to compiler but does need
        # to be included in the directory of the associated src file
        if is_haskell_src(src):
            arg_srcs.append(src)
        else:
            hidden_srcs.append(src)
    srcs = cmd_args(
        arg_srcs,
        hidden = hidden_srcs,
    )

    if native_shared_libs_dir != None:
        # Template Haskell splices run *during* this compile action (not at
        # final-link time), and GHC resolves them by dlopen()-ing the actual
        # shared objects of every package involved - including, transitively,
        # any native (cxx_library) shared libraries a Haskell dependency
        # dynamically links against. The dynamic loader needs to find those
        # on its own search path right now, in this sandboxed process, or
        # dlopen fails with "cannot open shared object file" even though the
        # eventual link of this target would have resolved them fine via an
        # rpath. Pointing LD_LIBRARY_PATH at the same merged symlink tree
        # used for the final binary's rpath (see haskell_binary_impl /
        # _build_haskell_lib) covers this without needing to know in advance
        # which dependency, if any, actually uses Template Haskell.
        compile_args.add(cmd_args(hidden = native_shared_libs_dir))

    return CompileArgsInfo(
        result = CompileResultInfo(
            objects = objects,
            hi = hi,
            stubs = stubs,
            producing_indices = _producing_indices(ctx),
        ),
        srcs = srcs,
        args_for_cmd = compile_cmd,
        args_for_file = compile_args,
    )

# The environment GHC runs in: the toolchain's compile_env, and the build
# tools on PATH. As the prefix of a `sh -c` script and the arguments it
# shifts off first (see _in_env); a build tool directory is made under the
# given name.
def _ghc_env(ctx: AnalysisContext, build_tool_dir: str):
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    # compile_env's values are shell-evaluated (via `sh -c`) rather than
    # passed straight through as literal env values - this lets a value
    # like "$(clang -print-file-name=libclang_rt.asan-x86_64.so)" get
    # resolved fresh at actual build-action execution time, matching this
    # project's existing convention of resolving tools via $PATH at
    # build-action time rather than baking absolute host paths into .bzl
    # or BUCK files (see toolchains/BUCK's `compiler`/`packager`).
    script = "".join([
        'export {}="{}"; '.format(name, value)
        for name, value in haskell_toolchain.compile_env.items()
    ]) if haskell_toolchain.compile_env else ""
    args = []

    build_tool_dirs = {
        dep[DefaultInfo].default_outputs[0].basename: dep[DefaultInfo].default_outputs[0]
        for dep in ctx.attrs.build_tool_depends
    }
    if build_tool_dirs:
        script += 'export PATH="$PATH:$1"; shift; '
        args.append(ctx.actions.symlinked_dir(build_tool_dir, build_tool_dirs, has_content_based_path = False))
    return struct(script = script, args = args)

# A command run in such an environment.
def _in_env(env, cmd: cmd_args) -> cmd_args:
    if not env.script:
        return cmd
    return cmd_args(["sh", "-c", env.script + 'exec "$@"', "sh"] + env.args, cmd)

# Compile all the context's sources.
def compile(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None = None, native_shared_libs_dir: [Artifact, None] = None, dynamic_too: bool = False) -> CompileResultInfo:
    # A target with no modules (all its code is C, say) has nothing for GHC
    # to compile, per module or not.
    has_modules = any([is_haskell_src(src) for _, src in srcs_to_pairs(ctx.attrs.srcs)])
    if getattr(ctx.attrs, "per_module", False) and has_modules:
        return _compile_per_module(ctx, link_style, enable_profiling, pkgname, native_shared_libs_dir, dynamic_too)
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    compile_cmd = cmd_args(haskell_toolchain.compiler)

    args = compile_args(ctx, link_style, enable_profiling, pkgname, native_shared_libs_dir = native_shared_libs_dir, dynamic_too = dynamic_too)

    if not has_modules:
        result = args.result
        ctx.actions.run(
            cmd_args("mkdir", "-p", result.objects.as_output(), result.hi.as_output(), result.stubs.as_output()),
            category = "haskell_compile_" + get_artifact_suffix(link_style, enable_profiling).replace("-", "_"),
        )
        return result

    compile_cmd.add(args.args_for_cmd)

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    if args.args_for_file:
        if haskell_toolchain.use_argsfile:
            compile_cmd.add(
                at_argfile(
                    actions = ctx.actions,
                    name = artifact_suffix + ".haskell_compile_argsfile",
                    args = [args.args_for_file, args.srcs],
                    allow_args = True,
                )
            )
        else:
            compile_cmd.add(args.args_for_file)
            compile_cmd.add(args.srcs)

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    ctx.actions.run(
        _in_env(_ghc_env(ctx, artifact_suffix + "-build-tool-depends"), compile_cmd),
        category = "haskell_compile_" + artifact_suffix.replace("-", "_"),
        # Keep the previous run's -odir/-hidir so that `ghc --make` can do its
        # own recompilation checking and only rebuild the modules whose
        # sources or imported interfaces changed, rather than the whole
        # package. GHC >= 9.4 tracks file changes with hashes rather than
        # timestamps, so this is safe even though Buck doesn't preserve
        # timestamps on artifacts.
        no_outputs_cleanup = True,
        env = {"LD_LIBRARY_PATH": cmd_args(native_shared_libs_dir)} if native_shared_libs_dir != None else {},
    )

    return args.result


# ---------------------------------------------------------------------------
# Per-module compilation (`per_module = True`): one `ghc -c` action per module
# instead of one `ghc --make` per target. See the Notes at the end of this
# file, starting with Note [Per-module compilation].

# The suffix of the srcs entry of a module's .hs-boot, and of its outputs.
_BOOT = "-boot"

def _is_boot(node: str) -> bool:
    return node.endswith(_BOOT)

def _module_of(node: str) -> str:
    return node[:-len(_BOOT)] if _is_boot(node) else node

def _node_file(node: str, ext: str) -> str:
    # The file of a node with the given extension, relative to an output or
    # tree directory: Foo/Bar.dyn_hi, or Foo/Bar.dyn_hi-boot for a boot.
    return module_name_to_file(_module_of(node), ext + (_BOOT if _is_boot(node) else ""))

def _split_ext(path: str) -> (str, str):
    # A path without its extension, and the extension (src/Foo.hs-boot:
    # src/Foo and hs-boot).
    dot = path.rfind(".")
    if dot < 0 or "/" in path[dot:]:
        return path, ""
    return path[:dot], path[dot + 1:]

def _node_from_path(path: str, by_stem: dict[str, str]) -> str | None:
    # The node of a source by the path `ghc -M` or the deps script was given
    # for it: its project path, or a generated source's output path, which
    # ends with that. So match on the source's path without extension,
    # longest first: src/Bar is also the end of src/Foo/Bar. A source is in
    # the project or in buck-out, never at an absolute path. The makefile is
    # the only machine output `ghc -M` has in released GHCs; a JSON one
    # (-dep-json, GHC merge request !16717) would replace this parsing and
    # the matching of dependencies' interfaces in _read_deps_makefile.
    if path.startswith("/"):
        return None
    stem, ext = _split_ext(path)
    found = None
    for tail, mod in by_stem.items():
        if (stem == tail or stem.endswith("/" + tail)) and (found == None or len(tail) > len(found[0])):
            found = (tail, mod)
    if found == None:
        return None
    return found[1] + _BOOT if ext.endswith(_BOOT) else found[1]

# The directory of a target's per-module compile of one way, relative to the
# target's outputs; the modules' outputs are in per_module_out_dir below it.
def per_module_dir(link_style: LinkStyle, enable_profiling: bool) -> str:
    return "per-module-" + get_artifact_suffix(link_style, enable_profiling) + "/"

# The directory of the outputs of a target's modules of one way, relative to
# the target's outputs. Every module's compile has it on its import path,
# and its dependents' find it through the target's early package db.
#
# It is named after the target's set of modules: buck2 does not delete
# outputs of an action that is gone, so GHC would find a module's old
# interface there after the module moved to another target. So a change to
# the set starts a fresh directory. The cost is that adding, removing or
# renaming a module compiles every module of the target again.
def per_module_out_dir(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool) -> str:
    names = " ".join(sorted([n for n, _ in _nodes(ctx)]))
    return per_module_dir(link_style, enable_profiling) + "out-" + str(hash(names) & 0xffffffff)

def _dir_of(artifact, node: str, ext: str) -> cmd_args:
    # The output (or tree) directory of a node's file with the given
    # extension.
    return cmd_args(artifact, parent = _node_file(node, ext).count("/") + 1)

def _per_module_owner(path: str) -> (str, str) | None:
    # The target that a per-module output in buck-out is of, as its label,
    # and the file's path below its output directory: buck2 puts a target's
    # outputs under buck-out/v2/<kind>/<cell>/<configuration>/<package>/
    # __<name>__/, and ours under per-module-<way>/out-<modules>/ below that
    # (per_module_out_dir). See Note [Compiling against dependencies module
    # by module]. (A package's own directory may be named per-module-...
    # too.)
    parts = path.split("/")
    if parts[0] != "buck-out":
        return None
    for i in range(6, len(parts) - 1):
        name = parts[i - 1]
        if parts[i].startswith("per-module-") and parts[i + 1].startswith("out-") and len(name) > 4 and name.startswith("__") and name.endswith("__"):
            return "{}//{}:{}".format(parts[3], "/".join(parts[5:i - 1]), name[2:-2]), "/".join(parts[i + 2:])
    return None

def _read_deps_makefile(label, text: str, nodes: list, libs_by_owner: dict):
    # From `ghc -M` output: each node's imports among the target's nodes, and
    # the (package id, module) pairs it imports from the dependencies
    # compiled per module.
    #
    # Each source has a line of its own ("src/Foo.o : src/Foo.hs"), by which
    # the module's path as `ghc -M` writes it is known exactly, and the
    # objects and interfaces of the target's modules are named by it with
    # other extensions; a file that only ends the same way (a dependency's
    # interface .../Q/Lib.hi, for a source Lib.hs) is none of them.
    by_stem = {_split_ext(src.short_path)[0]: n for n, src in nodes if not _is_boot(n)}
    lines = []
    exact = {}
    for line in text.splitlines():
        if line.startswith("#") or ":" not in line:
            continue
        lhs, rhs = line.split(":", 1)
        lines.append((lhs.strip(), rhs.strip()))
        stem, ext = _split_ext(rhs.strip())
        if ext in ["hs", "lhs", "hs-boot", "lhs-boot"]:
            n = _node_from_path(rhs.strip(), by_stem)
            if n != None:
                exact[stem] = _module_of(n)

    def node_of(path):
        stem, ext = _split_ext(path)
        mod = exact.get(stem)
        if mod == None:
            return None
        return mod + _BOOT if ext.endswith(_BOOT) else mod

    imports = {n: [] for n, _ in nodes}
    upstream = {n: [] for n, _ in nodes}
    for lhs, rhs in lines:
        tgt = node_of(lhs)
        if tgt == None:
            continue
        # An interface of a dependency compiled per module: which one, and
        # which module, by its path under the dependency's output directory.
        # That is the directory of the way its interfaces were written in,
        # which needn't be this target's: a "shared" library made from a
        # -dynamic-too compile has them in the static way's. An output of a
        # per-module target that is no dependency is never one of this
        # target's sources, whatever its path ends with.
        owned = _per_module_owner(rhs)
        if owned != None:
            lib = libs_by_owner.get(owned[0])
            mod_path = owned[1]
            dot = mod_path.rfind(".")
            ext = mod_path[dot + 1:]
            mod = mod_path[:dot].replace("/", ".") + (_BOOT if ext.endswith(_BOOT) else "")
            if lib != None and mod in lib.modules and (lib.name, mod) not in upstream[tgt]:
                upstream[tgt].append((lib.name, mod))
            continue
        dep = node_of(rhs)
        if dep == None or tgt == dep:
            # A module's dependency on its own source, or a file that
            # isn't one of the target's (an interface of a dependency
            # built with --make or prebuilt, a header, ...).
            continue
        if tgt not in imports or dep not in imports:
            fail("{}: `ghc -M` says {} depends on {}, but srcs has no such module (or boot file)".format(label, tgt, dep))
        if dep not in imports[tgt]:
            imports[tgt].append(dep)
    return imports, upstream

def _transitive_closure(order: list[str], imports: dict) -> dict:
    # Each node's imports, transitively (its direct imports first), from the
    # nodes in dependency order: each import's closure is complete before
    # its importers'.
    closure = {}
    for n in order:
        c = {d: True for d in imports[n]}
        for d in imports[n]:
            for x in closure[d]:
                c[x] = True
        closure[n] = list(c)
    return closure

def _linked_closure(node: str, closure: dict) -> list[str]:
    # The closure of a module that runs Template Haskell, with the whole
    # modules behind the boot files in it, and their closures in turn: a
    # splice may link those modules. See Note [Template Haskell modules].
    linked = {d: True for d in closure[node]}
    todo = [d for d in closure[node] if _is_boot(d)]

    # Starlark has no while: each round takes a boot file off, and there are
    # no more of those than nodes.
    for _ in range(len(closure) + 1):
        if not todo:
            break
        whole = todo.pop()[:-len(_BOOT)]

        # (One that imports this module can't be waited for; GHC couldn't
        # link it for this module's splices either.)
        if whole == node or whole in linked or node in closure[whole]:
            continue
        for d in [whole] + closure[whole]:
            if d not in linked and d != node:
                linked[d] = True
                if _is_boot(d):
                    todo.append(d)
    return list(linked)

def _dependency_order(nodes: list, imports: dict) -> (list[str], list[str]):
    # The nodes, each after its imports (Kahn's algorithm: Starlark has no
    # while, so a loop over the order as it grows), and those left in or
    # behind a cycle.
    importers = {n: [] for n, _ in nodes}
    waiting = {}
    for n, _ in nodes:
        waiting[n] = len(imports[n])
        for d in imports[n]:
            importers[d].append(n)
    order = [n for n, _ in nodes if waiting[n] == 0]
    for i in range(len(nodes)):
        if i >= len(order):
            break
        for m in importers[order[i]]:
            waiting[m] -= 1
            if waiting[m] == 0:
                order.append(m)
    done = {n: True for n in order}
    return order, [n for n, _ in nodes if n not in done]

def _read_splices(text: str, nodes: list):
    # From the deps script's output: the nodes it found Template Haskell (or
    # an ANN pragma) in, and those with explicit level imports, with the
    # modules they import at the splice level. A line is a source's path,
    # then "th" if it runs Template Haskell, then "splice" and the modules if
    # it has explicit level imports.
    # The paths are those the script was given, as `ghc -M` is (with the
    # sources' own extensions); a boot file's line counts for nothing.
    by_stem = {_split_ext(src.short_path)[0]: n for n, src in nodes if not _is_boot(n)}
    th = {}
    splice_imports = {}
    for line in text.splitlines():
        words = line.split()
        n = _node_from_path(words[0], by_stem) if words else None
        if n == None or _is_boot(n):
            continue
        rest = words[1:]
        if rest[:1] == ["th"]:
            th[n] = True
            rest = rest[1:]
        if rest[:1] == ["splice"]:
            splice_imports[n] = rest[1:]
    return th, splice_imports

# What a module that runs Template Haskell may compile against, by the
# direct dependencies its splices run code from (see Note [Template Haskell
# modules]):
#
# - closures: for each dependency compiled per module, by package id, the
#   package ids of its closure, whose final dbs the module then uses (each
#   of their libraries was linked against the others, see Note [Libraries
#   of the early package dbs]);
# - trees: for each of those, the tree of its shared libraries;
# - labels: their package ids, by target;
# - base, base_tree: the same for all the dependencies not compiled per
#   module together, whose libraries every such module gets.
#
# There are no trees when nothing is linked shared.
def _splice_deps(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, prefix: str, native_shared_libs_dir: [Artifact, None]):
    closures = {}
    trees = {}
    labels = {}
    base_infos = []
    base_shlibs = []

    def link_info(d):
        link = d.get(HaskellLinkInfo)
        if link == None:
            return None
        return link.prof_info[link_style] if enable_profiling else link.info[link_style]

    def tree(name, shlibs):
        if native_shared_libs_dir == None or not shlibs:
            return None
        sos = traverse_shared_library_info(merge_shared_libraries(ctx.actions, deps = shlibs), transformation_provider = None)
        return create_shlib_symlink_tree(actions = ctx.actions, out = prefix + "th-shared-libs/" + name, shared_libs = sos) if sos else None

    for d in attr_deps(ctx) + ctx.attrs.template_deps:
        provider = d.get(HaskellLibraryProvider)
        lib = (provider.prof_lib if enable_profiling else provider.lib)[link_style] if provider != None else None
        info = link_info(d)
        shlib = d.get(SharedLibraryInfo)
        if lib == None or lib.modules == None:
            if info != None:
                base_infos.append(info)
            if shlib != None:
                base_shlibs.append(shlib)
            continue
        labels[d.label.raw_target()] = lib.name
        closures[lib.name] = [l.name for l in ctx.actions.tset(HaskellLibraryInfoTSet, children = [info] if info != None else []).traverse()]
        trees[lib.name] = tree(lib.name, [shlib] if shlib != None else [])
    base = [l.name for l in ctx.actions.tset(HaskellLibraryInfoTSet, children = base_infos).traverse()]
    return struct(closures = closures, trees = trees, labels = labels, base = base, base_tree = tree("_", base_shlibs))

# The final dbs and shared library trees of a module that runs Template
# Haskell whose splices run code from the given dependencies compiled per
# module (package ids), and from every dependency not compiled per module.
def _splice_set(splice_deps, names: list[str]):
    final = {n: True for n in splice_deps.base}
    trees = [splice_deps.base_tree] if splice_deps.base_tree != None else []
    for name in names:
        # A package that is no direct dependency (one whose module a
        # dependency re-exports) comes with the direct dependencies whose
        # closures have it, whose trees have its library.
        via = [name] if name in splice_deps.closures else [d for d in sorted(splice_deps.closures.keys()) if name in splice_deps.closures[d]]
        for d in via:
            for n in splice_deps.closures[d]:
                final[n] = True
            if splice_deps.trees[d] != None and splice_deps.trees[d] not in trees:
                trees.append(splice_deps.trees[d])
    return struct(final = final, trees = trees)

# The final dbs and shared library trees of the target's Template Haskell
# modules: all of the dependencies, or with th_build_depends those listed,
# with the early dbs of the rest. None for all of them.
def _th_set(ctx: AnalysisContext, splice_deps):
    th_deps = getattr(ctx.attrs, "th_build_depends", None)
    if th_deps == None:
        return None
    names = []
    deps = {d.label.raw_target(): True for d in attr_deps(ctx) + ctx.attrs.template_deps}
    for d in th_deps:
        t = d.label.raw_target()
        if t not in deps:
            fail("{}: th_build_depends names {}, which is not a dependency".format(ctx.label.raw_target(), t))
        if t in splice_deps.labels:
            names.append(splice_deps.labels[t])
    return _splice_set(splice_deps, names)

def _nodes(ctx: AnalysisContext) -> list:
    # The nodes of a target's module graph: the modules, and their boot
    # files as "<module>-boot" (named so in a srcs dict; in a list they
    # only have the module's name), each with its source.
    nodes = []
    for name, src in srcs_to_pairs(ctx.attrs.srcs):
        if is_haskell_src(src):
            nodes.append((name, src))
        elif src.short_path.endswith(_BOOT):
            nodes.append((name if _is_boot(name) else name + _BOOT, src))
    return nodes

def _declare_module_outputs(ctx: AnalysisContext, out_dir: str, nodes: list, osuf: str, hisuf: str, dynamic_too: bool):
    # Each node's outputs, all in one directory (so not at content-based
    # paths, see per_module_out_dir). Declared outside the dynamic output so
    # that they can be exported, with the directories the rest of the rules
    # consume, which are assembled from them.
    def declare(n, ext):
        return ctx.actions.declare_output(out_dir + "/" + _node_file(n, ext), has_content_based_path = False)

    return struct(
        o = {n: declare(n, osuf) for n, _ in nodes},
        hi = {n: declare(n, hisuf) for n, _ in nodes},
        abi = {n: declare(n, "abi") for n, _ in nodes},
        dyn_o = {n: declare(n, "dyn_o") for n, _ in nodes} if dynamic_too else {},
        dyn_hi = {n: declare(n, "dyn_hi") for n, _ in nodes} if dynamic_too else {},
    )

def _cross_package_closures(nodes: list, closure: dict, upstream: dict, dep_closures: dict) -> dict:
    # Each node's closure across packages, as (package id, module) pairs:
    # its own and its in-package closure's imports from dependencies, and
    # those modules' own closures (which their targets wrote out,
    # transitively complete).
    full = {}
    for n, _ in nodes:
        entries = {}
        for x in [n] + closure[n]:
            for pkg, mod in upstream[x]:
                entries[(pkg, mod)] = True
                for pm in dep_closures.get(pkg, {}).get(mod, []):
                    entries[(pm[0], pm[1])] = True
        full[n] = list(entries.keys())
    return full

def _registration_order(label, nodes: list, imports: dict, closure: dict, reads: dict) -> (list[str], dict):
    # The nodes in the order their actions are registered, each after the
    # nodes whose outputs its compile reads (an action can only take as
    # inputs outputs of actions already registered); and `reads`, with any
    # cycle in it broken.
    #
    # The imports have no cycle (`ghc -M` and _dependency_order check), so
    # a cycle here is of modules that run Template Haskell, each waiting
    # for another's whole module, which its splice may link. The first by
    # name of those on such a cycle then waits for none of the others left:
    # its splice can't link them, as with --make, which can't compile both
    # first either, and fails to compile only if it runs their code. A
    # module only behind a cycle keeps its waits. One such module each
    # round, of no more than the nodes.
    reads = dict(reads)
    for _ in range(len(nodes) + 1):
        waits = {n: imports[n] + [d for d in reads[n] if d not in imports[n]] for n, _ in nodes}
        order, left = _dependency_order(nodes, waits)
        if not left:
            return order, reads
        on_cycle = [n for n in sorted(left) if _reaches([d for d in reads[n] if d in left and d not in closure[n]], n, waits, left)]
        if not on_cycle:
            break
        n = on_cycle[0]
        reads[n] = [d for d in reads[n] if d in closure[n] or d not in left]
    fail("{}: import cycle among {}".format(label, ", ".join(left)))

def _reaches(starts: list[str], target: str, edges: dict, within: list[str]) -> bool:
    # Whether target is reachable from any of starts by edges, through the
    # nodes within.
    allowed = {n: True for n in within}
    seen = {}
    todo = list(starts)
    for _ in range(len(allowed) + 1):
        if not todo:
            break
        frontier = []
        for n in todo:
            if n == target:
                return True
            if n in seen or n not in allowed:
                continue
            seen[n] = True
            frontier += edges[n]
        todo = frontier
    return False

def _compile_per_module(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None, native_shared_libs_dir: [Artifact, None], dynamic_too: bool) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    suffix = get_artifact_suffix(link_style, enable_profiling)
    osuf, hisuf = output_extensions(link_style, enable_profiling)
    prefix = per_module_dir(link_style, enable_profiling)

    # The tag of everything a module's dep file may list: see Note [Early
    # cut-off by dep files].
    tag = ctx.actions.artifact_tag()

    # The package flags of a module: the final dbs of the given dependencies
    # (None: all of them), and the early dbs of the rest, without their
    # interface dirs or libraries (the module declares the interfaces it
    # reads itself, below). See Note [Libraries of the early package dbs]. A
    # module that runs no Template Haskell compiles against the early dbs of
    # the dependencies compiled per module, and the final dbs of the others,
    # which have no early db.
    #
    # With them, the trees of the dependencies' shared libraries, which the
    # compile script puts on LD_LIBRARY_PATH (--ldtree). They are plain
    # inputs of the compiles given them (those that run Template Haskell), as
    # the dependencies' Haskell libraries are, since GHC records no use of a
    # library a splice loaded, native or not.
    dep_libs = list(_dependency_libs(ctx, link_style, enable_profiling).traverse())
    exposed_package_args = _exposed_package_args(ctx, link_style, False, enable_profiling)

    def packages(final, trees, runs_th = True):
        dbs = _package_dbs(dep_libs, final, tag, runs_th)
        return struct(
            args = cmd_args(exposed_package_args, dbs.packagedb_args),
            local_import_dirs = dbs.local_import_dirs,
            early_names = dbs.early_names,
            ld_tree = cmd_args(trees, delimiter = ":") if trees else None,
        )

    early_set = packages({}, [], runs_th = False)

    # The trees of the shared libraries a Template Haskell module loads
    # (which depend on their links) are given to those modules' actions
    # only, below, not to every compile and the module graph. A module with
    # explicit level imports chooses its own, see Note [Explicit level
    # imports]; the others take the target's.
    splice_deps = _splice_deps(ctx, link_style, enable_profiling, prefix, native_shared_libs_dir)
    th_set = _th_set(ctx, splice_deps)
    if th_set == None:
        # No th_build_depends: the final dbs of every dependency, and all
        # their shared library trees.
        target_th = packages(None, _splice_set(splice_deps, sorted(splice_deps.closures.keys())).trees)
    else:
        target_th = packages(th_set.final, th_set.trees)
    # The extensions the target's flags, or the toolchain's, enable for all
    # its modules.
    flags = (haskell_toolchain.compiler_flags or []) + ctx.attrs.compiler_flags
    th_target = "-XTemplateHaskell" in flags or "-XQuasiQuotes" in flags
    eli_target = "-XExplicitLevelImports" in flags or "-XNoImplicitStagePersistence" in flags
    module_libs = {lib.name: lib for lib in dep_libs if lib.modules != None}
    this_pkg = pkgname or haskell_library_unit_id(ctx.label)

    # A binary's modules too are in a unit named after the target, not
    # GHC's default `main`, which every binary would share.
    cmd_flags, file_flags = _ghc_flags(ctx, link_style, enable_profiling, this_pkg, dynamic_too)
    # The target's other sources (headers a module #includes, say), which
    # GHC records no use of: plain inputs of every compile, as of --make's.
    other_srcs = [src for _, src in srcs_to_pairs(ctx.attrs.srcs) if not is_haskell_src(src) and not src.short_path.endswith(_BOOT)]
    base_cmd = cmd_args(haskell_toolchain.compiler, cmd_flags, file_flags, hidden = other_srcs)
    env = _ghc_env(ctx, prefix + "build-tool-depends")

    nodes = _nodes(ctx)
    src_of = {n: src for n, src in nodes}

    module_outputs = _declare_module_outputs(ctx, per_module_out_dir(ctx, link_style, enable_profiling), nodes, osuf, hisuf, dynamic_too)
    o_of = module_outputs.o
    hi_of = module_outputs.hi
    abi_of = module_outputs.abi
    dyn_o_of = module_outputs.dyn_o
    dyn_hi_of = module_outputs.dyn_hi
    closures = ctx.actions.declare_output(prefix + "closures.json", has_content_based_path = False)
    objects = ctx.actions.declare_output("objects-" + suffix, dir = True, has_content_based_path = False)
    hi = ctx.actions.declare_output("hi-" + suffix, dir = True, has_content_based_path = False)
    stubs = ctx.actions.declare_output("stubs-" + suffix, dir = True, has_content_based_path = False)
    producing_indices = _producing_indices(ctx)

    # How dependents recognise this target's interfaces in their `ghc -M`
    # output (see _per_module_owner).
    owner = "{}//{}:{}".format(ctx.label.cell, ctx.label.package, ctx.label.name)

    # The module graph, with the interfaces each module imports from the
    # dependencies (by the paths their package dbs give them, which need not
    # exist yet), and which modules run Template Haskell and import what at
    # the splice level (see the script). Against the early dbs, so it needs
    # nothing built. The boot files aren't arguments: GHC finds them next to
    # the sources.
    deps_mk = ctx.actions.declare_output(prefix + "deps.mk")
    splices_file = ctx.actions.declare_output(prefix + "splices.txt")
    hs_srcs = [src for n, src in nodes if not _is_boot(n)]
    deps_cmd = cmd_args(
        base_cmd,
        early_set.args,
        "-M",
        "-include-pkg-deps",
        "-dep-makefile",
        deps_mk.as_output(),
        "-dep-suffix",
        "",
        hs_srcs,
        hidden = [src for n, src in nodes if _is_boot(n)],
    )
    ctx.actions.run(
        _in_env(env, cmd_args(ctx.attrs._per_module_deps[RunInfo], splices_file.as_output(), "1" if eli_target else "0", hs_srcs, "--", deps_cmd)),
        category = "haskell_deps_" + suffix.replace("-", "_"),
    )

    # The dependencies compiled per-module whose modules this target may
    # import, by the tail of their output path: all of them, not only the
    # direct ones, since a dependency may re-export a module of another.
    libs_by_owner = {lib.owner: lib for lib in module_libs.values()}

    # The import directories the dep-file writer looks interfaces up in: the
    # --make libraries' (whole), and the output directories of the per-module
    # libraries a module compiles against the early dbs of.
    # (Each of these libraries has a module: compile() handles a target with
    # none outside the per-module path, which leaves its `modules` None.)
    def out_dir_of(lib):
        m, files = list(lib.modules.items())[0]
        return _dir_of(files.hi, m, hisuf)

    module_lib_dirs = {name: out_dir_of(lib) for name, lib in module_libs.items()}

    def register_modules(ctx, artifacts, outputs):
        imports, upstream = _read_deps_makefile(ctx.label, artifacts[deps_mk].read_string(), nodes, libs_by_owner)
        order, left = _dependency_order(nodes, imports)
        if left:
            fail("{}: import cycle among {}".format(ctx.label, ", ".join(left)))
        closure = _transitive_closure(order, imports)

        dep_closures = {lib.name: artifacts[lib.closures].read_json() for lib in libs_by_owner.values()}
        full = _cross_package_closures(nodes, closure, upstream, dep_closures)
        ctx.actions.write_json(
            outputs[closures].as_output(),
            {n: [[this_pkg, d] for d in closure[n]] + [[p, m] for p, m in full[n]] for n, _ in nodes},
        )

        th_nodes, splice_imports = _read_splices(artifacts[splices_file].read_string(), nodes)

        # What each module's compile reads: its closure, and for a module
        # that runs Template Haskell, the whole modules behind the boot files
        # in it too (see _linked_closure). The actions are registered in
        # that order: an action can only take as inputs outputs of actions
        # already registered.
        runs_th = {n: not _is_boot(n) and (th_target or n in th_nodes) for n, _ in nodes}
        reads = {n: _linked_closure(n, closure) if runs_th[n] else closure[n] for n, _ in nodes}
        registration_order, reads = _registration_order(ctx.label, nodes, imports, closure, reads)

        # The package flags and library trees of a module with explicit
        # level imports: the final dbs of the packages its splices run code
        # from, those of the modules it imports at the splice level and, for
        # a module of this target, those its own imports bring, and the
        # early dbs of the rest. Shared by the modules that come to the same
        # packages.
        eli_sets = {}

        def eli_packages(n):
            pkgs = {}
            for m in splice_imports[n]:
                if m in src_of:
                    for x in [m] + closure[m]:
                        for pkg, _ in upstream[x]:
                            pkgs[pkg] = True
                else:
                    for pkg, mod in upstream[n]:
                        if mod == m:
                            pkgs[pkg] = True
            names = sorted(pkgs.keys())
            key = " ".join(names)
            if key not in eli_sets:
                splice_set = _splice_set(splice_deps, names)
                eli_sets[key] = packages(splice_set.final, splice_set.trees)
            return eli_sets[key]

        # In the order above, which a symlinked_dir needs too: it can only
        # link artifacts that an action already produces.
        hie_of = {}
        for n in registration_order:
            # The module's own imports are found in the shared output
            # directory of all the modules, with the closure's files as
            # (tagged) inputs: a symlink tree per module cost more to
            # materialise than the compiles themselves.
            closure_files = []
            for d in reads[n]:
                closure_files += [outputs[hi_of[d]], outputs[abi_of[d]], outputs[o_of[d]]]
                if dynamic_too:
                    closure_files += [outputs[dyn_hi_of[d]], outputs[dyn_o_of[d]]]
            if not runs_th[n]:
                mod_packages = early_set
            elif n in splice_imports:
                mod_packages = eli_packages(n)
            else:
                mod_packages = target_th
            hidirs = mod_packages.local_import_dirs + [d for name, d in module_lib_dirs.items() if name in mod_packages.early_names]

            # The interfaces this module may read from the per-module
            # dependencies it compiles against the early dbs of: its
            # imports' closure.
            upstream_files = []
            for pkg, mod in full[n]:
                lib = module_libs.get(pkg)
                if lib == None or mod not in lib.modules or pkg not in mod_packages.early_names:
                    continue
                files = lib.modules[mod]
                upstream_files += [files.hi, files.abi]
                if files.dyn_hi != None:
                    upstream_files.append(files.dyn_hi)

            # The module's own flags, after those of its session.
            stubdir = ctx.actions.declare_output(prefix + "stubs/" + n, dir = True, has_content_based_path = False)
            module_flags = cmd_args("-c", src_of[n], "-o", outputs[o_of[n]].as_output(), "-ohi", outputs[hi_of[n]].as_output(), "-stubdir", stubdir.as_output())
            mkdirs = [stubdir.as_output()]
            module_flags.add("-ddump-hi", "-ddump-to-file", cmd_args(outputs[abi_of[n]].as_output(), format = "-ddump-file-prefix={}"))
            if closure[n]:
                module_flags.add(tag.tag_artifacts(cmd_args(_dir_of(outputs[hi_of[closure[n][0]]], closure[n][0], hisuf), hidden = closure_files, format = "-i{}")))
            if upstream_files:
                module_flags.add(tag.tag_artifacts(cmd_args(hidden = upstream_files)))
            if dynamic_too:
                module_flags.add("-dyno", outputs[dyn_o_of[n]].as_output(), "-dynohi", outputs[dyn_hi_of[n]].as_output())
            if producing_indices:
                # The module's .hie file, which GHC writes below -hiedir by
                # the module's path, and which the index (the target's hi
                # tree) has, as --make's has it.
                hie_of[n] = ctx.actions.declare_output(prefix + "hie/" + n + "/" + _node_file(n, "hie"), has_content_based_path = False)
                module_flags.add("-hiedir", _dir_of(hie_of[n].as_output(), n, "hie"))

            # The compile script's request (see the script).
            depfile = ctx.actions.declare_output(prefix + "dep/" + n + ".dep", has_content_based_path = False)
            request = cmd_args(
                "--depfile",
                tag.tag_artifacts(depfile.as_output()),
                "--abi",
                outputs[abi_of[n]].as_output(),
                "--module",
                _module_of(n).replace(".", "/"),
                "--outdir",
                _dir_of(outputs[hi_of[n]].as_output(), n, hisuf),
                "--hisuf",
                hisuf,
                ["--ldtree", mod_packages.ld_tree] if mod_packages.ld_tree != None else [],
                # Paths only: the interfaces the module reads are inputs of
                # their own (upstream_files, and the --make libraries'
                # import dirs with the package dbs). A dependency compiled
                # per module is named by one of its interfaces, which as an
                # input would make the module wait for it.
                cmd_args(hidirs, format = "--hidir={}", ignore_artifacts = True),
                cmd_args(mkdirs, format = "--mkdir={}"),
                "--",
                base_cmd,
                mod_packages.args,
                "--",
                module_flags,
            )
            ctx.actions.run(
                _in_env(env, cmd_args(ctx.attrs._per_module_compile[RunInfo], request)),
                category = "haskell_compile_module_" + suffix.replace("-", "_"),
                identifier = n,
                dep_files = {"hs": tag},
            )

        obj_map = {}
        hi_map = {}
        for n, _ in nodes:
            obj_map[_node_file(n, osuf)] = outputs[o_of[n]]
            hi_map[_node_file(n, hisuf)] = outputs[hi_of[n]]
            hi_map[_node_file(n, "abi")] = outputs[abi_of[n]]
            if n in hie_of:
                hi_map[_node_file(n, "hie")] = hie_of[n]
            if dynamic_too:
                obj_map[_node_file(n, "dyn_o")] = outputs[dyn_o_of[n]]
                hi_map[_node_file(n, "dyn_hi")] = outputs[dyn_hi_of[n]]
        ctx.actions.symlinked_dir(outputs[objects].as_output(), obj_map, has_content_based_path = False)
        ctx.actions.symlinked_dir(outputs[hi].as_output(), hi_map, has_content_based_path = False)
        # Empty: each module writes its stubs (the _stub.h of its foreign
        # exports) to a directory of its own. Nothing reads the target's
        # stubs directory except as an input (--make's either), so an empty
        # one serves.
        ctx.actions.symlinked_dir(outputs[stubs].as_output(), {}, has_content_based_path = False)

    all_outputs = [objects.as_output(), hi.as_output(), stubs.as_output(), closures.as_output()]
    for files in [o_of, hi_of, abi_of, dyn_o_of, dyn_hi_of]:
        all_outputs += [out.as_output() for out in files.values()]
    ctx.actions.dynamic_output(
        dynamic = [deps_mk, splices_file] + [lib.closures for lib in libs_by_owner.values()],
        inputs = [src for _, src in nodes],
        outputs = all_outputs,
        f = register_modules,
    )
    modules = {
        n: HaskellModuleFiles(hi = hi_of[n], abi = abi_of[n], dyn_hi = dyn_hi_of[n] if dynamic_too else None)
        for n, _ in nodes
    }
    return CompileResultInfo(objects = objects, hi = hi, stubs = stubs, producing_indices = producing_indices, modules = modules, closures = closures, owner = owner)

# Note [Per-module compilation]
#
# Normally a target is compiled by one `ghc --make` action. With
# `per_module = True`, it is compiled by one `ghc -c` action per module
# instead. buck2 can then:
#
# - run the target's modules in parallel with everything else in the build;
# - start each module as soon as the modules it imports are compiled, even
#   those of other targets, rather than waiting for whole targets;
# - after an edit, run again only the modules affected.
#
# The price is CPU. Each `ghc -c` reads the interfaces of everything its
# module imports (and, for Template Haskell, loads the dependencies' shared
# libraries), which `ghc --make` does only once per target.
#
# Terms
#
# - Node: a module, or a module's boot file (.hs-boot). Each node has an
#   action of its own; a boot file's comes from the "<module>-boot" entry of
#   srcs (see _nodes). The modules that import a boot file with
#   {-# SOURCE #-} depend on it, and so does the module itself, since GHC
#   checks that the two agree.
# - Module graph: the target's nodes and their imports, from a `ghc -M`
#   action, which needs only the sources and the package dbs, not any
#   compiled dependency. A dynamic_output reads the graph and registers the
#   nodes' actions.
# - Closure: everything a module imports, directly or indirectly, across
#   targets. A compile needs the interfaces of its whole closure (GHC reads
#   them for instances and type families), and a Template Haskell module
#   needs the objects too.
# - Output directory: where all the modules of a target write their objects
#   and interfaces. It is the import path of every compile of the target, so
#   its files are at fixed paths rather than content-based ones, for GHC to
#   find them by module name. A target has one for each way it is compiled
#   in (static, shared, profiled), named after its set of modules (see
#   per_module_out_dir). The objects and hi directories the rest of the
#   rules use are assembled from it with symlinked_dir.
# - Early and final package db: a dependency compiled per module is
#   registered twice. Its early db names no library, and its interfaces
#   appear one by one as its modules compile. Its final db is the normal
#   one, registered once its library is linked. See Note [Compiling against
#   dependencies module by module].
# - Template Haskell module: one that runs a splice, or evaluates an ANN
#   pragma (GHC uses its interpreter for those too). It runs its
#   dependencies' code at compile time, so it needs their libraries, not
#   just their interfaces. See Note [Template Haskell modules].
# - Dep file: the list of an action's inputs that it actually read, which
#   buck2 uses to decide whether to run the action again. See Note [Early
#   cut-off by dep files].
#
# The other Notes, in reading order
#
# - Note [Compiling against dependencies module by module]: how a module
#   can compile before its dependencies are finished.
# - Note [Early cut-off by dep files]: which modules compile again after an
#   edit. Note [Reading the interface text] is how the dep files are made.
# - Note [Template Haskell modules]: what the modules that run code at
#   compile time wait for. Note [Libraries of the early package dbs] has
#   the package dbs each compile gets, and Note [Explicit level imports]
#   how a module can say what its splices run.

# Note [Compiling against dependencies module by module]
#
# 1. The problem
#
# Say module X of target T imports module Y of dependency D, and X runs no
# Template Haskell (for those, see Note [Template Haskell modules]). X needs
# the interfaces of Y and of Y's closure. It doesn't need the rest of D: not
# D's other interfaces, and not D's library. So X should be able to start as
# soon as Y and its closure are compiled, however much of D is left.
#
# But GHC finds D's interfaces through D's package db, and a normal package
# db is only registered once D's library is built.
#
# 2. The solution
#
# A dependency compiled per module also has an "early" package db (see the
# `early` argument of _make_package in haskell.bzl). It is registered before
# anything is compiled, names no library, and has D's output directory as
# its import directory, which fills in as D's modules compile. X compiles
# against D's early db, and depends on just the interface files it needs.
# (D's final db, registered once its library is linked, is the normal one
# that `ghc --make` would use.)
#
# Two things say which interface files X needs:
#
# - X's own imports from dependencies come from `ghc -M -include-pkg-deps`,
#   which names each interface by the path the package db gives it, before
#   the file exists. The path says which dependency the interface belongs
#   to (_per_module_owner). This is the one place the rules depend on
#   buck-out's layout.
# - Their closure comes from the dependencies themselves: every per-module
#   target writes out the closure of each of its modules, and its dependents
#   read that rather than following the imports again.

# Note [Early cut-off by dep files]
#
# 1. The problem
#
# After an edit, a module should compile again only if one of the modules
# it imports changed its ABI. (GHC's own recompilation check goes further:
# it also looks at which of the imported module's entities the module
# uses.) Comparing the imported modules' interface files isn't enough: an
# interface includes a hash of its source, so even a comment-only edit
# changes it.
#
# 2. The solution
#
# buck2 decides this for each action, from a dep file. Every file a module's
# compile might read is a tagged input: the interfaces, and the objects of
# the target's own modules. After the compile, the action lists the ones it
# actually read. On the next build, buck2 runs the action again only if one
# of the listed files has changed.
#
# The list comes from the usages GHC records in the new interface, which are
# also what GHC's own recompilation check reads (see Note [Reading the
# interface text]):
#
# - For each imported module, its .abi file, which holds just the
#   interface's ABI hash. Each action writes one next to its interface.
# - Each object of the target's own modules that a Template Haskell splice
#   loaded, which GHC records as a dependent file. (The dependencies'
#   _libraries_ are plain inputs instead: see Note [Template Haskell
#   modules].)
#
# 3. buck2 decides, not GHC
#
# buck2 removes an action's previous outputs before it runs, as for any
# action, so GHC's recompilation check never has anything to look at, and
# the module compiles whenever the action runs. This makes our check more
# sound than GHC's: GHC ignores changes to the _implementation_ of the
# libraries Template Haskell uses, and we don't.
#
# 4. Coarser than GHC's check
#
# The dep file names a whole imported module's ABI. So a module that imports
# `A (f)` compiles again when A gains an export, or when A's g changes,
# which GHC's check would know is irrelevant. The cascade usually stops
# there: the module's _own_ ABI comes out the same, so its importers don't
# compile again.
#
# GHC's interface has what we would need for a finer cut-off: the hash of
# the export list, and of each entity the module used. A module's compile
# could write those as files of their own (a directory per module), and its
# importers' dep files would list only the ones they used.

# Note [Reading the interface text]
#
# 1. The problem
#
# The compile script makes a module's .abi file and dep file from the
# interface GHC wrote (see Note [Early cut-off by dep files]). But an
# interface is binary, and the only reader GHC ships is the pretty-printer
# behind --show-iface and -ddump-hi, whose output is meant for people. GHC
# doesn't promise to keep that output the same, and as of 9.14 has no
# machine-readable form (GHC issue #25562 asked for one).
#
# 2. The solution
#
# The script parses three things out of the -ddump-hi output:
#
# - the "ABI hash:" line;
# - the usage lines of the imported modules, "import  -/  Mod hash"
#   ("import safe Mod hash" for a safe import; GHC 9.14 prints the first of
#   them on the "usages: [" line);
# - the addDependentFile "path" lines, for what a splice loaded.
#
# tests/rules/test_scripts.py checks these against a dump from each GHC the
# rules support. If the format changes, the script should fail rather than
# write a wrong dep file, so it fails the compile when it finds no ABI hash,
# or finds usages but no import line it can read. A change it can't tell
# from there being no usages (to the addDependentFile lines, say) would leave
# entries out of the dep files, and a module wouldn't compile again when it
# should.
#
# The proper way to read an interface is the GHC API, in a small executable
# built with the GHC in use, which a project could build like its other
# tools. We don't do that yet, but could.

# Note [Template Haskell modules]
#
# 1. The problem
#
# A Template Haskell module runs its dependencies' code at compile time, so
# it needs their libraries, not just their interfaces. That means waiting
# for its dependencies to be linked, which loses much of the parallelism
# that compiling per module gains.
#
# 2. What it waits for
#
# By default, a Template Haskell module compiles against the final package
# dbs of all its dependencies, with their libraries as inputs and the trees
# of their shared libraries on LD_LIBRARY_PATH. So it waits for all of them
# to be linked, as a --make compile does. Two things narrow that:
#
# - th_build_depends: the target lists the dependencies compiled per module
#   whose code its splices need (see _th_set). Its Template Haskell modules
#   then wait only for the libraries of those (and of their own
#   dependencies), and compile against the early dbs of the rest, like any
#   other module. Dependencies not compiled per module are always included:
#   a prebuilt package's library is there from the start, and one built
#   with --make is waited for whole anyway.
# - Explicit level imports: a module that uses them chooses its own set,
#   whatever th_build_depends says. See Note [Explicit level imports].
#
# Note [Libraries of the early package dbs] has a table of which package db
# a compile gets for each dependency. The shared libraries are in one tree
# per dependency compiled per module, and one tree for all the rest (see
# _splice_deps), so that a module's LD_LIBRARY_PATH can list only the ones
# it needs. If a splice runs code from a dependency that was left out, the
# compile fails, naming the symbol it couldn't load, so mistakes are easy to
# spot.
#
# 3. Why the libraries aren't in the dep file
#
# The libraries are plain inputs of the compile, not ones its dep file
# governs, so any relink of a library the module depends on makes it compile
# again. The dep file can't cover them: GHC records in an interface the
# libraries it loaded as Haskell libraries (hs-libraries), but a package db
# here names its library as one of its extra-libraries. So a splice that ran
# a _dependency's_ code leaves no trace of that library in the interface,
# but we do want a change to that code to force a recompile.
#
# 4. Modules behind boot files
#
# A splice links all the code it runs, _including_ modules behind boot
# files: one-shot GHC loads their objects from the output directory. But a
# module's closure only has the boot file of a {-# SOURCE #-}
# import, not the real module behind it. So a Template Haskell module also
# depends on the real modules behind the boot files in its closure, and on
# their closures (_linked_closure). Otherwise it could be compiled too early,
# and fail to link them.
#
# Even so, linking a module behind a boot file doesn't always work, and the
# rules don't currently try to work around that: GHC fails to link some
# such cases, before 9.12 and with 9.14.1.
#
# 5. Finding the Template Haskell modules
#
# Which modules run Template Haskell has to be decided before any compile,
# from the target's flags and the sources. The deps script
# (tools/per_module_deps.py) looks for the extensions' names, and for ANN
# pragmas. It can find too much (a name in a comment, say), but it's better
# to be conservative. It doesn't catch GHC plugins.

# Note [Libraries of the early package dbs]
#
# 1. The problem
#
# A Template Haskell module runs code in GHC's interpreter, which first
# loads the library of every package on the command line, and of their
# dependencies (GHC's "preload" units), whether or not the splice uses it.
# A dynamically linked GHC tolerates a missing library file: it warns, or
# says nothing, and carries on. But a library that is there, and was linked
# against one that _isn't_, fails to load in the system's dynamic linker,
# and the compile fails with it. buck2 doesn't sandbox local actions, so a
# library that a compile doesn't declare as an input may or may not be on
# disk: it may not be linked yet, or not materialised, even if one next to
# it is.
#
# 2. The solution
#
# A package db either names a library that the compile depends on, or none.
# The early dbs name none. For each dependency, a compile gets either its
# early db, or its final db, which names the library (and brings it as an
# input of the compile):
#
#                                 dependency compiled    other dependency
#                                 per-module             (prebuilt, --make)
#   module that runs no TH        early                  final
#   TH module                     final                  final
#   TH module, th_build_depends   final if listed,       final
#                                 else early
#   TH module, explicit level     final if its splice    final
#   imports                       imports need it,
#                                 else early
#
# A final db comes with the final dbs of the dependency's closure. A module
# that runs no Template Haskell never starts the interpreter, so it doesn't
# depend on the libraries of the final dbs it gets.

# Note [Explicit level imports]
#
# 1. The idea
#
# With ExplicitLevelImports (GHC 9.14 and later), or
# NoImplicitStagePersistence, a splice or ANN pragma can only use what the
# module imports with `import splice`: using a name imported otherwise, even
# from the Prelude, is a level error. So those imports tell us exactly what
# code the module's splices may run, and so which libraries its compile
# needs:
#
# - for an imported module of a dependency: that dependency's library, and
#   the libraries of its own dependencies (see Note [Libraries of the early
#   package dbs]);
# - for an imported module of the target itself: its object, which is an
#   input of the compile anyway, and the libraries of the dependencies it
#   imports from.
#
# Such a module compiles against the final dbs of those, and of the
# dependencies not compiled per module, whatever th_build_depends says, and
# against the early dbs of the rest. So the libraries differ from module to
# module, and so do the trees of shared libraries on its LD_LIBRARY_PATH
# (see _splice_deps).
#
# 2. Finding the splice imports
#
# `ghc -M` doesn't say at which level a module imports another, and nothing
# else does before the compile (the interface records it afterwards). So the
# deps script (tools/per_module_deps.py) reads it from the source: the
# extensions, from the LANGUAGE and OPTIONS_GHC pragmas and the target's
# flags, and the import declarations with `splice` before or after the
# module name. That can find too much (an import in a comment, or in a CPP
# branch not taken), but that's fine, as it's conservative.
