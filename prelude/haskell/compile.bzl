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
    module_dir_tail = field(str | None, None),
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
    # The interface dirs of the local libraries built with --make (all of
    # them when not `early`, see get_packages_info).
    local_import_dirs = field(list[Artifact], []),
    # The local libraries compiled per module, by package id.
    module_libs = field(dict[str, typing.Any], {}),
    # Those of them whose early dbs are used, by package id.
    early_names = field(dict[str, bool], {}),
)

def _package_flag(toolchain: HaskellToolchainInfo) -> str:
    if toolchain.support_expose_package:
        return "-expose-package"
    else:
        return "-package"

def get_packages_info(ctx: AnalysisContext, link_style: LinkStyle, specify_pkg_version: bool, enable_profiling: bool, import_dirs_tag = None, early: bool = False, final: [dict[str, bool], None] = None) -> PackagesInfo:
    # `early`: use the early package dbs of the dependencies compiled per
    # module (those registered before the library exists), and don't make
    # their interface directories, libraries or stub directories inputs: the
    # caller declares the interfaces it imports itself. For a compile that
    # runs no Template Haskell, which needs no library of any dependency.
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)
    libs = ctx.actions.tset(
        HaskellLibraryInfoTSet,
        children = [lib.prof_info[link_style] if enable_profiling else lib.info[link_style] for lib in direct_deps_link_info],
    )

    package_flag = _package_flag(haskell_toolchain)
    dbs = _package_dbs(list(libs.traverse()), early, final, import_dirs_tag)
    exposed_package_args = cmd_args(dbs.hidden)
    module_libs = {lib.name: lib for lib in libs.traverse() if lib.modules != None}

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

    return PackagesInfo(
        exposed_package_args = exposed_package_args,
        packagedb_args = dbs.packagedb_args,
        transitive_deps = libs,
        local_import_dirs = dbs.local_import_dirs,
        module_libs = module_libs,
        early_names = dbs.early_names,
    )

# The package db flags for the given libraries (the dependencies, direct and
# transitive), and the inputs they bring: see get_packages_info. Also run by
# a per-module compile for each set of final dbs its modules use (see
# _compile_per_module), with the libraries it has already collected.
def _package_dbs(libs: list, early: bool, final: [dict[str, bool], None], import_dirs_tag):
    packagedb_args = cmd_args()
    packagedb_set = {}
    hidden = cmd_args()

    local_import_dirs = []
    early_names = {}
    for lib in libs:
        if early and lib.early_db != None and (final == None or lib.name not in final):
            packagedb_set[lib.early_db] = None
            early_names[lib.name] = True
            continue
        packagedb_set[lib.db] = None
        import_dirs = list(lib.import_dirs.values())
        local_import_dirs += [d for d in import_dirs if not d.is_source]
        # libs of dependencies might be needed at compile time if we're
        # using Template Haskell. Per-module compiles track which of these
        # (and the interface dirs) they actually read through a dep file,
        # see _compile_per_module.
        dep_governed = [import_dirs, lib.libs]
        if import_dirs_tag != None:
            dep_governed = [import_dirs_tag.tag_artifacts(cmd_args(hidden = dep_governed))]
        hidden_args = cmd_args(
            hidden = [
                lib.stub_dirs,
            ] + dep_governed,
        )

        hidden.add(hidden_args)

        packagedb_args.add(hidden_args)

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add([cmd_args("-package-db", x) for x in packagedb_set])
    return struct(packagedb_args = packagedb_args, hidden = hidden, local_import_dirs = local_import_dirs, early_names = early_names)

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
    return "-fwrite-ide-info" in ctx.attrs.compiler_flags

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
    # A target with no modules (all its code is C, say) has nothing to compile
    # per module either.
    if getattr(ctx.attrs, "per_module", False) and [src for _, src in srcs_to_pairs(ctx.attrs.srcs) if is_haskell_src(src)]:
        return _compile_per_module(ctx, link_style, enable_profiling, pkgname, native_shared_libs_dir, dynamic_too)
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    compile_cmd = cmd_args(haskell_toolchain.compiler)

    args = compile_args(ctx, link_style, enable_profiling, pkgname, native_shared_libs_dir = native_shared_libs_dir, dynamic_too = dynamic_too)

    # A library with no modules (all its code is C, say) has nothing for GHC
    # to compile.
    if not [src for _, src in srcs_to_pairs(ctx.attrs.srcs) if is_haskell_src(src)]:
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
# instead of one `ghc --make` per target. See Note [Per-module compilation],
# Note [Early cut-off by dep files], Note [Compiling against dependencies
# module by module], Note [Template Haskell modules] and Note [The
# persistent worker].

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

