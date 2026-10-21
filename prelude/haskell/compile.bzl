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
    local_import_dirs = field(list[Artifact], []),
)

def _package_flag(toolchain: HaskellToolchainInfo) -> str:
    if toolchain.support_expose_package:
        return "-expose-package"
    else:
        return "-package"

def get_packages_info(ctx: AnalysisContext, link_style: LinkStyle, specify_pkg_version: bool, enable_profiling: bool, import_dirs_tag = None) -> PackagesInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)
    libs = ctx.actions.tset(
        HaskellLibraryInfoTSet,
        children = [lib.prof_info[link_style] if enable_profiling else lib.info[link_style] for lib in direct_deps_link_info],
    )

    package_flag = _package_flag(haskell_toolchain)
    exposed_package_args = cmd_args()

    packagedb_args = cmd_args()
    packagedb_set = {}

    local_import_dirs = []
    for lib in libs.traverse():
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

        exposed_package_args.add(hidden_args)

        packagedb_args.add(hidden_args)

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add([cmd_args("-package-db", x) for x in packagedb_set])

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
        packagedb_args = packagedb_args,
        transitive_deps = libs,
        local_import_dirs = local_import_dirs,
    )

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
# instead of one `ghc --make` per target. See Note [Per-module compilation]
# and Note [Early cut-off by dep files].

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

def _read_deps_makefile(label, text: str, nodes: list) -> dict:
    # From `ghc -M` output: each node's imports among the target's nodes.
    by_stem = {_source_stem(src): n for n, src in nodes if not _is_boot(n)}
    imports = {n: [] for n, _ in nodes}
    for line in text.splitlines():
        if line.startswith("#") or ":" not in line:
            continue
        lhs, rhs = line.split(":", 1)
        tgt = _node_from_path(lhs.strip(), by_stem)
        dep = _node_from_path(rhs.strip(), by_stem)
        if tgt == None or dep == None or tgt == dep:
            # A module's dependency on its own source, or a file that
            # isn't one of the target's (a header the C preprocessor
            # includes, say).
            continue
        if tgt not in imports or dep not in imports:
            fail("{}: `ghc -M` says {} depends on {}, but srcs has no such module (or boot file)".format(label, tgt, dep))
        if dep not in imports[tgt]:
            imports[tgt].append(dep)
    return imports

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

