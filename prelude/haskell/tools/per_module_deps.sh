#!/bin/sh
# The module graph of a target compiled per module (see _compile_per_module
# in prelude/haskell/compile.bzl): runs `ghc -M`, then writes, for each
# source that runs Template Haskell or has explicit level imports, a line of
# its path, then "th" if it runs Template Haskell, then "splice" and the
# modules it imports at the splice level if it has explicit level imports.
#
# usage: per_module_deps.sh OUT ELI_TARGET SRCS... -- GHC_M_COMMAND...
#
# A source runs Template Haskell if it enables an extension of it itself
# (the target may for all of them) or has an ANN pragma, which GHC evaluates
# with its interpreter at compile time the same way. It has explicit level
# imports by its own pragmas or, with ELI_TARGET=1, the target's flags,
# unless its pragmas turn them off. See Note [Explicit level imports].
out=$1
eli_target=$2
shift 2
srcs=""
while [ "$1" != "--" ]; do
  srcs="$srcs $1"
  shift
done
shift
"$@" || exit $?

# The extensions a source's LANGUAGE and OPTIONS_GHC pragmas name.
exts() {
  tr '\n\t' '  ' < "$1" |
    grep -o -i -E '\{-# *(LANGUAGE|OPTIONS_GHC)[^#]*#-\}' |
    tr ', ' '\n\n' |
    sed -n -E 's/^(-X)?([A-Z][A-Za-z]*)$/\2/p'
}

# The modules of the import declarations, wherever their lines break, that
# have `splice` before or after the module name.
splice_imports() {
  tr '\n\t' '  ' < "$1" |
    grep -o -E '(^| )import( +(\{-# *SOURCE *#-\}|safe|splice|qualified|"[^"]*"))* +[A-Z][A-Za-z0-9_.]*( +(splice|qualified))*' |
    awk '/ splice( |$)/ { for (i = 2; i <= NF; i++) if ($i ~ /^[A-Z]/ && $i != "SOURCE") { printf " %s", $i; break } }'
}

for f in $srcs; do
  line=""
  if grep -q -E 'TemplateHaskell|QuasiQuotes|\{-# *ANN ' "$f"; then
    line=" th"
  fi
  e=$(exts "$f")
  eli=$eli_target
  if printf '%s\n' "$e" | grep -q -x -E 'ExplicitLevelImports|NoImplicitStagePersistence'; then eli=1; fi
  if printf '%s\n' "$e" | grep -q -x -E 'NoExplicitLevelImports|ImplicitStagePersistence'; then eli=0; fi
  if [ "$eli" = 1 ]; then
    line="$line splice$(splice_imports "$f")"
  fi
  if [ -n "$line" ]; then
    printf '%s%s\n' "$f" "$line"
  fi
done > "$out"
