#!/usr/bin/env python3
"""Fails when classify_changes.sh would skip a suite for a change to a file the suite reads.

classify_changes.sh skips a class of tests when no input of it changed. That is sound only if the
table lists every input, so this finds the inputs mechanically, from the code that reads them
(decision O14), and fails when the table does not select the suite for one.

  1. The roots: the scripts build.zig's steps run (tests/api/api.py, ../errors/wire.py, ...), each
     tagged with its step's class (test:api is `api`); the scripts ci/job.sh's check_code,
     check_scripts and check_packages run (tagged checks, ci_scripts, packaging); and the scripts
     CI runs without either (tests/packaging, tests/macos, ci/ci_test.sh).
  2. A root's reads. Python: its syntax tree, for an `import` of a module in its own directory or
     one it put on `sys.path`, and every path it builds (`os.path.join(HERE, "..", "demo", ...)`,
     `Path(__file__).parent / "x"`, f-strings and `+`) or names ("docs/API.md", "VERSION") that is
     a file of the repository. Shell: the literal repository paths in it ("docs/ERRORS.md",
     ".github/scripts/x.sh") and `$here/x` or `$root/x` of the directory the script found for
     itself. A file reached is read in turn; the tags travel along.
  3. For every file reached, classify_changes.sh must select every tag it carries.

What it cannot resolve fails closed. A path built from parts it cannot evaluate, that holds a
repository directory or file name (f"{tmp}/docs/x", a Zig `readFileAlloc` of a variable inside a
test), is an error unless UNANALYSED names it, with the repository paths it stands for (those are
checked like any other read; an empty list says it reads nothing of the repository). Entries are
reviewed; one that matches nothing any more is an error too.

It also checks that the unit tests' reads of files outside src/ are selected for `unit`; that
ci.yml's `changes` job outputs each class as its own value, every step of a job that waits for
`changes` is gated, in the form `!= 'false'` that runs when `changes` fails, on a class its job
depends on (JOB_CLASSES), and the classifier makes each class true for `all` and `binary`; and that
every workflow that calls another grants it the permissions its jobs ask for (a called workflow
cannot hold more than its caller grants, and GitHub refuses the file when it does).

  classify_guard.py [--root DIR]      the repository, by default the one this file is in
"""
import ast
import glob
import os
import posixpath
import re
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None

HERE = os.path.dirname(os.path.abspath(__file__))
CLASSIFIER = os.path.join(HERE, "classify_changes.sh")

# build.zig's steps that run scripts, and the class that gates each (ci/job.sh's jobs).
STEP_CLASS = {
    "test_integration": "integration",
    "test_api": "api",
    "test_views": "views",
    "test_release": "release",
    "test_demo": "demo",
    "demo_r4": "demo_r4",
    "demo_r5": "demo_r5",
}
# Scripts that CI runs without build.zig, and the class that gates them.
EXTRA_ROOTS = {
    "tests/packaging": "packaging",
    "tests/macos": "macos",
    "ci/ci_test.sh": "ci_scripts",
}
# ci/job.sh's functions: the scripts each runs are roots of the class its ci.yml step is gated on.
JOB_FUNCTIONS = {"check_code": "checks", "check_scripts": "ci_scripts", "check_packages": "packaging"}

# The classes each ci.yml job's steps may be gated on, and at least one step must be gated on the
# first of them. A job not in this table that waits for `changes` is an error: add it here.
JOB_CLASSES = {
    "checks": ["checks", "ci_scripts", "packaging"],
    "ci-scripts": ["ci_scripts", "any"],
    "integration": ["integration"],
    "api": ["api"],
    "releases": ["release"],
    "targets": ["targets"],
    "macos-arm64": ["macos"],
    "macos-x86_64": ["macos"],
    "mac-keychain": ["mac_keychain"],
    "unit": ["unit"],
    "fuzz": ["fuzz"],
    "demo": ["demo"],
    "demo_r5": ["demo_r5"],
    "demo_r4": ["demo_r4"],
    "vopr": ["vopr", "any"],
    "vopr_main": ["vopr"],
}