def _source_stem(src: Artifact) -> str:
    # A source's path without its extension, as `ghc -M` writes the paths
    # of the files it will produce from it.
    path = src.short_path
    dot = path.rfind(".")
    return path if dot < 0 or "/" in path[dot:] else path[:dot]

def _node_from_path(path: str, by_stem: dict[str, str]) -> str | None:
    # `ghc -M` names files by the paths it was given, with extensions of its
    # own (plain .o/.hi whatever -osuf/-hisuf say, -boot for boot files), so
    # match on the source's path without extension, longest first: src/Bar
    # is also the end of src/Foo/Bar. A source is in the project or in
    # buck-out, never at an absolute path, where the interfaces of installed
    # packages are (one of which may well end in Main.hi too). The makefile
    # is the only machine output `ghc -M` has in released GHCs; a JSON one
    # (-dep-json, GHC merge request !16717) would replace this parsing and
    # the matching of dependencies' interfaces below.
    if path.startswith("/"):
        return None
    dot = path.rfind(".")
    stem, ext = (path, "") if dot < 0 else (path[:dot], path[dot + 1:])
    found = None
    for tail, mod in by_stem.items():
        if (stem == tail or stem.endswith("/" + tail)) and (found == None or len(tail) > len(found[0])):
            found = (tail, mod)
    if found == None:
        return None
    return found[1] + _BOOT if ext.endswith(_BOOT) else found[1]

# The directory of a target's per-module compile of one way, relative to the
# target's outputs; the modules' outputs are in "out" below it.
def per_module_dir(link_style: LinkStyle, enable_profiling: bool) -> str:
    return "per-module-" + get_artifact_suffix(link_style, enable_profiling) + "/"

def _dir_of(artifact, node: str, ext: str) -> cmd_args:
    # The output (or tree) directory of a node's file with the given
    # extension.
    return cmd_args(artifact, parent = _node_file(node, ext).count("/") + 1)

def _listed_node(path: str, nodes: list) -> str | None:
    # The node of a source by a path a script was given for it: its project
    # path, or a generated source's output path, which ends with that.
    for n, src in nodes:
        if not _is_boot(n) and (path == src.short_path or path.endswith("/" + src.short_path)):
            return n
    return None

def _read_deps_makefile(label, text: str, nodes: list, direct_module_libs: dict, out_marker: str):
    # From `ghc -M` output: each node's imports among the target's nodes, and
    # the (package id, module) pairs it imports from the dependencies
    # compiled per module.
    by_stem = {_source_stem(src): n for n, src in nodes if not _is_boot(n)}
    imports = {n: [] for n, _ in nodes}
    upstream = {n: [] for n, _ in nodes}
    for line in text.splitlines():
        if line.startswith("#") or ":" not in line:
            continue
        lhs, rhs = line.split(":", 1)
        lhs = lhs.strip()
        rhs = rhs.strip()
        tgt = _node_from_path(lhs, by_stem)
        if tgt == None:
            continue
        if rhs.startswith("buck-out/") and out_marker in rhs:
            # An interface of a dependency compiled per module: which
            # one, by the longest tail that matches (a package's path
            # may end with another's).
            lib = None
            for tail, candidate in direct_module_libs.items():
                if tail in rhs and (lib == None or len(tail) > len(lib.module_dir_tail)):
                    lib = candidate
            if lib != None:
                mod_path = rhs.split(out_marker, 1)[1]
                dot = mod_path.rfind(".")
                ext = mod_path[dot + 1:]
                mod = mod_path[:dot].replace("/", ".") + (_BOOT if ext.endswith(_BOOT) else "")
                if mod in lib.modules and (lib.name, mod) not in upstream[tgt]:
                    upstream[tgt].append((lib.name, mod))
            continue
        dep = _node_from_path(rhs, by_stem)
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

