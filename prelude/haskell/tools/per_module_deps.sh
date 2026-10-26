#!/bin/sh
# The module graph of a target compiled per module (see _compile_per_module
# in prelude/haskell/compile.bzl): runs `ghc -M`, then writes, for each
# source that runs Template Haskell, a line of its path and "th".
#
# usage: per_module_deps.sh OUT SRCS... -- GHC_M_COMMAND...
#
# A source runs Template Haskell if it enables an extension of it itself
# (the target may for all of them) or has an ANN pragma, which GHC evaluates
# with its interpreter at compile time the same way.
out=$1
shift
srcs=""
while [ "$1" != "--" ]; do
  srcs="$srcs $1"
  shift
done
shift
"$@" || exit $?

for f in $srcs; do
  if grep -q -E 'TemplateHaskell|QuasiQuotes|\{-# *ANN ' "$f"; then
    printf '%s th\n' "$f"
  fi
done > "$out"