# Paths the guard cannot evaluate, reviewed by hand, each with the repository paths (globs) it
# stands for. Key: (file, the constant or Zig argument). Every one of these is a path built or
# held where static analysis cannot see its value; what it reads is what a reviewer found.
UNANALYSED = {
    # Shell commands and messages that name checkouts and tools, not repository files the test reads.
    ("ops/jepsen/jepsen_report.py", " && ./zig/zig build -Drelease"): [],
    ("ops/sim-fleet/sim_fleet.py", "./zig/zig build -Drelease fuzz -- "): [],
    ("ops/sim-fleet/sim_fleet.py", "./zig/zig build -Drelease vopr -Dvopr-state-machine="): [],
    ("ops/sim-fleet/sim_fleet.py", "/src/"): [],  # the source root of a crash trace's frames
    ("ops/sim-fleet/sim_fleet.py", "src/"): [],
    (".github/scripts/sbom.py", " .github/scripts/sbom.py at "): [],  # the SBOM's own description
    (".github/scripts/test_release_check.py", "docs/a.zig"): [],  # files of a scratch repository
    (".github/scripts/test_release_check.py", "src/a.zig"): [],
    ("tests/api/docs_routes.py", "docs/API.md has a section for %s, which the gateway does not serve"): [],
    ("tests/api/docs_routes.py", "docs/API.md has no section for %s, which nerva view serves"): [],
    ("tests/api/docs_routes.py", "docs/API.md has no section for %s, which the gateway serves"): [],
    # Files of the repository a test builds a path to, in a scratch tree or from its checkout.
    (".github/scripts/sbom.py", "UPSTREAM.md"): ["UPSTREAM.md"],
    (".github/scripts/sbom.py", "build.zig"): ["build.zig"],
    (".github/scripts/test_site_build.py", ".github/scripts"): [".github/scripts/site_*"],
    (".github/scripts/test_site_build.py", ".github/scripts/site_check.mjs"): [".github/scripts/site_check.mjs"],
    (".github/scripts/test_site_build.py", "/.github/scripts/site_build.sh' ] || exit 22\ncp '"):
        [".github/scripts/site_build.sh"],
    (".github/scripts/test_release_finish.py", "packaging/keys"): ["packaging/keys/*"],
    (".github/scripts/test_release_finish.py", "packaging/keys/nerva-release.asc"):
        ["packaging/keys/nerva-release.asc"],
    ("tests/packaging/packages.py", "/VERSION"): ["VERSION"],
    ("tests/packaging/packages.py", "/packaging/linux/"): ["packaging/linux/*"],
    ("tests/packaging/packages.py", "/packaging/linux/package-setup.sh"): ["packaging/linux/package-setup.sh"],
    ("tests/packaging/packages.py", "/packaging/linux:/src:ro"): ["packaging/linux/*"],
    # A Zig test that reads the file it is in, through a path joined from @src().file.
    ("src/stdx/prng.zig", "path"): ["src/stdx/prng.zig"],
}

# Literals that name a repository file but are not a read of it: a fixture in a scratch directory,
# an argument to the classifier's own table test, or text in a message. Key: (file, the path), value:
# why. Reviewed by hand; one that matches nothing any more is an error.
NOT_READS = {
    (".github/scripts/test_release_check.py", "CHANGELOG.md"): "written to a scratch directory",
    (".github/scripts/test_release_finish.py", "README.md"): "a file of a scratch tree",
    (".github/scripts/test_site_build.py", "README.md"): "a file of a scratch tree",
    ("packaging/linux/install.sh", "docs/QUICKSTART.md"): "named in messages the installer prints",
    (".github/scripts/test_site_build.py", "CLAUDE.md"): "a name in a list of files the site build must not copy",
    ("ops/jepsen/test_jepsen_report.py", "README.md"): "a README of a scratch tree",
    (".github/scripts/docs_only_test.sh", "docs/briefs/r5.md"): "a name handed to docs_only.sh, not read",
    (".github/scripts/release_finish.sh", "docs/releases/automation.md"): "text of a pull request body",
}

TOP_DIRS = ("docs", "src", "tests", ".github", "ci", "packaging", "scripts", "ops", "perf", "release", "demo", "zig")
FRAGMENT = re.compile(r"(?:^|/)(?:%s)/" % "|".join(re.escape(d) for d in TOP_DIRS))
# Files at the root that the classifier places by name: a path built to one of them is a read of it.
ROOT_FILES = ("VERSION", "UPSTREAM.md", "build.zig", "build.zig.zon", ".gitmodules", ".gitattributes")
# A call that only reports: the paths in its message are not reads.
REPORTING = ("print", "warn", "fail", "die", "error", "ci_error", "sys.stderr.write", "sys.exit", "exit",
             "logging.info", "logging.warning", "logging.error", "log")
READ_CALLS = ("readFileAlloc", "openFile", "openFileZ", "openDir", "readFile", "statFile")


