#!/bin/sh
# Compiles one module of a target compiled per module with `ghc -c`, then
# writes the module's .abi file and buck2 dep file (see _compile_per_module
# in prelude/haskell/compile.bzl):
#
#   --depfile FILE --abi FILE --module Foo/Bar --outdir DIR --hisuf SUF
#   [--ldtree DIRS] [--hidir=DIR]... [--mkdir=DIR]...
#   -- GHC SESSION_FLAGS... -- MODULE_FLAGS...
#
# The compile is GHC with the session's flags then the module's. The .abi
# file and the dep file come from the text of the new interface, which the
# compile dumps itself (-ddump-hi: the same text as --show-iface, which
# would cost a second GHC start per module). See Note [Reading the
# interface text] in compile.bzl.
hidirs=""
while [ "$1" != "--" ]; do
  case "$1" in
    --depfile) depfile=$2; shift 2 ;;
    --abi) abi=$2; shift 2 ;;
    --module) self=$2; shift 2 ;;
    --outdir) outdir=$2; shift 2 ;;
    --hisuf) hisuf=$2; shift 2 ;;
    --ldtree) export LD_LIBRARY_PATH="$2"; shift 2 ;;
    --hidir=*) hidirs="$hidirs ${1#--hidir=}"; shift ;;
    --mkdir=*) mkdir -p "${1#--mkdir=}"; shift ;;
    *) echo "per_module_compile.sh: unexpected argument $1" >&2; exit 2 ;;
  esac
done
shift

# The compile's command: everything left but the "--" between the session's
# flags and the module's.
sep=0
for a do
  shift
  if [ "$a" = "--" ] && [ "$sep" = 0 ]; then
    sep=1
    continue
  fi
  set -- "$@" "$a"
done
"$@" || exit $?

# Dep file entries are paths from the project root to the real files: a
# tree entry is a symlink, and buck2 digests the link itself.
root=$(pwd)
rel() {
  r=$(readlink -f "$1")
  case "$r" in "$root"/*) printf '%s\n' "${r#"$root"/}" ;; esac
}

# The dump's name carries the way (Mod.dyn.dump-hi, Mod.p.dump-hi); a
# -dynamic-too compile writes one per way, with the same usages.
iface=$(ls "$abi".*dump-hi 2>/dev/null | head -1)
[ -n "$iface" ] || { echo "no interface dump next to $abi" >&2; exit 1; }
awk '/ABI hash:/{print $3}' "$iface" > "$abi"

# The imported modules are looked up in the modules' output directory, then
# in the interface dirs of the local dependencies (as .abi, or as the
# interface of a dependency built with --make, which has no .abi). A module
# with a boot file also depends on the boot's interface. The files a splice
# loaded are the interface's "addDependentFile" usages, by the paths GHC
# loaded them from (objects in the output directory, libraries in the
# LD_LIBRARY_PATH trees); those outside the project (the libraries of GHC's
# own package db) are no inputs of the action and are left out.
{
  # The import lines: "import  -/  Mod hash" (the first one on the "usages:"
  # line in GHC 9.14).
  sed -n -E 's/^.*import  -\/  ([^ ,]*).*/\1/p' "$iface" | while read -r mod; do
    mod=${mod#*:}  # GHC prefixes the modules of its home unit with the unit id
    p=$(printf '%s' "$mod" | tr . /)
    found=0
    for f in "$outdir/$p.abi" "$outdir/$p.abi-boot"; do
      if [ -e "$f" ]; then rel "$f"; found=1; fi
    done
    if [ "$found" = 1 ]; then continue; fi
    for d in $hidirs; do
      if [ -e "$d/$p.abi" ]; then rel "$d/$p.abi"; break; fi
      if [ -e "$d/$p.$hisuf" ]; then rel "$d/$p.$hisuf"; break; fi
    done
  done
  if [ -e "$outdir/$self.abi-boot" ]; then rel "$outdir/$self.abi-boot"; fi
  sed -n 's/^ *addDependentFile "\([^"]*\)".*/\1/p' "$iface" | while read -r f; do rel "$f"; done
} > "$depfile"
rm -f "$abi".*dump-hi