def _transitive_closure(nodes: list, imports: dict) -> dict:
    # Each node's imports, transitively; iteratively: Starlark has no
    # recursion.
    closure = {n: list(imports[n]) for n, _ in nodes}
    for _ in range(len(nodes)):
        changed = False
        for n, _ in nodes:
            for d in list(closure[n]):
                for x in closure[d]:
                    if x not in closure[n] and x != n:
                        closure[n].append(x)
                        changed = True
        if not changed:
            break
    return closure

def _dependency_order(label, nodes: list, imports: dict) -> list[str]:
    # The nodes, each after its imports.
    order = []
    done = {}
    for _ in range(len(nodes) + 1):
        progressed = False
        for n, _ in nodes:
            if n not in done and all([d in done for d in imports[n]]):
                order.append(n)
                done[n] = True
                progressed = True
        if not progressed:
            break
    if len(order) != len(nodes):
        fail("{}: import cycle among {}".format(label, ", ".join([n for n, _ in nodes if n not in done])))
    return order

def _read_splices(text: str, nodes: list):
    # From the deps script's output: the nodes it found Template Haskell (or
    # an ANN pragma) in. A line is a source's path, then "th".
    th = {}
    for line in text.splitlines():
        words = line.split()
        n = _listed_node(words[0], nodes) if words else None
        if n != None and words[1:2] == ["th"]:
            th[n] = True
    return th

# The version of the worker's request and of what it writes back (see
# tools/ghc-worker and the per-module compile script, which take the same
# request): the worker refuses a request of another version. Bump it, and
# the worker's, when either changes.
_WORKER_CONTRACT = "2"

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
#   module together, whose libraries exist from the start.
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
        for n in splice_deps.closures[name]:
            final[n] = True
        if splice_deps.trees[name] != None:
            trees.append(splice_deps.trees[name])
    return final, trees

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