class Guard:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.errors = []
        self.classes = {}
        self.unanalysed_seen = set()
        self.not_reads_seen = set()

    # --- the classifier -------------------------------------------------------------------

    def classify(self, path):
        if path not in self.classes:
            out = subprocess.run([CLASSIFIER], input=path + "\n", capture_output=True, text=True, check=True).stdout
            self.classes[path] = {k for k, v in (line.split("=") for line in out.split()) if v == "true"}
        return self.classes[path]

    def known_classes(self):
        out = subprocess.run([CLASSIFIER, "--all"], capture_output=True, text=True, check=True).stdout
        return [line.split("=")[0] for line in out.split()]

    # --- the repository -------------------------------------------------------------------

    def exists(self, rel):
        return os.path.exists(os.path.join(self.root, rel))

    def is_file(self, rel):
        return os.path.isfile(os.path.join(self.root, rel))

    def is_dir(self, rel):
        return os.path.isdir(os.path.join(self.root, rel))

    def rel(self, absolute):
        r = os.path.relpath(absolute, self.root)
        return None if r.startswith("..") else r

    def read(self, rel):
        return open(os.path.join(self.root, rel), encoding="utf-8").read()

    def files_under(self, rel, cap=20):
        """A sample of the files in a directory: one rule covers the files that share a prefix."""
        out = []
        for base, dirs, names in os.walk(os.path.join(self.root, rel)):
            dirs.sort()
            for n in sorted(names):
                out.append(self.rel(os.path.join(base, n)))
                if len(out) >= cap:
                    return out
        return out

    def allowed(self, path, text):
        """The paths a reviewed UNANALYSED entry says the construction `text` in `path` reads, or None."""
        key = (path, text)
        if key not in UNANALYSED:
            return None
        self.unanalysed_seen.add(key)
        out = []
        for pattern in UNANALYSED[key]:
            out.extend(sorted(self.rel(p) for p in glob.glob(os.path.join(self.root, pattern))))
        return out

    def path_like(self, text):
        return bool(FRAGMENT.search(text)) or any(
            text == n or text.endswith("/" + n) for n in ROOT_FILES)

    # --- roots ----------------------------------------------------------------------------

    def build_roots(self):
        """The scripts build.zig runs, each with its step's class."""
        text = self.read("build.zig")
        text = re.sub(r"//[^\n]*", "", text)
        roots = {}
        start = 0
        for m in re.finditer(r"steps\.(\w+)\.dependOn\(", text):
            segment, start = text[start:m.start()], m.end()
            bases = re.findall(r'"(tests/[\w/]+)/\{s\}"', segment)
            scripts = re.findall(r'"([\w./-]+\.py)"', segment)
            if not bases and not scripts:
                continue
            step = m.group(1)
            if step not in STEP_CLASS:
                self.errors.append(
                    "build.zig: step '%s' runs %s, and classify_guard.py does not know which class gates it: "
                    "add it to STEP_CLASS, and a rule to classify_changes.sh" % (step, scripts or bases))
                continue
            base = bases[-1] if bases else None
            for script in scripts:
                if script.startswith("tests/"):
                    path = script
                elif base:
                    path = posixpath.normpath(posixpath.join(base, script))
                else:
                    self.errors.append("build.zig: '%s' (step %s) has no tests/<dir>/{s} to be read against" % (script, step))
                    continue
                roots.setdefault(path, set()).add(STEP_CLASS[step])
        for path in roots:
            if not self.is_file(path):
                self.errors.append("build.zig runs %s, which is not in the repository" % path)
        for target, cls in EXTRA_ROOTS.items():
            if self.is_dir(target):
                for name in sorted(os.listdir(os.path.join(self.root, target))):
                    if name.endswith((".py", ".sh")):
                        roots.setdefault(target + "/" + name, set()).add(cls)
            elif self.is_file(target):
                roots.setdefault(target, set()).add(cls)
        if self.is_file("ci/job.sh"):
            job = self.read("ci/job.sh")
            for function, cls in JOB_FUNCTIONS.items():
                m = re.search(r"^%s\(\) \{\n(.*?)^\}" % function, job, re.M | re.S)
                if not m:
                    self.errors.append("ci/job.sh: no function %s; classify_guard.py reads the scripts it runs" % function)
                    continue
                body = "\n".join(l for l in m.group(1).splitlines() if not l.lstrip().startswith("#"))
                found = [t for t in re.findall(r"[A-Za-z0-9_./-]+\.(?:py|sh)\b", body) if self.is_file(t)]
                if not found:
                    self.errors.append("ci/job.sh: %s runs no script classify_guard.py can see" % function)
                for t in found:
                    roots.setdefault(t, set()).add(cls)
        return roots

    # --- reads of a Python file -----------------------------------------------------------

    def py_reads(self, rel):
        """The repository paths the Python file `rel` reads."""
        tree = ast.parse(self.read(rel), filename=rel)
        here = posixpath.dirname(rel)
        env = {}

        def concat(parts):
            if any(p is None or p[0] not in ("abs", "lit") for p in parts):
                return None
            kind, text = parts[0]
            for k, t in parts[1:]:
                if k != "lit":
                    return None
                text += t
            return (kind, posixpath.normpath(text) if kind == "abs" else text)

        def ev(node):
            """('abs', repo path), ('lit', text) or None."""
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                return ("lit", node.value)
            if isinstance(node, ast.JoinedStr):
                parts = []
                for v in node.values:
                    if isinstance(v, ast.Constant):
                        parts.append(("lit", v.value))
                    elif isinstance(v, ast.FormattedValue) and v.format_spec is None:
                        parts.append(ev(v.value))
                    else:
                        return None
                return concat(parts)
            if isinstance(node, ast.Name):
                if node.id == "__file__":
                    return ("abs", rel)
                return env.get(node.id)
            if isinstance(node, ast.Attribute):
                inner = ev(node.value)
                if node.attr == "parent" and inner and inner[0] == "abs":
                    return ("abs", posixpath.dirname(inner[1]))
                if node.attr == "parents" and inner and inner[0] == "abs":
                    return ("parents", inner[1])
                return None
            if isinstance(node, ast.Subscript):  # Path(__file__).parents[2]
                inner, index = ev(node.value), node.slice
                if inner and inner[0] == "parents" and isinstance(index, ast.Constant) and isinstance(index.value, int):
                    up = inner[1]
                    for _ in range(index.value + 1):
                        up = posixpath.dirname(up)
                    return ("abs", up or ".")
                return None
            if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
                return joined([ev(node.left), ev(node.right)])
            if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
                return concat([ev(node.left), ev(node.right)])
            if isinstance(node, ast.Call):
                name = dotted(node.func)
                args = [ev(a) for a in node.args]
                if name in ("os.path.dirname",) and args and args[0] and args[0][0] == "abs":
                    return ("abs", posixpath.dirname(args[0][1]))
                if name in ("os.path.abspath", "os.path.realpath", "os.path.normpath", "Path", "pathlib.Path",
                            "str") and args:
                    return args[0]
                if name in ("os.path.join", "posixpath.join"):
                    return joined(args)
                if isinstance(node.func, ast.Attribute) and node.func.attr in ("resolve", "absolute"):
                    return ev(node.func.value)
            return None

        def joined(parts):
            if not parts or any(p is None for p in parts):
                return None
            kind, path = parts[0]
            for k, p in parts[1:]:
                if k == "abs":
                    return None
                path = p if p.startswith("/") else posixpath.join(path, p)
            return (kind, posixpath.normpath(path))

        def dotted(node):
            if isinstance(node, ast.Attribute):
                inner = dotted(node.value)
                return inner + "." + node.attr if inner else None
            return node.id if isinstance(node, ast.Name) else None

        # Assignments (HERE = dirname(abspath(__file__))), in source order, in any scope.
        assigns = [n for n in ast.walk(tree)
                   if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name)]
        for node in sorted(assigns, key=lambda n: n.lineno):
            value = ev(node.value)
            if value:
                env[node.targets[0].id] = value

        def composite(node):
            if isinstance(node, (ast.JoinedStr, ast.BinOp)):
                return isinstance(node, ast.JoinedStr) or isinstance(node.op, (ast.Add, ast.Mod, ast.Div))
            if isinstance(node, ast.Call):
                return dotted(node.func) in ("os.path.join", "posixpath.join") or (
                    isinstance(node.func, ast.Attribute) and node.func.attr in ("format", "join"))
            return False

        # Text that only reports (a raise, an assert's message, print(...)) is not a path read.
        quiet = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Raise) or (isinstance(node, ast.Call) and dotted(node.func) in REPORTING) \
                    or isinstance(node, ast.Assert):
                quiet.update(id(n) for n in ast.walk(node))
        files, dirs, unresolved = set(), set(), set()
        for node in ast.walk(tree):
            value = None
            if isinstance(node, (ast.Call, ast.BinOp, ast.Attribute, ast.Subscript, ast.JoinedStr)):
                value = ev(node)
            elif isinstance(node, ast.Constant) and isinstance(node.value, str):
                value = ("lit", node.value)
            if composite(node) and value is None and id(node) not in quiet:
                for sub in ast.walk(node):
                    if isinstance(sub, ast.Constant) and isinstance(sub.value, str) and self.path_like(sub.value):
                        unresolved.add(sub.value)
            if not value:
                continue
            kind, path = value
            if kind == "parents":
                continue
            if kind == "abs":
                absolute = path
            elif not path.startswith("/") and "\n" not in path and len(path) < 200:
                absolute = posixpath.normpath(path)
            else:
                continue
            if absolute.startswith("..") or absolute in (rel, "."):
                continue
            if (rel, absolute) in NOT_READS:
                self.not_reads_seen.add((rel, absolute))
            elif self.is_file(absolute):
                files.add(absolute)
            elif self.is_dir(absolute) and kind == "abs" and absolute != here:
                dirs.add(absolute)
        # An `import x` finds x.py beside the script, or in a directory put on sys.path.
        for node in ast.walk(tree):
            names = []
            if isinstance(node, ast.Import):
                names = [a.name.split(".")[0] for a in node.names]
            elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
                names = [node.module.split(".")[0]]
            for name in names:
                for directory in [here] + sorted(dirs):
                    candidate = posixpath.join(directory, name + ".py")
                    if self.is_file(candidate) and candidate != rel:
                        files.add(candidate)
        for text in sorted(unresolved):
            self.unresolved(rel, text, files)
        return files

    def unresolved(self, rel, text, files):
        """A path-like construction the guard cannot evaluate: reviewed, or an error."""
        stands_for = self.allowed(rel, text)
        if stands_for is None:
            self.errors.append(
                "%s builds a path it cannot evaluate from %r: it may read a repository file the classifier does "
                "not place. Rewrite it so its value is visible (a literal or os.path.join of __file__), or add "
                "(%r, %r) to UNANALYSED with the paths it reads" % (rel, text, rel, text))
        else:
            files.update(stands_for)

    # --- reads of a shell script ----------------------------------------------------------

    def sh_reads(self, rel):
        """Literal repository paths in a shell script, and `$here/x` of the directory it found for itself."""
        text = "\n".join(l for l in self.read(rel).splitlines() if not l.lstrip().startswith("#"))
        here = posixpath.dirname(rel)
        files = set()

        def add(path):
            path = posixpath.normpath(path)
            if path.startswith("..") or path == rel:
                return
            if (rel, path) in NOT_READS:
                self.not_reads_seen.add((rel, path))
            elif self.is_file(path):
                files.add(path)

        for m in re.finditer(r"(?:%s)/[A-Za-z0-9_./*-]*[A-Za-z0-9_*]" % "|".join(re.escape(d) for d in TOP_DIRS), text):
            # A path of the repository stands alone or after `./`, not after `$tmp/` or inside a word.
            start = m.start() - 2 if text[max(0, m.start() - 2):m.start()] == "./" else m.start()
            if start > 0 and re.match(r"[\w$}/.-]", text[start - 1]):
                continue
            pattern = m.group(0)
            if "*" in pattern:
                for p in glob.glob(os.path.join(self.root, pattern)):
                    add(self.rel(p))
            else:
                add(pattern)
        # Directories this script finds for itself: here=$(cd "$(dirname "$0")" && pwd), root=$(cd "$here/.." ...).
        dirs = {}
        for m in re.finditer(r'^\s*(\w+)=.*\bdirname\b[^\n]*?(?:\$0|BASH_SOURCE)[^\n]*?\)"?((?:/\.\.)*)', text, re.M):
            dirs[m.group(1)] = posixpath.normpath(posixpath.join(here, "." + m.group(2)))
        for m in re.finditer(r'^\s*(\w+)=.*?\bcd "?\$\{?(\w+)\}?((?:/\.\.)+)', text, re.M):
            if m.group(2) in dirs:
                dirs[m.group(1)] = posixpath.normpath(posixpath.join(dirs[m.group(2)], "." + m.group(3)))
        for m in re.finditer(r"\$\{?(\w+)\}?/([A-Za-z0-9_./-]*[A-Za-z0-9_])", text):
            if m.group(1) in dirs:
                add(posixpath.join(dirs[m.group(1)], m.group(2)))
        return files

    # --- reads of a Zig file --------------------------------------------------------------

    def zig_blocks(self, text):
        """The `test` blocks of a Zig source, as (start, end) offsets."""
        clean = re.sub(r"\\\\[^\n]*", lambda m: " " * len(m.group(0)), text)
        clean = re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), clean)
        clean = re.sub(r'"(?:[^"\\\n]|\\.)*"', lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', clean)
        blocks = []
        for m in re.finditer(r'^test\b[^{\n]*\{', clean, re.M):
            depth, i = 1, m.end()
            while i < len(clean) and depth:
                depth += (clean[i] == "{") - (clean[i] == "}")
                i += 1
            blocks.append((m.start(), i))
        return blocks

    def zig_args(self, text, start):
        """The top-level arguments of the call whose `(` ends just before `start`."""
        depth, i, args, cur = 1, start, [], ""
        while i < len(text) and depth:
            c = text[i]
            if c == '"':
                j = i + 1
                while j < len(text) and text[j] != '"':
                    j += 2 if text[j] == "\\" else 1
                cur += text[i:j + 1]
                i = j + 1
                continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
                if depth == 0:
                    break
            if c == "," and depth == 1:
                args.append(cur.strip())
                cur = ""
            else:
                cur += c
            i += 1
        if cur.strip():
            args.append(cur.strip())
        return args

    def check_unit_reads(self):
        """A unit test that reads a file outside src/: by literal, through a const, or @embedFile."""
        src = os.path.join(self.root, "src")
        if not os.path.isdir(src):
            return
        call = re.compile(r"std\.fs\.cwd\(\)\.(%s)\(" % "|".join(READ_CALLS))
        embed = re.compile(r'@embedFile\("([^"]+)"\)')
        for base, _, names in os.walk(src):
            for name in sorted(names):
                if not name.endswith(".zig"):
                    continue
                path = os.path.join(base, name)
                rel = self.rel(path)
                text = open(path, encoding="utf-8").read()
                consts = dict(re.findall(r'\bconst\s+(\w+)\s*=\s*"([^"]+)"\s*;', text))
                blocks = self.zig_blocks(text)
                for m in call.finditer(text):
                    args = self.zig_args(text, m.end())
                    index = 1 if m.group(1) == "readFileAlloc" else 0
                    if index >= len(args):
                        continue
                    arg = args[index]
                    literal = re.fullmatch(r'"([^"]*)"', arg)
                    if literal:
                        targets = [literal.group(1)]
                    elif arg in consts:
                        targets = [consts[arg]]
                    elif any(a <= m.start() < b for a, b in blocks):
                        stands_for = self.allowed(rel, arg)
                        if stands_for is None:
                            self.errors.append(
                                "%s reads a path it cannot evaluate in a unit test (`%s`): it may read a file "
                                "outside src/ that the classifier does not select unit for. Use a literal, or add "
                                "(%r, %r) to UNANALYSED with the paths it reads" % (rel, arg, rel, arg))
                        targets = stands_for or []
                    else:
                        targets = []
                    for target in targets:
                        if self.exists(target) and not target.startswith("src/") and "unit" not in self.classify(target):
                            self.errors.append(
                                "%s reads %s in a unit test, but classify_changes.sh does not select unit for it" %
                                (rel, target))
                for m in embed.finditer(text):
                    target = posixpath.normpath(posixpath.join(posixpath.dirname(rel), m.group(1)))
                    if self.is_file(target) and not target.startswith("src/") and "unit" not in self.classify(target):
                        self.errors.append(
                            "%s embeds %s in a unit test, but classify_changes.sh does not select unit for it" %
                            (rel, target))

    # --- the check ------------------------------------------------------------------------

    def check_reads(self):
        roots = self.build_roots()
        if not roots:
            self.errors.append("build.zig: found no script that a step runs; classify_guard.py cannot read it")
        tags = {}      # file -> set of classes that read it
        via = {}       # (file, class) -> the file that read it
        queue = []
        for path, cls in roots.items():
            for c in cls:
                queue.append((path, c, None))
        scanned = {}
        while queue:
            path, cls, parent = queue.pop()
            if cls in tags.get(path, ()):
                continue
            tags.setdefault(path, set()).add(cls)
            via[(path, cls)] = parent
            if parent is not None and "all" in self.classify(path):
                continue  # a change to it runs every suite; what it reads is not a separate input
            if path not in scanned:
                if path.endswith(".py"):
                    scanned[path] = self.py_reads(path)
                elif path.endswith(".sh"):
                    scanned[path] = self.sh_reads(path)
                else:
                    scanned[path] = set()
            if "all" in self.classify(path) and parent is not None:
                continue  # a change to it runs every suite; what it reads is not a separate input
            for read in scanned[path]:
                queue.append((read, cls, path))
        known = set(self.known_classes())
        for path in sorted(tags):
            for cls in sorted(tags[path]):
                if cls not in known:
                    self.errors.append("the class '%s' of %s is not one classify_changes.sh prints" % (cls, path))
                elif cls not in self.classify(path):
                    chain, node = [], path
                    while node is not None:
                        chain.append(node)
                        node = via[(node, cls)]
                    self.errors.append(
                        "%s is read by the %s suite (%s) but classify_changes.sh does not select %s for it: "
                        "a change to it would skip the suite" % (path, cls, " <- ".join(chain), cls))

    def check_stale(self):
        # The entries are for this repository; a small tree in the tests has none of their files.
        if self.root != os.path.abspath(os.path.join(HERE, "..", "..")):
            return
        for key in sorted(set(UNANALYSED) - self.unanalysed_seen):
            self.errors.append("UNANALYSED entry %r matches no construction the guard finds: remove it" % (key,))
        for key in sorted(set(NOT_READS) - self.not_reads_seen):
            self.errors.append("NOT_READS entry %r matches no literal the guard finds: remove it" % (key,))

    # --- workflows ------------------------------------------------------------------------

    GATE_TERM = re.compile(
        r"needs\.changes\.outputs\.(\w+) != 'false'|matrix\.\w+ [!=]= '\w+'|always\(\)|!cancelled\(\)|[()]|&&|\|\||\s+")

    def check_workflow(self):
        path = os.path.join(self.root, ".github/workflows/ci.yml")
        if not os.path.isfile(path):
            return
        if yaml is None:
            self.errors.append("PyYAML is not installed: classify_guard.py reads the workflows with it")
            return
        workflow = yaml.safe_load(open(path, encoding="utf-8"))
        known = self.known_classes()
        jobs = workflow["jobs"]
        outputs = (jobs.get("changes") or {}).get("outputs") or {}
        for name in known:
            want = "${{ steps.classify.outputs.%s }}" % name
            if name not in outputs:
                self.errors.append("ci.yml's `changes` job does not output the class %s" % name)
            elif outputs[name] != want:
                self.errors.append("ci.yml's `changes` job outputs %s as `%s`, not `%s`" % (name, outputs[name], want))
        for name in sorted(set(outputs) - set(known)):
            self.errors.append("ci.yml's `changes` job outputs %s, which is not a class of classify_changes.sh" % name)
        # `all` and `binary` fold into the suites: every class a job is gated on is true for both.
        binary, everything = self.classify("build.zig"), self.classify("ci/job.sh")
        gated_on = set()
        for name, job in jobs.items():
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else needs
            if "changes" not in needs or name == "changes":
                continue
            allowed = JOB_CLASSES.get(name)
            if allowed is None:
                self.errors.append("ci.yml: job %s waits for `changes`, and classify_guard.py does not know which "
                                   "class gates it: add it to JOB_CLASSES" % name)
                continue
            used = set()
            for step in job.get("steps") or []:
                label = step.get("name") or step.get("uses") or step.get("run", "")[:40]
                condition = step.get("if")
                if not isinstance(condition, str) or "needs.changes.outputs." not in condition:
                    self.errors.append("ci.yml: job %s has a step with no condition on `changes`: %s" % (name, label))
                    continue
                rest = self.GATE_TERM.sub("", condition)
                if rest:
                    self.errors.append(
                        "ci.yml: job %s step `%s` is gated by `%s`; every term must be `needs.changes.outputs.<class> "
                        "!= 'false'` (so a failed `changes` runs the step), `always()` or a matrix test, not `%s`" %
                        (name, label, condition.strip(), rest.strip()))
                    continue
                for cls in re.findall(r"needs\.changes\.outputs\.(\w+) != 'false'", condition):
                    used.add(cls)
                    gated_on.add(cls)
                    if cls not in known:
                        self.errors.append("ci.yml gates on needs.changes.outputs.%s, which is not a class of "
                                           "classify_changes.sh" % cls)
                    elif cls not in allowed:
                        self.errors.append("ci.yml: job %s step `%s` is gated on `%s`, but the job depends on %s" %
                                           (name, label, cls, " and ".join(allowed)))
            if allowed[0] not in used:
                self.errors.append("ci.yml: no step of job %s is gated on `%s`, the class it depends on" % (name, allowed[0]))
        for cls in sorted(gated_on & set(known)):
            if cls in ("all", "binary"):
                continue
            if cls != "mac_keychain" and cls not in binary:
                self.errors.append("classify_changes.sh: `binary` (build.zig) does not make `%s` true, but ci.yml "
                                   "gates on it" % cls)
            if cls not in everything:
                self.errors.append("classify_changes.sh: `all` (ci/job.sh) does not make `%s` true, but ci.yml "
                                   "gates on it" % cls)

    def check_packages_gate(self):
        """packages.yml: every job that waits for `classify` runs unless the output is 'false'."""
        path = os.path.join(self.root, ".github/workflows/packages.yml")
        if not os.path.isfile(path) or yaml is None:
            return
        workflow = yaml.safe_load(open(path, encoding="utf-8")) or {}
        jobs = workflow.get("jobs") or {}
        for name, job in jobs.items():
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else needs
            if "classify" not in needs:
                continue
            condition = str(job.get("if", ""))
            if "needs.classify.outputs.run != 'false'" not in condition or "== 'true'" in condition:
                self.errors.append("packages.yml: job `%s` waits for `classify` but is not gated on "
                                   "`needs.classify.outputs.run != 'false'` (the form that runs when `classify` fails)"
                                   % name)

    LEVEL = {"none": 0, "read": 1, "write": 2}

    def grants(self, permissions):
        if permissions is None:
            return None
        if permissions in ("read-all", "write-all"):
            return {"*": 1 if permissions == "read-all" else 2}
        return {k: self.LEVEL[v] for k, v in permissions.items()}

    def check_permissions(self):
        """A workflow that calls another grants it what its jobs ask for."""
        folder = os.path.join(self.root, ".github/workflows")
        if not os.path.isdir(folder) or yaml is None:
            return
        loaded = {}
        for name in sorted(os.listdir(folder)):
            if name.endswith((".yml", ".yaml")):
                loaded[name] = yaml.safe_load(open(os.path.join(folder, name), encoding="utf-8")) or {}
        for caller, workflow in loaded.items():
            for job_name, job in (workflow.get("jobs") or {}).items():
                uses = job.get("uses")
                if not isinstance(uses, str) or not uses.startswith("./.github/workflows/"):
                    continue
                callee_name = uses.rsplit("/", 1)[1]
                callee = loaded.get(callee_name)
                if callee is None:
                    self.errors.append("%s: job %s calls %s, which is not a workflow here" % (caller, job_name, uses))
                    continue
                grant = self.grants(job["permissions"] if "permissions" in job else workflow.get("permissions")) or {}
                asked = {}
                top = self.grants(callee.get("permissions")) or {}
                for scope, jb in [("workflow", None)] + list((callee.get("jobs") or {}).items()):
                    granted = top if jb is None else (self.grants(jb.get("permissions")) or {})
                    for key, level in granted.items():
                        if level > asked.get(key, (0, ""))[0]:
                            asked[key] = (level, "the workflow" if jb is None else "its job `%s`" % scope)
                for key, (level, who) in sorted(asked.items()):
                    have = grant.get(key, grant.get("*", 0))
                    if have < level:
                        names = {v: k for k, v in self.LEVEL.items()}
                        self.errors.append(
                            "%s: job `%s` calls %s with `%s: %s`, but %s asks for `%s: %s`; GitHub refuses a called "
                            "workflow that asks for more than its caller grants, when the file loads" %
                            (caller, job_name, callee_name, key, names[have], who, key, names[level]))


def main(argv):
    root = os.path.join(HERE, "..", "..")
    if len(argv) == 3 and argv[1] == "--root":
        root = argv[2]
    elif len(argv) != 1:
        print("usage: classify_guard.py [--root DIR]", file=sys.stderr)
        return 2
    guard = Guard(root)
    guard.check_reads()
    guard.check_unit_reads()
    guard.check_stale()
    guard.check_workflow()
    guard.check_packages_gate()
    guard.check_permissions()
    for error in guard.errors:
        print("error[NRV-E1250]: classify_guard.py: " + error, file=sys.stderr)
    if guard.errors:
        print("  cause  a suite reads a file the change classifier does not select it for, or ci.yml gates a job "
              "on the wrong class, or a workflow calls another without the permissions it asks for, so a change "
              "would skip a suite or a release would fail to start (decision O14)", file=sys.stderr)
        print("  fix    add the file, or the directory it is in, to the rule for that suite in "
              ".github/scripts/classify_changes.sh, and a case to classify_changes_test.sh; or correct the "
              "workflow", file=sys.stderr)
        return 1
    print("classify_guard: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
