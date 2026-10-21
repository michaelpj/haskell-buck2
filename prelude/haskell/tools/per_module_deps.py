#!/usr/bin/env python3
# The module graph of a target compiled per module (see _compile_per_module
# in prelude/haskell/compile.bzl): runs `ghc -M`, then writes, for each
# source that runs Template Haskell or has explicit level imports, a line of
# its path, then "th" if it runs Template Haskell, then "splice" and the
# modules it imports at the splice level if it has explicit level imports.
#
# usage: per_module_deps.py OUT ELI_TARGET SRCS... -- GHC_M_COMMAND...
#
# A source runs Template Haskell if its own pragmas enable TemplateHaskell
# or QuasiQuotes (the target's flags may enable them for every source,
# which compile.bzl takes into account), or if it has an ANN pragma, which
# GHC also evaluates with its interpreter. It has explicit level imports by
# its own pragmas or, with ELI_TARGET=1, the target's flags, unless its
# pragmas turn them off. See Note [Explicit level imports] in
# prelude/haskell/compile.bzl.

import re
import subprocess
import sys

# A source that may run Template Haskell (TemplateHaskellQuotes, which runs
# nothing, matches too).
MAY_RUN_TH = re.compile(r"TemplateHaskell|QuasiQuotes|\{-# *ANN ")
# A source whose pragmas may change the target's explicit level imports (a
# source that doesn't name such an extension can't enable it).
MAY_SET_ELI = re.compile(r"ExplicitLevelImports|ImplicitStagePersistence")
# The LANGUAGE and OPTIONS_GHC pragmas, and the extensions they name.
PRAGMA = re.compile(r"\{-# *(?:LANGUAGE|OPTIONS_GHC)[^#]*#-\}", re.IGNORECASE)
EXTENSION = re.compile(r"^(?:-X)?([A-Z][A-Za-z]*)$")
# An import declaration, wherever its lines break, with `splice` before or
# after the module name if it has one.
IMPORT = re.compile(r'(?:^| )import(?: +(?:\{-# *SOURCE *#-\}|safe|splice|qualified|"[^"]*"))* +[A-Z][A-Za-z0-9_.]*(?: +(?:splice|qualified))*')
SPLICE = re.compile(r" splice(?: |$)")


def one_line(text):
    return text.replace("\n", " ").replace("\t", " ")


def extensions(text):
    exts = set()
    for pragma in PRAGMA.findall(one_line(text)):
        # Without the "{-#" and "#-}", which may touch an extension's name.
        for word in re.split(r"[, ]", pragma[3:-3]):
            m = EXTENSION.match(word)
            if m:
                exts.add(m.group(1))
    return exts


def splice_imports(text):
    """The modules of the import declarations with `splice`."""
    mods = []
    for decl in IMPORT.findall(one_line(text)):
        if SPLICE.search(decl):
            mods += [w for w in decl.split()[1:] if w[:1].isupper() and w != "SOURCE"][:1]
    return mods


def main():
    out, eli_target = sys.argv[1], sys.argv[2] == "1"
    args = sys.argv[3:]
    sep = args.index("--")
    srcs, command = args[:sep], args[sep + 1:]
    code = subprocess.call(command)
    if code != 0:
        sys.exit(code if code > 0 else 128 - code)

    lines = []
    for src in srcs:
        with open(src, encoding="utf-8", errors="replace") as f:
            text = f.read()
        line = " th" if MAY_RUN_TH.search(text) else ""
        eli = eli_target
        if MAY_SET_ELI.search(text):
            exts = extensions(text)
            if exts & {"ExplicitLevelImports", "NoImplicitStagePersistence"}:
                eli = True
            if exts & {"NoExplicitLevelImports", "ImplicitStagePersistence"}:
                eli = False
        if eli:
            line += " " + " ".join(["splice"] + splice_imports(text))
        if line:
            lines.append(src + line + "\n")
    with open(out, "w") as f:
        f.writelines(lines)


if __name__ == "__main__":
    main()