def _compile_per_module(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None, native_shared_libs_dir: [Artifact, None], dynamic_too: bool) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    suffix = get_artifact_suffix(link_style, enable_profiling)
    osuf, hisuf = output_extensions(link_style, enable_profiling)
    prefix = per_module_dir(link_style, enable_profiling)
    out_marker = "/" + prefix + "out/"

    # The tag of everything a module's dep file may list: see Note [Early
    # cut-off by dep files].
    tag = ctx.actions.artifact_tag()

    # The package flags of a module: the final dbs of the given dependencies
    # (None: all of them), and the early dbs of the rest, without their
    # interface dirs or libraries (declared per module below). See Note
    # [Libraries of the early package dbs]. A module that runs no Template
    # Haskell compiles against the early dbs alone.
    early_packages = get_packages_info(ctx, link_style, specify_pkg_version = False, enable_profiling = enable_profiling, import_dirs_tag = tag, early = True)
    dep_libs = list(early_packages.transitive_deps.traverse())

    def packages(final):
        dbs = _package_dbs(dep_libs, final != None, final, tag)
        return struct(
            args = cmd_args(early_packages.exposed_package_args, dbs.packagedb_args),
            local_import_dirs = dbs.local_import_dirs,
            early_names = dbs.early_names,
        )

    early_set = packages({})

    # The trees of the shared libraries a Template Haskell module loads
    # (which depend on their links) are given to those modules' actions
    # only, below, not to every compile and the module graph.
    splice_deps = _splice_deps(ctx, link_style, enable_profiling, prefix, native_shared_libs_dir)
    th_set = _th_set(ctx, splice_deps)
    if th_set == None:
        target_th = packages(None)
        target_th_trees = [native_shared_libs_dir] if native_shared_libs_dir != None else []
    else:
        target_th = packages(th_set[0])
        target_th_trees = th_set[1]
    th_target = "-XTemplateHaskell" in ctx.attrs.compiler_flags or "-XQuasiQuotes" in ctx.attrs.compiler_flags
    module_libs = early_packages.module_libs
    this_pkg = pkgname or haskell_library_unit_id(ctx.label)

    cmd_flags, file_flags = _ghc_flags(ctx, link_style, enable_profiling, pkgname, dynamic_too)
    base_cmd = cmd_args(haskell_toolchain.compiler, cmd_flags, file_flags)
    env = _ghc_env(ctx, prefix + "build-tool-depends")

    # The persistent worker, if there is one: see Note [The persistent
    # worker]. The target's own (one the project builds) comes before the
    # toolchain's.
    worker_info = None
    worker = ctx.attrs.per_module_worker[RunInfo] if getattr(ctx.attrs, "per_module_worker", None) != None else haskell_toolchain.per_module_worker
    if worker != None:
        worker_cmd = _in_env(env, cmd_args(worker))
        worker_info = WorkerInfo(
            exe = worker_cmd,
            env = {"LD_LIBRARY_PATH": cmd_args(target_th_trees, delimiter = ":", ignore_artifacts = True)} if target_th_trees else {},
        )

    # The nodes of the graph: the modules, and their boot files as
    # "<module>-boot" (named so in a srcs dict; in a list they only have the
    # module's name).
    nodes = []
    for name, src in srcs_to_pairs(ctx.attrs.srcs):
        if is_haskell_src(src):
            nodes.append((name, src))
        elif src.short_path.endswith(_BOOT):
            nodes.append((name if _is_boot(name) else name + _BOOT, src))
    src_of = {n: src for n, src in nodes}

    # The tree of the target's sources, the worker's import path (see Note
    # [The persistent worker]). Tagged: the tree changes with any source of
    # the target, which is no reason to compile the others again (a
    # module's own source is an input in its own right).
    src_tree = None
    if worker_info != None:
        src_tree = ctx.actions.symlinked_dir(
            prefix + "srcs",
            {_node_file(n, "hs"): src for n, src in nodes},
            has_content_based_path = False,
        )

    # The outputs, all in one directory (so not at content-based paths),
    # which is the import path of every module's compile here and, through
    # the early package db, of the modules of dependents. Declared outside
    # the dynamic output so that they can be exported, with the directories
    # the rest of the rules consume, which are assembled from them.
    o_of = {}
    hi_of = {}
    abi_of = {}
    dyn_o_of = {}
    dyn_hi_of = {}
    for n, _ in nodes:
        o_of[n] = ctx.actions.declare_output(prefix + "out/" + _node_file(n, osuf), has_content_based_path = False)
        hi_of[n] = ctx.actions.declare_output(prefix + "out/" + _node_file(n, hisuf), has_content_based_path = False)
        abi_of[n] = ctx.actions.declare_output(prefix + "out/" + _node_file(n, "abi"), has_content_based_path = False)
        if dynamic_too:
            dyn_o_of[n] = ctx.actions.declare_output(prefix + "out/" + _node_file(n, "dyn_o"), has_content_based_path = False)
            dyn_hi_of[n] = ctx.actions.declare_output(prefix + "out/" + _node_file(n, "dyn_hi"), has_content_based_path = False)
    closures = ctx.actions.declare_output(prefix + "closures.json", has_content_based_path = False)
    objects = ctx.actions.declare_output("objects-" + suffix, dir = True, has_content_based_path = False)
    hi = ctx.actions.declare_output("hi-" + suffix, dir = True, has_content_based_path = False)
    stubs = ctx.actions.declare_output("stubs-" + suffix, dir = True, has_content_based_path = False)
    producing_indices = _producing_indices(ctx)

    # How dependents recognise this target's interfaces in their `ghc -M`
    # output: buck2 puts a target's outputs under <package>/__<name>__/ in
    # buck-out, and ours under per-module-<suffix>/out/ below that. Nothing
    # else in the rules depends on buck-out's layout; this does, because the
    # paths come back from GHC as text.
    module_dir_tail = "/" + (ctx.label.package + "/" if ctx.label.package else "") + "__" + ctx.label.name + "__/"

    # The trees of the dependencies' shared libraries go to the compile,
    # which puts them on LD_LIBRARY_PATH, as a tagged argument rather than
    # in the environment, so that a change to one only re-runs the modules
    # whose dep file lists it (the Template Haskell ones).
    target_ld_tree = tag.tag_artifacts(cmd_args(target_th_trees, delimiter = ":")) if target_th_trees else None

    # The module graph, with the interfaces each module imports from the
    # dependencies (by the paths their package dbs give them, which need not
    # exist yet), and which modules run Template Haskell (see the script).
    # Against the early dbs, so it needs nothing built. The boot files aren't
    # arguments: GHC finds them next to the sources.
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
        _in_env(env, cmd_args("sh", ctx.attrs._per_module_deps, splices_file.as_output(), hs_srcs, "--", deps_cmd)),
        category = "haskell_deps_" + suffix.replace("-", "_"),
    )

    # The dependencies compiled per module whose modules this target can
    # import (its direct dependencies), by the tail of their output path.
    direct_module_libs = {}
    for lib in attr_deps_haskell_lib_infos(ctx, link_style, enable_profiling):
        if lib.modules != None and lib.module_dir_tail != None:
            direct_module_libs[lib.module_dir_tail] = lib

    # The import directories the dep-file writer looks interfaces up in: the
    # --make libraries' (whole), and the output directories of the per-module
    # libraries a module compiles against the early dbs of.
    def out_dir_of(lib):
        for m, files in lib.modules.items():
            return _dir_of(files.hi, m, hisuf)
        return None

    module_lib_dirs = {name: out_dir_of(lib) for name, lib in module_libs.items()}

    def f(ctx, artifacts, outputs):
        imports, upstream = _read_deps_makefile(ctx.label, artifacts[deps_mk].read_string(), nodes, direct_module_libs, out_marker)
        closure = _transitive_closure(nodes, imports)

        # The closure across packages: this module's and its in-package
        # closure's imports from dependencies, and those modules' own
        # closures (which their targets wrote out, transitively complete).
        dep_closures = {lib.name: artifacts[lib.closures].read_json() for lib in direct_module_libs.values()}
        full = {}
        for n, _ in nodes:
            entries = {}
            for x in [n] + closure[n]:
                for pkg, mod in upstream[x]:
                    entries[(pkg, mod)] = True
                    for pm in dep_closures.get(pkg, {}).get(mod, []):
                        entries[(pm[0], pm[1])] = True
            full[n] = list(entries.keys())
        ctx.actions.write_json(
            outputs[closures].as_output(),
            {n: [[this_pkg, d] for d in closure[n]] + [[p, m] for p, m in full[n]] for n, _ in nodes},
        )

        th_nodes = _read_splices(artifacts[splices_file].read_string(), nodes)

        # Actions are registered in dependency order: a symlinked_dir can
        # only link artifacts that an action already produces.
        for n in _dependency_order(ctx.label, nodes, imports):
            # The module's own imports are found in the shared output
            # directory of all the modules, with the closure's files as
            # (tagged) inputs: a symlink tree per module cost more to
            # materialise than the compiles themselves.
            closure_files = []
            for d in closure[n]:
                closure_files += [outputs[hi_of[d]], outputs[abi_of[d]], outputs[o_of[d]]]
                if dynamic_too:
                    closure_files += [outputs[dyn_hi_of[d]], outputs[dyn_o_of[d]]]
            runs_th = not _is_boot(n) and (th_target or n in th_nodes)
            if not runs_th:
                mod_packages, ld_tree = early_set, None
            else:
                mod_packages, ld_tree = target_th, target_ld_tree
            hidirs = mod_packages.local_import_dirs + [d for name, d in module_lib_dirs.items() if d != None and name in mod_packages.early_names]

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
            if worker_info == None:
                module_flags.add("-ddump-hi", "-ddump-to-file", cmd_args(outputs[abi_of[n]].as_output(), format = "-ddump-file-prefix={}"))
            if closure[n]:
                module_flags.add(tag.tag_artifacts(cmd_args(_dir_of(outputs[hi_of[closure[n][0]]], closure[n][0], hisuf), hidden = closure_files, format = "-i{}")))
            if upstream_files:
                module_flags.add(tag.tag_artifacts(cmd_args(hidden = upstream_files)))
            if dynamic_too:
                module_flags.add("-dyno", outputs[dyn_o_of[n]].as_output(), "-dynohi", outputs[dyn_hi_of[n]].as_output())
            if producing_indices:
                hiedir = ctx.actions.declare_output(prefix + "hie/" + n, dir = True, has_content_based_path = False)
                module_flags.add("-hiedir", hiedir.as_output())
                mkdirs.append(hiedir.as_output())

            # The request, which the worker takes, and the compile script
            # without it: see Note [The persistent worker].
            depfile = ctx.actions.declare_output(prefix + "dep/" + n + ".dep", has_content_based_path = False)
            request = cmd_args(
                "--request",
                "--contract",
                _WORKER_CONTRACT,
                "--depfile",
                tag.tag_artifacts(depfile.as_output()),
                "--abi",
                outputs[abi_of[n]].as_output(),
                "--module",
                _module_of(n).replace(".", "/"),
                "--source",
                src_of[n],
                "--outdir",
                _dir_of(outputs[hi_of[n]].as_output(), n, hisuf),
                "--hisuf",
                hisuf,
                "--boot" if _is_boot(n) else [],
                ["--ldtree", ld_tree] if ld_tree != None else [],
                # The script only needs their paths; as inputs they are
                # dep-file governed like everything else the module may
                # read.
                tag.tag_artifacts(cmd_args(hidirs, format = "--hidir={}")),
                tag.tag_artifacts(cmd_args(src_tree, format = "--srcroot={}")) if src_tree != None else [],
                cmd_args(mkdirs, format = "--mkdir={}"),
                "--",
                base_cmd,
                mod_packages.args,
                "--",
                module_flags,
            )
            run = {"exe": WorkerRunInfo(worker = worker_info, exe = worker_cmd)} if worker_info != None else {}
            ctx.actions.run(
                request if worker_info != None else _in_env(env, cmd_args("sh", ctx.attrs._per_module_compile, request)),
                category = "haskell_compile_module_" + suffix.replace("-", "_"),
                identifier = n,
                # So that ghc can skip the compile when the interface it
                # would write is unchanged, as in --make mode (see compile()).
                no_outputs_cleanup = True,
                dep_files = {"hs": tag},
                **run
            )

        obj_map = {}
        hi_map = {}
        for n, _ in nodes:
            obj_map[_node_file(n, osuf)] = outputs[o_of[n]]
            hi_map[_node_file(n, hisuf)] = outputs[hi_of[n]]
            hi_map[_node_file(n, "abi")] = outputs[abi_of[n]]
            if dynamic_too:
                obj_map[_node_file(n, "dyn_o")] = outputs[dyn_o_of[n]]
                hi_map[_node_file(n, "dyn_hi")] = outputs[dyn_hi_of[n]]
        ctx.actions.symlinked_dir(outputs[objects].as_output(), obj_map, has_content_based_path = False)
        ctx.actions.symlinked_dir(outputs[hi].as_output(), hi_map, has_content_based_path = False)
        ctx.actions.symlinked_dir(outputs[stubs].as_output(), {}, has_content_based_path = False)

    all_outputs = [objects.as_output(), hi.as_output(), stubs.as_output(), closures.as_output()]
    for n, _ in nodes:
        all_outputs += [o_of[n].as_output(), hi_of[n].as_output(), abi_of[n].as_output()]
        if dynamic_too:
            all_outputs += [dyn_o_of[n].as_output(), dyn_hi_of[n].as_output()]
    ctx.actions.dynamic_output(
        dynamic = [deps_mk, splices_file] + [lib.closures for lib in direct_module_libs.values()],
        inputs = [src for _, src in nodes],
        outputs = all_outputs,
        f = f,
    )
    modules = {
        n: HaskellModuleFiles(hi = hi_of[n], abi = abi_of[n], dyn_hi = dyn_hi_of[n] if dynamic_too else None)
        for n, _ in nodes
    }
    return CompileResultInfo(objects = objects, hi = hi, stubs = stubs, producing_indices = producing_indices, modules = modules, closures = closures, module_dir_tail = module_dir_tail)