def _compile_per_module(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None, native_shared_libs_dir: [Artifact, None], dynamic_too: bool) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    suffix = get_artifact_suffix(link_style, enable_profiling)
    osuf, hisuf = output_extensions(link_style, enable_profiling)
    prefix = per_module_dir(link_style, enable_profiling)

    # The tag of everything a module's dep file may list: see Note [Early
    # cut-off by dep files].
    tag = ctx.actions.artifact_tag()

    packages = get_packages_info(ctx, link_style, specify_pkg_version = False, enable_profiling = enable_profiling, import_dirs_tag = tag)
    cmd_flags, file_flags = _ghc_flags(ctx, link_style, enable_profiling, pkgname, dynamic_too)
    base_cmd = cmd_args(haskell_toolchain.compiler, cmd_flags, file_flags, packages.exposed_package_args, packages.packagedb_args)
    env = _ghc_env(ctx, prefix + "build-tool-depends")

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

    # The outputs, all in one directory (so not at content-based paths),
    # which is the import path of every module's compile here, with the
    # directories the rest of the rules consume, which are assembled from
    # them.
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
    objects = ctx.actions.declare_output("objects-" + suffix, dir = True, has_content_based_path = False)
    hi = ctx.actions.declare_output("hi-" + suffix, dir = True, has_content_based_path = False)
    stubs = ctx.actions.declare_output("stubs-" + suffix, dir = True, has_content_based_path = False)
    producing_indices = _producing_indices(ctx)

    # The tree of the dependencies' shared libraries goes to the compile,
    # which puts it on LD_LIBRARY_PATH, as a tagged argument rather than in
    # the environment, so that a change to one only re-runs the modules
    # whose dep file lists it (the Template Haskell ones).
    ld_tree = tag.tag_artifacts(cmd_args(native_shared_libs_dir)) if native_shared_libs_dir != None else None

    # The module graph. The boot files aren't arguments: GHC finds them next
    # to the sources.
    deps_mk = ctx.actions.declare_output(prefix + "deps.mk")
    deps_cmd = cmd_args(
        base_cmd,
        "-M",
        "-dep-makefile",
        deps_mk.as_output(),
        "-dep-suffix",
        "",
        [src for n, src in nodes if not _is_boot(n)],
        hidden = [src for n, src in nodes if _is_boot(n)],
    )
    ctx.actions.run(_in_env(env, deps_cmd), category = "haskell_deps_" + suffix.replace("-", "_"))

    def f(ctx, artifacts, outputs):
        imports = _read_deps_makefile(ctx.label, artifacts[deps_mk].read_string(), nodes)
        closure = _transitive_closure(nodes, imports)

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

            # The module's own flags, after those of its session.
            stubdir = ctx.actions.declare_output(prefix + "stubs/" + n, dir = True, has_content_based_path = False)
            module_flags = cmd_args("-c", src_of[n], "-o", outputs[o_of[n]].as_output(), "-ohi", outputs[hi_of[n]].as_output(), "-stubdir", stubdir.as_output())
            mkdirs = [stubdir.as_output()]
            module_flags.add("-ddump-hi", "-ddump-to-file", cmd_args(outputs[abi_of[n]].as_output(), format = "-ddump-file-prefix={}"))
            if closure[n]:
                module_flags.add(tag.tag_artifacts(cmd_args(_dir_of(outputs[hi_of[closure[n][0]]], closure[n][0], hisuf), hidden = closure_files, format = "-i{}")))
            if dynamic_too:
                module_flags.add("-dyno", outputs[dyn_o_of[n]].as_output(), "-dynohi", outputs[dyn_hi_of[n]].as_output())
            if producing_indices:
                hiedir = ctx.actions.declare_output(prefix + "hie/" + n, dir = True, has_content_based_path = False)
                module_flags.add("-hiedir", hiedir.as_output())
                mkdirs.append(hiedir.as_output())

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
                ["--ldtree", ld_tree] if ld_tree != None else [],
                # The script only needs their paths; as inputs they are
                # dep-file governed like everything else the module may
                # read.
                tag.tag_artifacts(cmd_args(packages.local_import_dirs, format = "--hidir={}")),
                cmd_args(mkdirs, format = "--mkdir={}"),
                "--",
                base_cmd,
                "--",
                module_flags,
            )
            ctx.actions.run(
                _in_env(env, cmd_args("sh", ctx.attrs._per_module_compile, request)),
                category = "haskell_compile_module_" + suffix.replace("-", "_"),
                identifier = n,
                # So that ghc can skip the compile when the interface it
                # would write is unchanged, as in --make mode (see compile()).
                no_outputs_cleanup = True,
                dep_files = {"hs": tag},
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

    all_outputs = [objects.as_output(), hi.as_output(), stubs.as_output()]
    for n, _ in nodes:
        all_outputs += [o_of[n].as_output(), hi_of[n].as_output(), abi_of[n].as_output()]
        if dynamic_too:
            all_outputs += [dyn_o_of[n].as_output(), dyn_hi_of[n].as_output()]
    ctx.actions.dynamic_output(
        dynamic = [deps_mk],
        inputs = [src for _, src in nodes],
        outputs = all_outputs,
        f = f,
    )
    return CompileResultInfo(objects = objects, hi = hi, stubs = stubs, producing_indices = producing_indices)

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
# writes it next to the interface. Listing the interface itself would
# recompile every importer after a comment-only edit, since its bytes
# include the hash of the source.
#
# The action keeps its previous outputs (no_outputs_cleanup), so that GHC,
# when it does run, can still find the module up to date, as `--make` does.

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

