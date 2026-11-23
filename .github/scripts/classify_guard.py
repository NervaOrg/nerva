#!/usr/bin/env python3
"""Fails when classify_changes.sh would skip a suite for a change to a file the suite reads.

classify_changes.sh skips a class of tests when no input of it changed. That is sound only if the
table lists every input, so this finds the inputs mechanically, from the code that reads them
(decision O14, condition 2), and fails when the table does not select the suite for one.

  1. build.zig's steps name the scripts they run (tests/api/api.py, ../errors/wire.py, ...); each
     script is a root, tagged with the class of its step (test:api is `api`).
  2. A script's reads are found in its syntax tree: an `import` of a module in its own directory or
     one it put on `sys.path`, and every path it builds (`os.path.join(HERE, "..", "demo", ...)`,
     `Path(__file__).parent / "x"`) or names ("docs/API.md", "VERSION") that is a file of the
     repository. A Python file reached is read in turn; the tags travel along.
  3. For every file reached, classify_changes.sh must select every tag it carries.

It also checks the unit tests' reads of files outside src/ (`readFileAlloc` of a path), that every
`needs.changes.outputs.X` in ci.yml names a class, and that no step of a job that waits for
`changes` runs without a condition on it. A file nothing reads is the classifier's to place or to
fail closed on: the guard has nothing to say about it.

  classify_guard.py [--root DIR]      the repository, by default the one this file is in
"""
import ast
import os
import posixpath
import re
import subprocess
import sys

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
EXTRA_ROOTS = {"tests/packaging": "packaging", "tests/macos": "macos"}


class Guard:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.errors = []
        self.classes = {}

    # --- the classifier -------------------------------------------------------------------

    def classify(self, path):
        if path not in self.classes:
            out = subprocess.run([CLASSIFIER], input=path + "\n", capture_output=True, text=True, check=True).stdout
            self.classes[path] = {k for k, v in (line.split("=") for line in out.split()) if v == "true"}
        return self.classes[path]

    def known_classes(self):
        out = subprocess.run([CLASSIFIER, "--all"], capture_output=True, text=True, check=True).stdout
        return {line.split("=")[0] for line in out.split()}

    # --- the repository -------------------------------------------------------------------

    def exists(self, rel):
        return os.path.exists(os.path.join(self.root, rel))

    def is_file(self, rel):
        return os.path.isfile(os.path.join(self.root, rel))

    def rel(self, absolute):
        r = os.path.relpath(absolute, self.root)
        return None if r.startswith("..") else r

    # --- roots ----------------------------------------------------------------------------

    def build_roots(self):
        """The scripts build.zig runs, each with its step's class."""
        text = open(os.path.join(self.root, "build.zig"), encoding="utf-8").read()
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
        for directory, cls in EXTRA_ROOTS.items():
            full = os.path.join(self.root, directory)
            if os.path.isdir(full):
                for name in sorted(os.listdir(full)):
                    if name.endswith(".py"):
                        roots.setdefault(directory + "/" + name, set()).add(cls)
        return roots

    # --- reads of a Python file -----------------------------------------------------------

    def reads(self, rel):
        """The repository paths the Python file `rel` reads: (files, directories put on sys.path)."""
        source = open(os.path.join(self.root, rel), encoding="utf-8").read()
        tree = ast.parse(source, filename=rel)
        here = posixpath.dirname(rel)
        env = {}

        def ev(node):
            """('abs', repo path), ('lit', text) or None."""
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                return ("lit", node.value)
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

        # Module-level assignments first (HERE = dirname(abspath(__file__))), in order.
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                value = ev(node.value)
                if value:
                    env[node.targets[0].id] = value

        files, dirs = set(), set()
        for node in ast.walk(tree):
            value = None
            if isinstance(node, (ast.Call, ast.BinOp, ast.Attribute, ast.Subscript)):
                value = ev(node)
            elif isinstance(node, ast.Constant) and isinstance(node.value, str):
                value = ("lit", node.value)
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
            if self.is_file(absolute):
                files.add(absolute)
            elif self.exists(absolute) and kind == "abs" and absolute != here:
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
        return files

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
        while queue:
            path, cls, parent = queue.pop()
            if cls in tags.get(path, ()):
                continue
            tags.setdefault(path, set()).add(cls)
            via[(path, cls)] = parent
            if path.endswith(".py"):
                for read in self.reads(path):
                    queue.append((read, cls, path))
        known = self.known_classes()
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

    def check_unit_reads(self):
        """A unit test that reads a file outside src/ (readFileAlloc, openFile on a repository path)."""
        reads = re.compile(r'(?:readFileAlloc|openFile|openFileZ)\s*\([^;"]*"([A-Za-z0-9_./-]+)"')
        src = os.path.join(self.root, "src")
        if not os.path.isdir(src):
            return
        for base, _, names in os.walk(src):
            for name in names:
                if not name.endswith(".zig"):
                    continue
                path = os.path.join(base, name)
                for m in reads.finditer(open(path, encoding="utf-8").read()):
                    target = m.group(1)
                    if self.is_file(target) and not target.startswith("src/") and "unit" not in self.classify(target):
                        self.errors.append(
                            "%s reads %s in a unit test, but classify_changes.sh does not select unit for it" %
                            (self.rel(path), target))

    def check_workflow(self):
        path = os.path.join(self.root, ".github/workflows/ci.yml")
        if not os.path.isfile(path):
            return
        text = open(path, encoding="utf-8").read()
        known = self.known_classes()
        used = set(re.findall(r"needs\.changes\.outputs\.(\w+)", text))
        for name in sorted(used - known):
            self.errors.append("ci.yml gates on needs.changes.outputs.%s, which is not a class of classify_changes.sh" % name)
        declared = set(re.findall(r"^      (\w+): \$\{\{ steps\.classify\.outputs\.\w+ \}\}$", text, re.M))
        for name in sorted(known - declared):
            self.errors.append("ci.yml's `changes` job does not output the class %s" % name)
        jobs = re.split(r"^  ([\w-]+):\n", text.split("\njobs:\n", 1)[1], flags=re.M)
        for name, body in zip(jobs[1::2], jobs[2::2]):
            if not re.search(r"^    needs: changes$", body, re.M):
                continue
            steps = re.split(r"^      - ", body.split("\n    steps:\n", 1)[-1], flags=re.M)[1:]
            for step in steps:
                if not re.search(r"^        if: .*needs\.changes\.outputs\.", step, re.M):
                    first = step.splitlines()[0]
                    self.errors.append("ci.yml: job %s has a step with no condition on `changes`: %s" % (name, first))


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
    guard.check_workflow()
    for error in guard.errors:
        print("error[NRV-E1250]: classify_guard.py: " + error, file=sys.stderr)
    if guard.errors:
        print("  cause  a suite reads a file the change classifier does not select it for, so a change to that "
              "file would skip the suite instead of running it (decision O14)", file=sys.stderr)
        print("  fix    add the file, or the directory it is in, to the rule for that suite in "
              ".github/scripts/classify_changes.sh, and a case to classify_changes_test.sh", file=sys.stderr)
        return 1
    print("classify_guard: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