# Note [Per-module compilation]
#
# A target compiled per module has one `ghc -c` action per module instead of
# one `ghc --make` action, so that buck2 schedules its modules in parallel
# with everything else it has to do, and re-runs only those whose inputs
# changed (see Note [Early cut-off by dep files]).
#
# The module graph comes from a `ghc -M` action, which needs only the
# sources and the package dbs, not any compiled dependency. A dynamic_output
# reads it and registers the modules' actions. A module's .hs-boot is a node
# of the graph with an action of its own, from the "<module>-boot" entry of
# srcs (see boot_srcs in haskell.bzl): modules that {-# SOURCE #-} import it
# depend on that, and so does the module itself, since GHC checks that the
# two agree.
#
# Every module writes its object and interface to one output directory,
# which is the import path of every compile, and has the interfaces and
# objects of its transitive imports (Template Haskell loads objects) as
# inputs. The outputs are at fixed paths rather than content-based ones,
# since GHC finds them there by module name. The objects and hi directories
# the rest of the rules consume are assembled from them with symlinked_dir.
#
# Each one-shot compile loads the interfaces of its imports (and, for
# Template Haskell, the shared libraries of its dependencies), which
# `--make` loads once per target, so a target's modules take more CPU in
# total than its `--make` would. What is gained is the parallelism and the
# granularity of the rebuilds.

