#!/usr/bin/env python3
"""Checks the change classifier's manifest and the workflows' wiring (decision O14).

classify_changes.sh skips a class of tests from the hand-kept manifest .github/test-inputs.txt, and
ci.yml and packages.yml gate their jobs on its output. This checks two things.

  1. The manifest, by a cheap lint. Every file a narrowable suite owns (a file the manifest gives
     a class and that does not run everything) is scanned for literal repository paths: a token such
     as `docs/API.md`, `tests/api/api.py` or `../api`, or a Python `import` of a module that is a
     tracked file. Each path found must be selected for every class of the file that names it, or
     run everything. BEST EFFORT, and no proof: it cannot see a path built at run time, a directory
     listing, a glob, an `importlib` name, a path on a comment line (skipped), or one
     read through another file. The manifest is the claim; this catches the commonest slip, a new
     literal that the manifest does not know. A rule that matches no file is an error too.
  2. The wiring: ci.yml's `changes` job outputs each class as its own value, every job that waits
     for it runs after a failed one (`!cancelled()`), every step of such a job is gated in exactly
     `needs.changes.outputs.<class> != 'false'` on a class its job depends on, no gated job or step
     has `continue-on-error`, `system` waits for the jobs it aggregates, runs `always()` and has the step that fails it unless each
     succeeded, the classifier's own test
     and its checkout have no `if`, `on.push` has no `paths` or `paths-ignore`, packages.yml's jobs
     wait for `classify` and run when it fails or says nothing, and every workflow that calls another
     grants it the permissions its jobs ask for (a called workflow cannot hold more than its caller,
     and GitHub refuses the file when it does). What a step DOES (the force, the fail-closed
     reading of garbled output) is run by classify_changes_test.sh, not matched here.

  classify_guard.py [--root DIR]      the repository, by default the one this file is in
"""
import fnmatch
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

# The classes a manifest rule names; the others (all, any, checks, unit, ...) are not a suite's own.
SUITE_CLASSES = ("integration", "api", "views", "release", "demo", "demo_r4", "demo_r5", "macos", "packaging",
                 "ci_scripts", "mac_keychain")

# The lint's literal: any run of path characters that names a tracked file, whatever its extension, as
# written or relative to the file that names it.
TOKEN = re.compile(r"[A-Za-z0-9_.@+-]+(?:/[A-Za-z0-9_.@+-]*)*")
# `import a, b.c as d` (every name, also after a `;` or a `:`), and `from x import a, b` or `from x import (a,\n b)`:
# the module x, and each name, which may be a submodule.
IMPORT = re.compile(r"(?:^|[;:])[ \t]*import[ \t]+([^;\n]+)", re.M)
IMPORT_FROM = re.compile(r"(?:^|[;:])[ \t]*from[ \t]+([\w.]+)[ \t]+import[ \t]+(\([^)]*\)|[^;\n]*)", re.M)
# Documents a suite's file names in a docstring and never reads (the manifest says `none` for them), and the
# one test file another names as the place a case lives. Each is allowed by hand: the lint would otherwise
# demand every suite select its own prose. A real read of one of these is not seen (O14, Limits).
MENTIONED = ("CLAUDE.md", "docs/DECISIONS.md", "docs/briefs/*.md")
MENTIONED_PAIRS = {("tests/errors/commands.py", "tests/release/mixed.py")}
COMMENT = re.compile(r"^\s*(?:#|//)")

