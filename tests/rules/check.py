#!/usr/bin/env python3
"""The checks of the per-module rules, run in the test project by run.sh.

Each check builds what it needs, reads what the rules decided from buck2
(the command lines of `buck2 log what-ran`, `buck2 audit dep-files`, the
static actions of `buck2 aquery`) and compares sets of short names (see
short()) with what it expects, saying what is missing and what is not
expected. The checks run in order, on one project: some edit its sources.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time
import traceback

MAIN_TARGETS = ["//a:a", "//b:b", "//th:th", "//c:c", "//c:show", "//d:d", "//cyc:cyc", "//main:main", "//rx:rx", "//ux:ux", "//tie:tie", "//rp:rp"]
ELI_TARGETS = ["//e:e", "//elr:elr"]
# The modules compiled without the worker even when the project has one
# (see check_workers): c's splices run th's code; e's and elr's (`import
# splice`) run a's.
NO_WORKER = {"c:C.Splice", "c:C.Ann"}
NO_WORKER_ELI = {"e:E.Gen", "e:E.Lib", "elr:ER.M"}

LOG_DIR = "buck-logs"


class CheckFailed(Exception):
    pass


# --- Running buck2 ---------------------------------------------------------

_run_count = 0


def buck2(*args, ok=True):
    """Runs buck2 with the args, saving its output under LOG_DIR. Fails the
    check if `ok` and buck2 fails."""
    global _run_count
    _run_count += 1
    os.makedirs(LOG_DIR, exist_ok=True)
    log = os.path.join(LOG_DIR, "{:02d}-{}.log".format(_run_count, args[0]))
    p = subprocess.run(["buck2", *args], capture_output=True, text=True)
    with open(log, "w") as f:
        f.write("$ buck2 " + " ".join(args) + "\n" + p.stdout + p.stderr)
    if ok and p.returncode != 0:
        raise CheckFailed("`buck2 {}` failed (see {}):\n{}".format(" ".join(args), log, tail(p.stderr)))
    return p


def tail(text, n=30):
    return "\n".join(text.splitlines()[-n:])


def build(*targets, mode=None, keep_going=False):
    args = ["build"] + (["-m", mode] if mode else []) + (["--keep-going"] if keep_going else []) + list(targets)
    return buck2(*args, ok=not keep_going)


IDENTITY = re.compile(r"^(\S+) \(cfg:[^)]*\) \((\S+)(?: (.+))?\)$")


def what_ran_entries():
    """The entries of `buck2 log what-ran` for the last build, as JSON."""
    out = buck2("log", "what-ran", "--format", "json").stdout
    return [json.loads(line) for line in out.splitlines() if line.startswith("{")]


def what_ran(entries=None):
    """The actions the last build ran (or those of the given what-ran
    entries), as (target, category, identifier, command) tuples: target as
    "c:c", without the cell. Not those that buck2 found up to date by their
    dep files (or in a cache), which what-ran lists too, nor the start of a
    persistent worker, which it lists under the action first sent to the
    worker."""
    actions = []
    for entry in (what_ran_entries() if entries is None else entries):
        m = IDENTITY.match(entry["identity"])
        executor = entry["reproducer"].get("executor", "")
        if not m or executor.endswith("Cache") or executor == "WorkerInit":
            continue
        target = m.group(1).split("//", 1)[1].lstrip(":")
        cmd = entry.get("reproducer", {}).get("details", {}).get("command", [])
        actions.append((target, m.group(2), m.group(3), cmd))
    return actions


def compiled_modules(actions):
    """The per-module compiles that ran, as "target-name:Module"."""
    return {target_name(t) + ":" + i for t, c, i, _ in actions if c.startswith("haskell_compile_module_")}


def target_name(target):
    return target.split(":")[-1]


def dep_file(target, category, identifier, mode=None):
    """The entries of an action's dep file (its tagged inputs that it read),
    by short name, and its untagged inputs, by short name."""
    args = ["audit", "dep-files"] + (["-m", mode] if mode else []) + ["root" + target, category, identifier]
    out = buck2(*args).stdout
    tagged, untagged = set(), set()
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        (untagged if parts[0] == "untagged" else tagged).add(short(parts[1]))
    return tagged, untagged


def raw_dep_file(package, name, node):
    """The entries of a per-module compile's dep file as its action wrote
    them, by short name."""
    paths = glob.glob("buck-out/v2/art/root/*/{}/__{}__/__action___*/per-module-shared/dep/{}.dep".format(package, name, node))
    if len(paths) != 1:
        raise CheckFailed("no single dep file of {}:{} {} (found {})".format(package, name, node, paths))
    with open(paths[0]) as f:
        return {short(line.strip()) for line in f if line.strip()}


# --- Naming buck-out paths ---------------------------------------------------

OWN = r"buck-out/v2/art/root/[0-9a-f]+/(?:[^ ]*/)?__([^/]+)__/"
SHORT_NAMES = [
    # A module's outputs: a:A.Mid.abi, cyc:Cyc.B.abi-boot.
    (OWN + r"per-module-[^/]+/out-[0-9]+/(.+)\.([a-z_]+(?:-boot)?)$", lambda m: "{}:{}.{}".format(m[1], m[2].replace("/", "."), m[3])),
    (OWN + r"per-module-[^/]+/out-[0-9]+$", lambda m: m[1] + ":out"),
    (OWN + r"per-module-[^/]+/th-shared-libs/(.+)$", lambda m: "{}:ldtree:{}".format(m[1], m[2])),
    (OWN + r"db-early-[^/]+(/.*)?$", lambda m: m[1] + ":early"),
    (OWN + r"db-[^/]+(/.*)?$", lambda m: m[1] + ":final"),
    (OWN + r"hi-[^/]+$", lambda m: m[1] + ":hi"),
    (OWN + r"lib-[^/]+/.*$", lambda m: m[1] + ":lib"),
    (r"third-party/haskell/ghc-[^/]+(/package\.conf\.d)?$", lambda m: "ghc:global"),
]


def short(path):
    for pattern, name in SHORT_NAMES:
        m = re.match(pattern, path)
        if m:
            return name(m)
    return path


# --- Reading a per-module compile's command line -----------------------------

def parse_compile(cmd):
    """The parts of a per-module compile's request (the worker's, or the
    compile script's arguments) that the rules decide: package dbs,
    LD_LIBRARY_PATH trees, interface dirs, the modules a splice may link
    past boot files."""
    args = cmd[cmd.index("--request"):]
    sep = args.index("--")
    script, rest = args[:sep], args[sep + 1:]
    session = rest[:rest.index("--")]
    ldtree, hidirs, links = set(), set(), set()
    for n, a in enumerate(script):
        if a == "--ldtree":
            ldtree = {short(p) for p in script[n + 1].split(":")}
        elif a.startswith("--hidir="):
            hidirs.add(short(a[len("--hidir="):]))
        elif a.startswith("--link="):
            links.add(a[len("--link="):])
    dbs = {short(session[n + 1]) for n, a in enumerate(session) if a == "-package-db"}
    units = [session[n + 1] for n, a in enumerate(session) if a == "-this-unit-id"]
    return {"dbs": dbs, "ldtree": ldtree, "hidirs": hidirs, "links": links, "unit": units[-1] if units else None}


def find_compile(actions, target, module):
    for t, c, i, cmd in actions:
        if target_name(t) == target and c.startswith("haskell_compile_module_") and i == module:
            return parse_compile(cmd)
    raise CheckFailed("no compile of {}:{} in the build".format(target, module))


# --- Assertions ----------------------------------------------------------------

def expect_set(what, actual, expected):
    actual, expected = set(actual), set(expected)
    if actual != expected:
        raise CheckFailed("{}:\n  missing:    {}\n  unexpected: {}\n  (actual:    {})".format(
            what, sorted(expected - actual) or "-", sorted(actual - expected) or "-", sorted(actual)))


def expect(what, cond):
    if not cond:
        raise CheckFailed(what)


# --- Editing sources ------------------------------------------------------------

def append(path, text):
    with open(path, "a") as f:
        f.write(text)


def replace(path, old, new):
    with open(path) as f:
        s = f.read()
    expect("{} contains {!r}".format(path, old), old in s)
    with open(path, "w") as f:
        f.write(s.replace(old, new))


# --- The checks -------------------------------------------------------------------

class State:
    def __init__(self, eli, worker):
        self.eli = eli
        self.worker = worker
        self.targets = MAIN_TARGETS + (ELI_TARGETS if eli else [])
        self.entries = None
        self.actions = None


def check_clean_build(st):
    """The fixtures build from clean, compiling every module. The build
    itself guards against some regressions: rp's flat Lib taken for mk's
    Q.Lib (whose interface path ends the same way); tie's Template Haskell
    modules, each behind the other's boot file, waiting on each other; the
    hs-boot pair of cyc; B.Lit, a literate source."""
    buck2("clean")
    build(*st.targets)
    st.entries = what_ran_entries()
    st.actions = what_ran(st.entries)
    expect_set("modules compiled from clean", compiled_modules(st.actions),
               {"a:A.Base", "a:A.Mid", "a:A.Unused", "b:B.M", "th:TH.Gen", "c:C.Splice", "c:C.Plain", "c:C.Ann",
                "d:D.Splice", "cyc:Cyc.A", "cyc:Cyc.B", "cyc:Cyc.B-boot", "cyc:Cyc.AS", "rx:R.R", "ux:U.M", "main:Main", "main:Main.Util", "show:Main",
                "tie:Tie.A", "tie:Tie.B", "tie:Tie.I", "tie:Tie.K", "tie:Tie.I-boot", "tie:Tie.K-boot",
                "tie:Tie.AZ", "tie:Tie.V", "tie:Tie.W", "tie:Tie.W-boot", "rp:Lib", "rp:User", "b:B.Lit", "b:B.UsesLit", "b:B.Safe"}
               | ({"e:E.Gen", "e:E.Lib", "elr:ER.M"} if st.eli else set()))


def check_workers(st):
    """The module compiles of the clean build ran in the shared persistent
    worker when the project has one (run.sh with GHC_WORKER), and as
    processes of their own otherwise. With the worker, those whose splices
    load libraries built by buck2, which must be on LD_LIBRARY_PATH, ran as
    processes of their own (see Note [The persistent worker]). Splices that
    run only GHC's own, prebuilt, packages (d's, cyc's, tie's) need none.
    So do a target's build tools, if they are all on the worker's PATH
    (per_module_worker_build_tools, which the project's buckconfig sets to
    //bt:bt-shared): //bt:shared's module compiles in the worker, and
    //bt:own's without it."""
    def executors(entries):
        compiles = [e for e in entries if "haskell_compile_module_" in e["identity"]]
        return [(module_of(e), e["reproducer"].get("executor", "")) for e in compiles], [e for e in compiles if e["reproducer"].get("executor") == "WorkerInit"]

    ran, inits = executors(st.entries)
    build("//bt:shared", "//bt:own")
    bt, _ = executors(what_ran_entries())
    bt = set(bt) - {(m, "WorkerInit") for m, _ in bt}
    if not st.worker:
        expect_set("how the module compiles ran", {x for _, x in ran} - {"WorkerInit"}, {"Local"})
        expect_set("how //bt's module compiles ran", bt, {("shared:BT.Shared", "Local"), ("own:BT.Own", "Local")})
        return
    expect_set("the modules compiled without the worker", {m for m, x in ran if x == "Local"}, NO_WORKER | (NO_WORKER_ELI if st.eli else set()))
    expect_set("how the other module compiles ran", {x for _, x in ran} - {"Local", "WorkerInit"}, {"Worker"})
    expect("one worker (started: {})".format(len(inits)), len(inits) == 1)
    expect_set("how //bt's module compiles ran", bt, {("shared:BT.Shared", "Worker"), ("own:BT.Own", "Local")})
    # A target naming its worker (//wk:w, which runs //wk:ghc-worker).
    build("//wk:wk")
    entries = what_ran_entries()
    ran, _ = executors(entries)
    expect_set("how //wk:wk's module compiles ran", {x for _, x in ran} - {"WorkerInit"}, {"Worker"})
    named = [e for e in entries if e["reproducer"].get("executor") == "WorkerInit" and any(a == "wk/ghc-worker" or a.endswith("/wk/ghc-worker") for a in e["reproducer"]["details"].get("command", []))]
    expect("//wk:wk's compiles started the worker it names (//wk:w)", len(named) == 1)


def module_of(entry):
    """A what-ran entry's module, as "target-name:Module"."""
    m = IDENTITY.match(entry["identity"])
    return target_name(m.group(1)) + ":" + m.group(3)


def check_early_db_conf(st):
    """a's early package db names no library, and its import dir is the
    per-module output dir; its final db names the library."""
    out = buck2("aquery", "all_actions(root//a:a)", "--output-all-attributes").stdout
    confs = {v.get("identifier"): v.get("contents", "") for v in json.loads(out).values() if v.get("kind") == "write"}
    expect("aquery shows the write of pkg-early-shared.conf (got {})".format(sorted(confs)), "pkg-early-shared.conf" in confs)
    early = parse_conf(confs["pkg-early-shared.conf"])
    final = parse_conf(confs["pkg-shared.conf"])
    library_fields = {"hs-libraries", "extra-libraries", "library-dirs", "dynamic-library-dirs"}
    expect_set("library fields of a's early db conf", set(early) & library_fields, set())
    dirs = early.get("import-dirs", [])
    expect("a's early db conf has one import-dir, the modules' output directory (got {})".format(dirs),
           len(dirs) == 1 and re.fullmatch(r'"\$\{pkgroot\}/per-module-shared/out-[0-9]+"', dirs[0]) is not None)
    expect("a's final db conf names its library (fields: {})".format(sorted(final)), "extra-libraries" in final)


def parse_conf(text):
    fields, key = {}, None
    for line in text.splitlines():
        m = re.match(r"^([\w-]+):\s*(.*)$", line)
        if m:
            key = m.group(1)
            fields[key] = [v.strip() for v in m.group(2).split(",") if v.strip()]
    return fields


def check_cross_package_dep_file(st):
    """B.M's dep file lists only the a interfaces GHC recorded a usage of:
    A.Mid, which it imports (A.Base reaches it through A.Mid's ABI hash),
    nothing of A.Unused; its closure, which it may read, is A.Mid and
    A.Base."""
    tagged, untagged = dep_file("//b:b", "haskell_compile_module_shared", "B.M")
    expect_set("B.M's dep file", tagged, {"a:A.Mid.abi"})
    expect_set("a's package dbs among B.M's untagged inputs", {u for u in untagged if u.startswith("a:")}, {"a:early"})
    closures = find_output("b", "per-module-shared/closures.json")
    with open(closures) as f:
        expect_set("B.M's closure (b's closures.json)", {"{}:{}".format(p, m) for p, m in json.load(f)["B.M"]},
                   {"root-a-a:A.Mid", "root-a-a:A.Base"})


def find_output(target, rel):
    for root, _, files in os.walk("buck-out/v2/art/root"):
        path = os.path.join(root, os.path.basename(rel))
        if root.endswith(os.path.join("__{}__".format(target), os.path.dirname(rel))) and os.path.exists(path):
            return path
    raise CheckFailed("no {} of {} in buck-out".format(rel, target))


def check_plain_module_uses_early_dbs(st):
    """A module without Template Haskell compiles against its dependencies'
    early dbs, with no library on its LD_LIBRARY_PATH."""
    for target, module, deps in [("b", "B.M", ["a"]), ("c", "C.Plain", ["a", "th"])]:
        c = find_compile(st.actions, target, module)
        expect_set("{}'s package dbs".format(module), c["dbs"], {d + ":early" for d in deps} | {"ghc:global"})
        expect_set("{}'s LD_LIBRARY_PATH trees".format(module), c["ldtree"], set())
        expect_set("{}'s interface dirs".format(module), c["hidirs"], {d + ":out" for d in deps})


def check_binary_unit(st):
    """A per-module binary's modules are in a unit named after the target,
    as a library's are, not GHC's default `main`, which every binary would
    share."""
    c = find_compile(st.actions, "main", "Main")
    expect("main's Main is in unit root-main-main (got {})".format(c["unit"]), c["unit"] == "root-main-main")


def check_th_modules_dbs(st):
    """Template Haskell modules: with th_build_depends = [":th"], C.Splice
    and C.Ann (an ANN pragma) compile against th's final db and a's early
    one, with th's libraries on LD_LIBRARY_PATH; with th_build_depends =
    [], D.Splice only against early dbs, with the libraries of GHC's own
    packages alone."""
    for module in ["C.Splice", "C.Ann"]:
        c = find_compile(st.actions, "c", module)
        expect_set("{}'s package dbs".format(module), c["dbs"], {"a:early", "th:final", "ghc:global"})
        expect_set("{}'s LD_LIBRARY_PATH trees".format(module), c["ldtree"], {"c:ldtree:_", "c:ldtree:root-th-th"})
        expect_set("{}'s interface dirs".format(module), c["hidirs"], {"a:out", "th:hi"})
    c = find_compile(st.actions, "d", "D.Splice")
    expect_set("D.Splice's package dbs", c["dbs"], {"a:early", "th:early", "ghc:global"})
    expect_set("D.Splice's LD_LIBRARY_PATH trees", c["ldtree"], {"d:ldtree:_"})


def check_explicit_level_imports(st):
    """GHC 9.14: with th_build_depends = [], E.Gen (`import splice TH.Gen`)
    compiles against th's final db, E.Lib (`import splice
    Language.Haskell.TH`) against early dbs only."""
    c = find_compile(st.actions, "e", "E.Gen")
    expect_set("E.Gen's package dbs", c["dbs"], {"a:early", "th:final", "ghc:global"})
    expect_set("E.Gen's LD_LIBRARY_PATH trees", c["ldtree"], {"e:ldtree:_", "e:ldtree:root-th-th"})
    c = find_compile(st.actions, "e", "E.Lib")
    expect_set("E.Lib's package dbs", c["dbs"], {"a:early", "th:early", "ghc:global"})
    expect_set("E.Lib's LD_LIBRARY_PATH trees", c["ldtree"], {"e:ldtree:_"})


def check_boot(st):
    """The hs-boot pair: the boot file has its own action, which Cyc.A (its
    {-# SOURCE #-} importer) and Cyc.B (checked against it) depend on; its
    own dep file doesn't list its own output, and Cyc.A's lists the boot
    file's, even once Cyc.B's own is there too. Cyc.AS, whose splice may link
    Cyc.B past its boot file, names it for the worker; Cyc.B, which runs no
    splice, names nothing."""
    tagged, _ = dep_file("//cyc:cyc", "haskell_compile_module_shared", "Cyc.B-boot")
    expect_set("Cyc.B-boot's dep file", tagged, set())
    tagged, _ = dep_file("//cyc:cyc", "haskell_compile_module_shared", "Cyc.A")
    expect_set("Cyc.A's dep file", tagged, {"cyc:Cyc.B.abi-boot"})
    tagged, _ = dep_file("//cyc:cyc", "haskell_compile_module_shared", "Cyc.B")
    expect_set("Cyc.B's dep file", tagged, {"cyc:Cyc.A.abi", "cyc:Cyc.B.abi-boot"})
    # The clean build's compiles (st.actions):
    expect_set("the modules Cyc.AS links past boot files", find_compile(st.actions, "cyc", "Cyc.AS")["links"], {"Cyc.B"})
    expect_set("the modules Cyc.B links past boot files", find_compile(st.actions, "cyc", "Cyc.B")["links"], set())
    # Compiled again, with Cyc.B's whole interface there now too: still the
    # boot file's, which is what Cyc.A imports. (The file itself: buck2
    # leaves out of its record entries that aren't inputs of the action, as
    # Cyc.B.abi isn't.)
    append("cyc/Cyc/A.hs", "\n-- an edit\n")
    build("//cyc:cyc")
    expect_set("Cyc.A's dep file, compiled again", raw_dep_file("cyc", "cyc", "Cyc.A"), {"cyc:Cyc.B.abi-boot"})


def check_tie(st):
    """Two modules that run Template Haskell, each behind a boot file below
    the other, would each wait for the other: the first by name doesn't
    wait for the other, which names it to link past its boot file. Tie.AZ,
    only behind that cycle, keeps its waits."""
    expect_set("the modules Tie.I links past boot files", find_compile(st.actions, "tie", "Tie.I")["links"], set())
    expect_set("the modules Tie.K links past boot files", find_compile(st.actions, "tie", "Tie.K")["links"], {"Tie.I"})
    expect_set("the modules Tie.AZ, only behind the cycle, links past boot files",
               find_compile(st.actions, "tie", "Tie.AZ")["links"], {"Tie.I", "Tie.K", "Tie.W"})


def index_files(target, *config):
    """The names of the .hie files in the target's index (HaskellIndexInfo)."""
    path = buck2("bxl", *config, "//index.bxl:index", "--", "--target", target).stdout.strip().splitlines()[-1]
    hie = set()
    for root, _, files in os.walk(path, followlinks=True):
        hie |= {f for f in files if f.endswith(".hie")}
    return hie


def check_index(st):
    """A library built with -fwrite-ide-info has an index (HaskellIndexInfo)
    with each module's .hie file."""
    expect_set("the .hie files of //idx:idx's index", index_files("//idx:idx"), {"A.hie", "B.hie"})


def check_native_library_change(st):
    """A change to a C library that a splice runs (U.V's, through //ffi:ffi)
    compiles the module again, and the splice runs the new code."""
    expect_output("//ffiuse:show", "before the edit to //cl:cl", "7")
    replace("cl/cl.c", "return 7", "return 8")
    build("//ffiuse:ffiuse")
    ran = compiled_modules(what_ran())
    expect("U.V compiled after the edit to //cl:cl (ran: {})".format(sorted(ran)), "ffiuse:U.V" in ran)
    expect_output("//ffiuse:show", "after the edit to //cl:cl", "8")


def check_module_moved(st):
    """A module moved from a target to its dependency (MV.X, from //mv:hi
    to //mv:lo): its importer compiles against the dependency's, not the
    interface its old target left behind."""
    expect_output("//mv:main", "before MV.X moves", "12")
    replace("mv/BUCK.fixture", '''srcs = {"MV.Lo": "MV/Lo.hs"}''', '''srcs = {"MV.Lo": "MV/Lo.hs", "MV.X": "MV/X.hs"}''')
    replace("mv/BUCK.fixture", '''"MV.X": "MV/X.hs", "MV.Y": "MV/Y.hs"''', '''"MV.Y": "MV/Y.hs"''')
    replace("mv/MV/X.hs", "x = 2", "x = 3")
    expect_output("//mv:main", "after MV.X moves", "13")


def check_header_change(st):
    """An edit to a header in a target's srcs, which a module #includes,
    recompiles the module."""
    build("//hdr:hdr")
    replace("hdr/Hdr/value.h", "VALUE 1", "VALUE 2")
    build("//hdr:hdr")
    expect_set("modules compiled after an edit to Hdr/value.h", compiled_modules(what_ran()), {"hdr:Hdr.M"})


def check_toolchain_th(st):
    """With Template Haskell enabled by the toolchain's flags, a module
    without a LANGUAGE pragma compiles as one that runs Template Haskell.
    The build is the check: TF.M's splice runs A.Base's code, which it
    can't unless it has a's final db and library. (At the end: it changes
    the configuration.)"""
    buck2("build", "-c", "haskell.compiler_flags=-XTemplateHaskell", "//tf:tf")


def check_toolchain_index(st):
    """With -fwrite-ide-info in the toolchain's flags, a library has an
    index with each module's .hie file. (At the end: it changes the
    configuration.)"""
    expect_set("the .hie files of //a:a's index, with the toolchain's -fwrite-ide-info",
               index_files("//a:a", "-c", "haskell.compiler_flags=-fwrite-ide-info"),
               {"Base.hie", "Mid.hie", "Unused.hie"})


def rebuild(st):
    """Builds the fixtures again: the modules compiled."""
    build(*st.targets)
    return compiled_modules(what_ran())


def check_cutoff_comment(st):
    """A comment-only edit to A.Base recompiles A.Base alone."""
    append("a/A/Base.hs", "\n-- a comment\n")
    ran = rebuild(st)
    expect_set("modules compiled after a comment-only edit to A.Base", ran, {"a:A.Base"})


def check_cutoff_abi_base(st):
    """A new export of A.Base recompiles the modules whose dep files list
    A.Base's ABI, within and across packages, ux's U.M among them, which
    imports A.Base through rx's re-export of it; A.Mid's ABI is unchanged,
    so nothing that imports A.Mid alone, and nothing of A.Unused."""
    replace("a/A/Base.hs", "module A.Base (base) where", "module A.Base (base, base2) where")
    append("a/A/Base.hs", "\nbase2 :: Int\nbase2 = 2\n")
    ran = rebuild(st)
    expect_set("modules compiled after a new export of A.Base", ran,
               {"a:A.Base", "a:A.Mid", "c:C.Splice", "c:C.Ann", "d:D.Splice", "ux:U.M"}
               | ({"e:E.Gen", "e:E.Lib", "elr:ER.M"} if st.eli else set()))


def check_cutoff_abi_mid(st):
    """A new export of A.Mid recompiles its importers in other packages
    (B.M, C.Plain, and B.Safe, whose import is a safe one), not B.M's
    importers in main, whose ABI is unchanged;
    and, with GHC 9.14, ER.M, whose splice runs a's code, so whose compile
    has a's library, linked again, as an input."""
    replace("a/A/Mid.hs", "module A.Mid (mid) where", "module A.Mid (mid, mid2) where")
    append("a/A/Mid.hs", "\nmid2 :: Int\nmid2 = 2\n")
    expect_set("modules compiled after a new export of A.Mid", rebuild(st),
               {"a:A.Mid", "b:B.M", "b:B.Safe", "c:C.Plain"} | ({"elr:ER.M"} if st.eli else set()))


def check_th_body_change(st):
    """A change to the body of TH.Gen's gen (its type the same, so its ABI)
    recompiles the modules of c that load th's library, which is a plain
    input of theirs (GHC records no use of it): C.Splice, whose splice runs
    gen, and C.Ann, whose ANN pragma runs the interpreter too; not C.Plain.
    //c:show then prints the new value."""
    expect_output("//c:show", "before the edit to TH.Gen", "43")
    replace("th/TH/Gen.hs", "integerL 42", "integerL 43")
    ran = rebuild(st)
    expect("TH.Gen recompiled after its edit (ran: {})".format(sorted(ran)), "th:TH.Gen" in ran)
    expect_output("//c:show", "after the edit to TH.Gen", "44")
    expect_set("modules of c compiled after a body-only edit to TH.Gen",
               {m for m in ran if m.startswith("c:")}, {"c:C.Splice", "c:C.Ann"})


def expect_output(target, when, value):
    out = buck2("run", target).stdout.strip()
    expect("{} should print {} {}; it printed {}".format(target, value, when, out), out == value)


def check_unrelated_modules(st):
    """W.M imports S.Ok only, so its compile doesn't wait for S.Broken,
    which fails: with --keep-going, W.M is compiled."""
    build("//waits:w", keep_going=True)
    ran = compiled_modules(what_ran())
    expect("S.Broken was attempted (ran: {})".format(sorted(ran)), "s:S.Broken" in ran)
    expect("W.M compiled although S.Broken, which it doesn't import, failed (ran: {})".format(sorted(ran)),
           "w:W.M" in ran)


def check_opt_static(st):
    """opt mode (static, -dynamic-too): B.M's dep file lists A.Mid, as in
    dev mode."""
    build("//main:main", mode="opt")
    tagged, _ = dep_file("//b:b", "haskell_compile_module_static", "B.M", mode="opt")
    expect_set("B.M's dep file in opt mode", tagged, {"a:A.Mid.abi"})


def check_opt_shared_consumer(st):
    """opt mode: a binary linked shared compiles against b's "shared"
    package, which comes from b's -dynamic-too compile; Main's dep file
    lists B.M, which it imports."""
    build("//main:main-shared", mode="opt")
    tagged, _ = dep_file("//main:main-shared", "haskell_compile_module_shared", "Main", mode="opt")
    expect_set("b's files in Main's dep file (main-shared, opt mode)",
               {t for t in tagged if t.startswith("b:")}, {"b:B.M.abi"})


CHECKS = [
    check_clean_build,
    check_workers,
    check_early_db_conf,
    check_cross_package_dep_file,
    check_plain_module_uses_early_dbs,
    check_binary_unit,
    check_th_modules_dbs,
    check_explicit_level_imports,
    check_boot,
    check_tie,
    check_index,
    check_native_library_change,
    check_cutoff_comment,
    check_cutoff_abi_base,
    check_cutoff_abi_mid,
    check_th_body_change,
    check_unrelated_modules,
    check_opt_static,
    check_opt_shared_consumer,
    check_module_moved,
    check_header_change,
    check_toolchain_th,
    check_toolchain_index,
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ghc-version", required=True)
    ap.add_argument("--only", action="append", help="run only this check (by name, without check_); repeatable")
    ap.add_argument("--worker", action="store_true", help="the project compiles in a persistent worker")
    args = ap.parse_args()
    unknown = set(args.only or []) - {check.__name__[len("check_"):] for check in CHECKS}
    if unknown:
        ap.error("no such check: " + " ".join(sorted(unknown)))
    major, minor = (int(x) for x in args.ghc_version.split(".")[:2])
    st = State(eli=(major, minor) >= (9, 14), worker=args.worker)
    failed = []
    for check in CHECKS:
        name = check.__name__[len("check_"):]
        if args.only and name not in args.only and check is not check_clean_build:
            continue
        if check is check_explicit_level_imports and not st.eli:
            print("SKIP   {} (GHC {})".format(name, args.ghc_version))
            continue
        start = time.time()
        try:
            check(st)
            error = None
        except CheckFailed as e:
            error = str(e)
        except Exception:
            # Most likely a change to buck2's logs or the rules' command
            # lines that the harness can't read.
            error = traceback.format_exc()
        took = "{:.0f}s".format(time.time() - start)
        if error is None:
            print("PASS   {} ({})".format(name, took))
        else:
            failed.append(name)
            print("FAIL   {} ({}): {}\n       {}".format(name, took,
                                                   check.__doc__.split("\n")[0], error.replace("\n", "\n       ")))
        sys.stdout.flush()
        if check is check_clean_build and error is not None:
            print("(the other checks need the clean build)")
            break
    print("{} failed: {}".format(len(failed), " ".join(failed)) if failed else "all passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