# Note [Early cut-off by dep files]
#
# After an edit, a module should be compiled again only when GHC's own
# recompilation check would say so. buck2 decides it per action, from a dep
# file: every file a module might read (interfaces, objects, libraries) is
# a tagged input, and after the compile the action lists those it did read;
# on the next build, only a change to a listed file re-runs the action.
#
# The list comes from the usages GHC records in the new interface, which is
# what its recompilation check reads (see Note [Reading the interface
# text]): for each import, the imported module's .abi file, and each object
# and library that a Template Haskell splice loaded, which GHC records as
# dependent files. The .abi file holds the interface's ABI hash; each action
# writes it next to the interface. The compile script
# (tools/per_module_compile.sh) writes both from the interface's text, the
# persistent worker from the interface. Listing the interface itself would
# recompile every importer after a comment-only edit, since its bytes
# include the hash of the source.
#
# The action keeps its previous outputs (no_outputs_cleanup), so that GHC,
# when it does run, can still find the module up to date, as `--make` does.

# Note [Compiling against dependencies module by module]
#
# A module that runs no Template Haskell needs only the interfaces it
# imports from its dependencies, and their transitive closure, which GHC
# reads for instances and type families. A dependency compiled per module
# writes those one by one, so the module depends on them alone, not on the
# dependency's whole interface directory or its library, and can start
# before the dependency is fully compiled, let alone linked.
#
# It compiles against the dependency's early package db (see the `early`
# argument of _make_package in haskell.bzl): the package without its
# library, whose import directory is the one the dependency's modules write
# their interfaces to, registered before anything is compiled. Its final
# db, registered once the library is built, is the one a --make compile
# uses. The interfaces a module imports come from `ghc -M -include-pkg-deps`,
# which names each by the path the package db gives it, before it exists;
# the path's tail (module_dir_tail) says which dependency it belongs to, the
# one place the rules depend on buck-out's layout. Their closure comes from
# the dependencies' own: every per-module target writes out the closure of
# each of its modules across packages, transitively complete, so a target
# reads only its direct dependencies'.