# The classes each ci.yml job's steps may be gated on, and at least one step must be gated on the
# first of them. A job not in this table that waits for `changes` is an error: add it here.
JOB_CLASSES = {
    "checks": ["checks", "ci_scripts", "packaging"],
    "ci-scripts": ["ci_scripts"],
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
# The jobs the required check `system` aggregates.
SYSTEM_NEEDS = {"checks", "ci-scripts", "integration", "api", "releases", "targets", "macos-arm64", "macos-x86_64",
                "mac-keychain"}

# The one job-level `if` a job that waits for `changes` may have, besides the default: it must run
# when `changes` fails (`!cancelled()` runs after a failed need; a bare comparison of an output
# skips the job, and a skipped required check passes).
JOB_IF = "!cancelled()"
JOB_IF_OTHER = {
    "vopr": "!cancelled() && github.event_name == 'pull_request'",
    "vopr_main": "!cancelled() && github.event_name != 'pull_request'",
    "macos-x86_64": "!cancelled() && needs.macos-arm64.result == 'success'",
}
# A step's `if` is exactly one of these forms: a class `!= 'false'` (a failed `changes` leaves the
# output empty, and empty is not 'false'), after `always() && ` for a step that must also run when
# an earlier one failed, or VOPR's matrix of two classes. Anything else (`== 'true'`, `&& <term>`,
# `|| false`) can skip a step the class selects, or fail open.
GATE = re.compile(r"(?:always\(\) && )?needs\.changes\.outputs\.(\w+) != 'false'")
GATE_MATRIX = {
    "vopr": "((matrix.seed == 'random' && needs.changes.outputs.any != 'false') || "
            "(matrix.seed != 'random' && needs.changes.outputs.vopr != 'false'))",
}
# Steps with no `if` at all: the classifier's own test runs on every pull request, and the checkout
# it needs. Keyed by job; a step of the job that runs the test must have no `if`.
UNGATED = {"ci-scripts": "classify_changes_test.sh"}
PACKAGES_IF = ("!cancelled() && (github.event_name != 'pull_request' || !github.event.pull_request.draft) && "
               "needs.classify.outputs.run != 'false'")


class Guard:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.errors = []
        self.classes = {}
        self.manifest = os.path.join(self.root, ".github/test-inputs.txt")

    # --- the classifier -------------------------------------------------------------------

    def run_classifier(self, args, stdin=""):
        env = dict(os.environ, CLASSIFY_MANIFEST=self.manifest)
        out = subprocess.run([CLASSIFIER] + args, input=stdin, capture_output=True, text=True, env=env)
        if out.returncode:
            self.errors.append("classify_changes.sh failed: %s" % out.stderr.strip())
            return None
        return {k for k, v in (line.split("=") for line in out.stdout.split()) if v == "true"}

    def classify(self, path):
        if path not in self.classes:
            self.classes[path] = self.run_classifier([], path + "\n")
        return self.classes[path] or set()

    def known_classes(self):
        out = subprocess.run([CLASSIFIER, "--all"], capture_output=True, text=True)
        return [line.split("=")[0] for line in out.stdout.split()]

    # --- the repository -------------------------------------------------------------------

    def tracked_files(self):
        """The tracked files (git), or every file but .git and build output where root is not a work tree."""
        out = subprocess.run(["git", "-C", self.root, "ls-files", "-z"], capture_output=True)
        if out.returncode == 0 and out.stdout:
            return sorted(p for p in out.stdout.decode().split("\0") if p and os.path.isfile(os.path.join(self.root, p)))
        found = []
        for base, dirs, names in os.walk(self.root):
            dirs[:] = [d for d in dirs if d not in (".git", ".zig-cache", "zig-out")]
            found.extend(os.path.relpath(os.path.join(base, n), self.root) for n in names)
        return sorted(found)

    def read(self, rel):
        try:
            data = open(os.path.join(self.root, rel), "rb").read()
        except OSError:
            return None
        if b"\0" in data or len(data) > 2_000_000:
            return None
        return data.decode("utf-8", "replace")

    # --- the lint -------------------------------------------------------------------------

    def literals(self, rel, text):
        """The text the lint scans: every line but a comment line. Triple-quoted strings are scanned, docstrings
        too: a string may be a script that runs, and a path in prose only adds a candidate (select it, or reword)."""
        return "\n".join(line for line in text.splitlines() if not COMMENT.match(line))

    def resolve(self, rel, token, files):
        """The tracked file a literal token names, or a path relative to the file that names it, trying each
        suffix of the token (`$here/../docs/x.md` is `../docs/x.md`). A directory is not expanded."""
        parts = token.rstrip("/").split("/")
        for k in range(len(parts)):
            tail = "/".join(parts[k:])
            for cand in (posixpath.normpath(tail), posixpath.normpath(posixpath.join(posixpath.dirname(rel), tail))):
                if cand.startswith("..") or cand in (".", ""):
                    continue
                if cand in files:
                    return [cand]
        return []

    @staticmethod
    def imported(text):
        """The top-level module names a Python text imports: every name of a comma import, the module of a
        `from`, and each name it imports (a submodule is `from pkg import sub`)."""
        names = set()
        for clause in IMPORT.findall(text):
            for part in clause.split(","):
                words = part.split()
                if words:
                    names.add(words[0].split(".")[0])
        for module, clause in IMPORT_FROM.findall(text):
            names.add(module.lstrip(".").split(".")[0])
            for part in clause.strip("()").split(","):
                words = part.split()
                if words:
                    names.add(words[0])
        return {n for n in names if n.isidentifier()}

    def literal_paths(self, rel, text, files, modules):
        found = {}
        for token in TOKEN.findall(self.literals(rel, text)):
            token = token[2:] if token.startswith("./") else token
            for p in self.resolve(rel, token, files):
                found[p] = token
        if rel.endswith(".py"):
            for name in self.imported(text):
                for p in modules.get(name, ()):
                    found[p] = "import " + name
        found.pop(rel, None)
        return found

    def check_manifest(self):
        if not os.path.isfile(self.manifest):
            self.errors.append(".github/test-inputs.txt does not exist")
            return
        if self.run_classifier([], "README.md\n") is None:
            return
        files = self.tracked_files()
        file_set = set(files)
        # A module name is a tracked `<name>.py`; with none, a directory `<name>` (a package, all its files).
        modules, packages = {}, {}
        for f in files:
            if f.endswith(".py"):
                modules.setdefault(posixpath.basename(f)[:-3], []).append(f)
                d = posixpath.dirname(f)
                while d:
                    packages.setdefault(posixpath.basename(d), []).append(f)
                    d = posixpath.dirname(d)
        for name, found in packages.items():
            modules.setdefault(name, found)
        self.check_rules(files)
        for rel in files:
            if rel.endswith(".md"):
                continue
            got = self.classify(rel)
            if "all" in got:
                continue
            own = [c for c in SUITE_CLASSES if c in got]
            if not own:
                continue
            text = self.read(rel)
            if text is None:
                continue
            for path, token in sorted(self.literal_paths(rel, text, file_set, modules).items()):
                if (rel, path) in MENTIONED_PAIRS or any(fnmatch.fnmatchcase(path, m) for m in MENTIONED):
                    continue
                missing = [c for c in own if c not in self.classify(path)]
                if missing:
                    self.errors.append(
                        "%s (%s) names %s (`%s`), but .github/test-inputs.txt does not select %s for it: a change to it "
                        "would skip the suite" % (rel, " ".join(own), path, token, " and ".join(missing)))

    def check_rules(self, files):
        """A rule that narrows (not `all`) and matches no tracked file is stale: the directory moved."""
        for n, line in enumerate(open(self.manifest, encoding="utf-8"), 1):
            fields = line.split("#", 1)[0].split()
            if len(fields) != 2 or fields[0] == "all":
                continue
            pattern = re.compile("".join(".*" if c == "*" else re.escape(c) for c in fields[1]))
            if not any(pattern.fullmatch(f) for f in files):
                self.errors.append(".github/test-inputs.txt:%d: the rule `%s %s` matches no file: remove it, or fix "
                                   "the glob" % (n, fields[0], fields[1]))

    def check_symlinks(self):
        """A tracked symlink makes a path another file's: the lint follows none, so there must be none."""
        out = subprocess.run(["git", "-C", self.root, "ls-files", "-s"], capture_output=True, text=True)
        if out.returncode:
            return
        for line in out.stdout.splitlines():
            if line.startswith("120000 "):
                self.errors.append("%s is a symbolic link: classify_guard.py follows none, so a change to its target "
                                   "could skip a suite that reads it through the link" % line.split("\t", 1)[1])

    # --- workflows ------------------------------------------------------------------------

    @staticmethod
    def expression(condition):
        """An `if:` as GitHub evaluates it: `${{ }}` stripped, whitespace collapsed."""
        text = " ".join(str(condition).split())
        m = re.fullmatch(r"\$\{\{ (.*) \}\}", text)
        return m.group(1) if m else text

    def load(self, name):
        path = os.path.join(self.root, ".github/workflows", name)
        if not os.path.isfile(path):
            return None
        return yaml.safe_load(open(path, encoding="utf-8")) or {}

    @staticmethod
    def needs_of(job):
        needs = job.get("needs") or []
        return [needs] if isinstance(needs, str) else list(needs)

    def check_triggers(self, workflow):
        """Every push to main runs everything: no `paths` or `paths-ignore` on `push` (O14). PyYAML reads the
        key `on` as True."""
        on = workflow.get("on", workflow.get(True)) or {}
        push = on.get("push") if isinstance(on, dict) else None
        if isinstance(push, dict) and ("paths" in push or "paths-ignore" in push):
            self.errors.append("ci.yml: `on.push` has `paths` or `paths-ignore`: a push to main must run everything, "
                               "Markdown included, since it is the backstop for what a pull request skipped (O14)")

    def check_workflow(self):
        if not os.path.isfile(os.path.join(self.root, ".github/workflows/ci.yml")):
            return
        if yaml is None:
            self.errors.append("PyYAML is not installed: classify_guard.py reads the workflows with it")
            return
        workflow = self.load("ci.yml")
        self.check_triggers(workflow)
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
        everything = self.run_classifier(["--all"]) or set()
        system = self.needs_of(jobs.get("system") or {})
        if set(system) != SYSTEM_NEEDS:
            self.errors.append("ci.yml: the required check `system` waits for %s, not %s: a job it drops can fail "
                               "unseen" % (sorted(system), sorted(SYSTEM_NEEDS)))
        self.check_system(jobs.get("system") or {})
        for name, job in jobs.items():
            if "changes" not in self.needs_of(job) or name == "changes":
                continue
            allowed = JOB_CLASSES.get(name)
            if allowed is None:
                self.errors.append("ci.yml: job %s waits for `changes`, and classify_guard.py does not know which "
                                   "class gates it: add it to JOB_CLASSES" % name)
                continue
            if "continue-on-error" in job:
                self.errors.append("ci.yml: job %s has `continue-on-error`: a failed suite would pass" % name)
            want_if = JOB_IF_OTHER.get(name, JOB_IF)
            have_if = self.expression(job["if"]) if "if" in job else None
            if have_if != want_if:
                self.errors.append(
                    "ci.yml: job %s has `if: %s`; it must be exactly `%s` (a job that waits for `changes` and does not "
                    "run after a failed one is skipped, and a skipped required check passes)" %
                    (name, have_if if have_if is not None else "(none)", want_if))
            used = set()
            for step in job.get("steps") or []:
                label = step.get("name") or step.get("uses") or step.get("run", "")[:40]
                run = step.get("run", "") or ""
                condition = step.get("if")
                if "continue-on-error" in step:
                    self.errors.append("ci.yml: job %s step `%s` has `continue-on-error`: a failed step would pass" %
                                       (name, label))
                ungated = UNGATED.get(name)
                if ungated and (ungated in run or str(step.get("uses", "")).startswith("actions/checkout")):
                    if condition is not None:
                        self.errors.append("ci.yml: job %s step `%s` has an `if`: it runs on every pull request, with "
                                           "no gate (the classifier's own test must not depend on the classifier)" %
                                           (name, label))
                    continue
                if not isinstance(condition, str) or "needs.changes.outputs." not in condition:
                    self.errors.append("ci.yml: job %s has a step with no condition on `changes`: %s" % (name, label))
                    continue
                text = self.expression(condition)
                classes = None
                m = GATE.fullmatch(text)
                if m:
                    classes = [m.group(1)]
                elif GATE_MATRIX.get(name) == text:
                    classes = re.findall(r"needs\.changes\.outputs\.(\w+) != 'false'", text)
                if classes is None:
                    self.errors.append(
                        "ci.yml: job %s step `%s` is gated by `%s`; it must be exactly `needs.changes.outputs.<class> "
                        "!= 'false'` (so a failed `changes` runs the step), optionally after `always() && `%s" %
                        (name, label, text, " (or the job's matrix form)" if name in GATE_MATRIX else ""))
                    continue
                for cls in classes:
                    used.add(cls)
                    if cls not in known:
                        self.errors.append("ci.yml gates on needs.changes.outputs.%s, which is not a class of "
                                           "classify_changes.sh" % cls)
                    elif cls not in allowed:
                        self.errors.append("ci.yml: job %s step `%s` is gated on `%s`, but the job depends on %s" %
                                           (name, label, cls, " and ".join(allowed)))
                    elif cls not in everything:
                        self.errors.append("classify_changes.sh: `all` does not make `%s` true, but ci.yml gates on "
                                           "it" % cls)
            if allowed[0] not in used:
                self.errors.append("ci.yml: no step of job %s is gated on `%s`, the class it depends on" %
                                   (name, allowed[0]))
            if UNGATED.get(name) and not any(UNGATED[name] in (s.get("run") or "") for s in job.get("steps") or []):
                self.errors.append("ci.yml: job %s has no step that runs %s" % (name, UNGATED[name]))

    def check_system(self, job):
        """`system` is the required check. It runs after a failed need (`if: always()`; the default `success()`
        would skip it, and a skipped required check passes), and a step fails it unless every need's result is
        `success`: the step reads `join(needs.*.result, ' ')`, tests each against `success` and exits 1."""
        have = self.expression(job["if"]) if "if" in job else None
        if have != "always()":
            self.errors.append("ci.yml: job system has `if: %s`; it must be exactly `always()` (a failed job it "
                               "waits for would skip it, and a skipped required check passes)" %
                               (have if have is not None else "(none)"))
        if "continue-on-error" in job:
            self.errors.append("ci.yml: job system has `continue-on-error`: a failed job would pass")
        for step in job.get("steps") or []:
            env = " ".join(str(v) for v in (step.get("env") or {}).values())
            run = step.get("run") or ""
            if ("join(needs.*.result" in env and "!= success" in run and "exit 1" in run and "if" not in step
                    and "continue-on-error" not in step):
                return
        self.errors.append("ci.yml: job system has no step, without `if` or `continue-on-error`, that reads "
                           "`join(needs.*.result, ' ')`, compares each with `success` and exits 1: a failed job "
                           "it waits for would pass")

    def check_packages_gate(self):
        """packages.yml: every job that waits for `classify` runs unless the output is 'false'."""
        workflow = self.load("packages.yml") if yaml else None
        if workflow is None:
            return
        jobs = workflow.get("jobs") or {}
        for name, job in jobs.items():
            if "classify" not in self.needs_of(job):
                continue
            have = self.expression(job["if"]) if "if" in job else None
            if have != PACKAGES_IF:
                self.errors.append(
                    "packages.yml: job `%s` waits for `classify` and has `if: %s`; it must be exactly `%s` (it runs "
                    "when `classify` fails, a draft waits for ready_for_review, and an empty output is not 'false')"
                    % (name, have if have is not None else "(none)", PACKAGES_IF))
            if "continue-on-error" in job:
                self.errors.append("packages.yml: job `%s` has `continue-on-error`: a failed suite would pass" % name)

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
    guard.check_manifest()
    guard.check_symlinks()
    guard.check_workflow()
    guard.check_packages_gate()
    guard.check_permissions()
    for error in guard.errors:
        print("error[NRV-E1250]: classify_guard.py: " + error, file=sys.stderr)
    if guard.errors:
        print("  cause  a suite names a file the manifest does not select it for, or a workflow is wired so that a "
              "change could skip a suite, or a workflow calls another without the permissions it asks for "
              "(decision O14)", file=sys.stderr)
        print("  fix    add the file, or its directory, to the rule for that suite in .github/test-inputs.txt and a "
              "case to classify_changes_test.sh; or correct the workflow", file=sys.stderr)
        return 1
    print("classify_guard: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
