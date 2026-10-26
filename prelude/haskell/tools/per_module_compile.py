#!/usr/bin/env python3
# Compiles one module of a target compiled per module with `ghc -c`, then
# writes the module's .abi file and buck2 dep file, from the request the
# persistent worker would take for it (see tools/ghc-worker and
# _compile_per_module in prelude/haskell/compile.bzl):
#
#   --request --contract V --depfile FILE --abi FILE --module Foo/Bar
#   --source FILE --outdir DIR --hisuf SUF [--boot] [--ldtree DIRS]
#   [--link=MODULE]... [--hidir=DIR]... [--srcroot=DIR]... [--mkdir=DIR]...
#   -- GHC SESSION_FLAGS... -- MODULE_FLAGS...
#
# The compile is GHC with the session's flags then the module's. The
# session's flags are those the target's modules share (with the same
# package dbs); the module's own are its source and outputs. The worker
# keeps a session per set of session flags; here the two are just joined
# again. The .abi file and the dep file come from the text of the new
# interface, which the compile dumps itself (-ddump-hi: the same text as
# --show-iface, which would cost a second GHC start per module). See Note
# [Reading the interface text] in compile.bzl.

import glob
import os
import re
import subprocess
import sys

# The lines of the interface dump that this script reads. See Note [Reading
# the interface text] in compile.bzl.

# "ABI hash: <hash>"
ABI_HASH = re.compile(r"ABI hash:\s+(\S+)")
# A usage of an imported module: "import  -/  Mod hash", or "import safe Mod
# hash" for a safe import. GHC 9.14 prints the first of them on the
# "usages: [" line, so the import is the last one on its line.
IMPORT = re.compile(r"^.*import +(?:-/|safe) +([^ ,]*)")
# What looks like a usage, which some IMPORT line must match.
LOOKS_LIKE_IMPORT = re.compile(r" -/ |import safe ")
# A file a splice loaded: `addDependentFile "path"`.
DEPENDENT_FILE = re.compile(r'^ *addDependentFile "([^"]*)"')
# The direct module dependencies, which mark a module imported only as a
# boot file "[boot]": "direct module dependencies: unit:Mod [boot] ...",
# wrapped onto lines that start with a space.
DIRECT_DEPS = "direct module dependencies:"


class Dump:
    """What the script reads from an interface dump."""

    def __init__(self, text):
        lines = text.splitlines()
        self.abi_hashes = [m.group(1) for m in map(ABI_HASH.search, lines) if m]
        self.imports = [m.group(1) for m in map(IMPORT.match, lines) if m]
        self.looks_like_imports = any(LOOKS_LIKE_IMPORT.search(line) for line in lines)
        self.dependent_files = [m.group(1) for m in map(DEPENDENT_FILE.match, lines) if m]
        self.boots = set()
        words = []
        in_deps = False
        for line in lines:
            if line.startswith(DIRECT_DEPS):
                in_deps = True
                words += line[len(DIRECT_DEPS):].split()
            elif in_deps and line.startswith(" "):
                words += line.split()
            else:
                in_deps = False
        for prev, word in zip(words, words[1:]):
            if word == "[boot]":
                self.boots.add(prev.rsplit(":", 1)[-1])

    def readable(self):
        """Whether the dump has what the script needs: an ABI hash, and
        import lines if it has anything that looks like a usage (a module
        may import nothing). A dump the script can't read would make an empty
        or partial dep file, and the module would never be compiled again."""
        return bool(self.abi_hashes) and (any(self.imports) or not self.looks_like_imports)


def parse_args(args):
    request = {"hidirs": []}
    i = 0
    while args[i] != "--":
        a = args[i]
        if a in ("--request", "--boot"):
            i += 1
        elif a in ("--contract", "--source"):
            i += 2
        elif a in ("--depfile", "--abi", "--module", "--outdir", "--hisuf", "--ldtree"):
            request[a[2:]] = args[i + 1]
            i += 2
        elif a.startswith("--hidir="):
            request["hidirs"].append(a[len("--hidir="):])
            i += 1
        elif a.startswith("--mkdir="):
            os.makedirs(a[len("--mkdir="):], exist_ok=True)
            i += 1
        elif a.startswith(("--srcroot=", "--link=")):
            i += 1
        else:
            print("per_module_compile.py: unexpected argument " + a, file=sys.stderr)
            sys.exit(2)
    # The compile's command: everything left but the "--" between the
    # session's flags and the module's.
    rest = args[i + 1:]
    if "--" in rest:
        rest.remove("--")
    return request, rest


def dep_file_entries(request, dump):
    """The dep file's entries, as paths from the project root to the real
    files: a tree entry is a symlink, and buck2 digests the link itself.

    The imported modules are looked up in the modules' output directory,
    then in the interface dirs of the local dependencies (as .abi, or as the
    interface of a dependency built with --make, which has no .abi). A
    module imported only {-# SOURCE #-} is looked up by its boot file's
    (".abi-boot"). The files a splice loaded are those GHC loaded them from
    (the target's objects in the output directory). Files outside the
    project (the libraries of GHC's own package db) are not inputs of the
    action, and are left out."""
    root = os.getcwd()
    outdir = request["outdir"]

    def rel(path):
        real = os.path.realpath(path)
        if real.startswith(root + os.sep):
            yield os.path.relpath(real, root)

    for mod in dump.imports:
        if not mod:
            continue
        # GHC prefixes the modules of its home unit with the unit id.
        mod = mod.split(":", 1)[-1]
        p = mod.replace(".", "/")
        f = os.path.join(outdir, p + (".abi-boot" if mod in dump.boots else ".abi"))
        if os.path.exists(f):
            yield from rel(f)
            continue
        for d in request["hidirs"]:
            found = [f for f in (os.path.join(d, p + ".abi"), os.path.join(d, p + "." + request["hisuf"])) if os.path.exists(f)]
            if found:
                yield from rel(found[0])
                break
    # A module with a boot file depends on the boot's interface too (GHC
    # checks they agree), except in the boot's own compile, which writes it.
    own_boot = os.path.join(outdir, request["module"] + ".abi-boot")
    if request["abi"] != own_boot and os.path.exists(own_boot):
        yield from rel(own_boot)
    for f in dump.dependent_files:
        yield from rel(f)


def main():
    request, command = parse_args(sys.argv[1:])
    env = dict(os.environ)
    if "ldtree" in request:
        env["LD_LIBRARY_PATH"] = request["ldtree"]
    code = subprocess.call(command, env=env)
    if code != 0:
        sys.exit(code if code > 0 else 128 - code)

    abi = request["abi"]
    # The dump's name carries the way (Mod.dyn.dump-hi, Mod.p.dump-hi); a
    # -dynamic-too compile writes one per way, with the same usages.
    dumps = sorted(glob.glob(glob.escape(abi) + ".*dump-hi"))
    if not dumps:
        sys.exit("no interface dump next to " + abi)
    with open(dumps[0], encoding="utf-8", errors="replace") as f:
        dump = Dump(f.read())
    with open(abi, "w") as f:
        f.writelines(h + "\n" for h in dump.abi_hashes)
    if not dump.readable():
        sys.exit("per_module_compile.py: can't read the ABI hash or usages in {}; has the format of GHC's interface dump changed?".format(dumps[0]))
    entries = list(dep_file_entries(request, dump))
    with open(request["depfile"], "w") as f:
        f.writelines(e + "\n" for e in entries)
    for d in dumps:
        os.remove(d)


if __name__ == "__main__":
    main()