# Note [Template Haskell modules]
#
# A module that runs Template Haskell, or evaluates an ANN pragma (which
# GHC does with its interpreter too), runs its dependencies' code at
# compile time, so it needs their libraries, not just their interfaces. By
# default it compiles against all the dependencies' final package dbs, with
# their libraries as inputs and the tree of their shared libraries on
# LD_LIBRARY_PATH, so it waits for all of them to be linked, as a --make
# compile does. The trees are given to these modules' compiles alone, as
# tagged inputs, so that a relink re-runs only the modules whose dep files
# list the library. The other modules compile against the early dbs, which name no
# library: see Note [Libraries of the early package dbs].
#
# A target's th_build_depends narrows that to the dependencies its splices
# run code from (see _th_set). Its Template Haskell modules then compile
# against the final dbs of those and of every dependency not compiled per
# module, whose libraries exist from the start, closed over their own
# dependencies, and against the early dbs of the rest. The shared libraries
# are in a tree per dependency compiled per module, and one for the rest
# (see _splice_deps), so that a module's LD_LIBRARY_PATH can list those of
# its set alone. A splice that runs code from a dependency left out fails
# to compile, naming the symbol it couldn't load.
#
# Which modules run Template Haskell is decided before any compile, from
# the target's flags and from the sources: the deps script
# (tools/per_module_deps.sh) looks for the extensions' names and for ANN
# pragmas. It can find too much (a name in a comment), which only makes a
# module wait for more.

# Note [The persistent worker]
#
# What remains of the per-module build's cost over --make is a GHC process
# per module, each reading the interfaces of its imports again. A buck2
# persistent worker (tools/ghc-worker) takes that away: buck2 sends the
# compiles of a target (and way) to one process, which compiles each as it
# arrives, concurrently, in a GHC session that keeps what it has read.
#
# A module's action is the same request with or without a worker: the
# worker takes it, and without one the compile script runs it as one
# `ghc -c`. When buck2 runs an action without the worker, as it may, it
# runs the worker program, which compiles the one module and exits. The
# request carries the module's source and its compile's flags in two parts,
# those of the module's session and the module's own. The worker keeps a
# session per set of session flags (a Template Haskell module's package
# dbs differ from the others', see Note [Template Haskell modules]), and
# ignores the module's own flags but for -hiedir. _WORKER_CONTRACT names
# the version of the request, which a worker installed for other rules
# refuses.
#
# The worker gets the environment of a compile when it starts, before the
# libraries are linked, so the shared library trees go in it by path only:
# starting it waits for no link, and a Template Haskell module's action
# materialises its trees before it is dispatched. Its session finds the
# modules a compile imports by name, on an import path: a tree of the
# target's sources alone, since in the project's source directories a
# module of another target (a sublibrary's, say) would be found before that
# target's package. The worker has no concurrency limit of its own: buck2's
# -j bounds the actions in workers with the rest, and a lower limit per
# worker would only hold a target's modules back.

# Note [Reading the interface text]
#
# The dep file of a module is taken from the interface GHC wrote for it, by
# the usages GHC records there: that is what GHC's own recompilation check
# reads, so the policy is exactly its own. The interface is a binary format,
# though, and the only reader GHC ships is the pretty-printer behind
# --show-iface and -ddump-hi, meant for people. The script parses three
# things out of it: the "ABI hash:" line, the "import  -/  Mod hash" usage
# lines (the first of which GHC 9.14 prints on the "usages: [" line), and the
# addDependentFile "path" lines for what a splice loaded. None of that is
# promised to stay as it is (GHC issue #25562 asked for a machine-readable
# form and got none); a release that changes it breaks the dep files, which
# would show as modules never being skipped, or as the "no interface dump"
# error. The sanctioned way to read an interface is the GHC API, as a small
# executable built against the GHC in use, which a project could build the
# way it builds its other tools; the Stack project's hi-file-parser library
# reads the same fields without the GHC API, by following the format by hand
# per release.

# Note [Libraries of the early package dbs]
#
# A module that runs Template Haskell (or evaluates an ANN pragma) runs code
# in GHC's interpreter, which first loads the library of every package
# exposed on the command line and of their dependencies (GHC's "preload"
# units), whether or not the splice uses it. A dynamically linked GHC
# tolerates a package whose library file isn't there: it warns, or says
# nothing, and carries on. But a library that is there and was linked
# against one that isn't fails to load in the system's dynamic linker, and
# the compile with it. buck2 doesn't sandbox local actions, so files a
# compile doesn't declare as inputs may or may not be on disk: a library
# not yet linked, or not materialised, beside one that is.
#
# So a package db either names a library that the compile depends on, or
# none. The early dbs name none: they are what a module compiles against
# before its dependencies are linked. A module that runs Template Haskell
# compiles against the final dbs of the packages whose libraries it
# depends on: all of them, or with th_build_depends those listed and those
# not compiled per module, closed over their dependencies (each of their
# libraries was linked against those), and the early dbs of the rest. Every
# other module compiles against the early dbs, and never starts the
# interpreter.
