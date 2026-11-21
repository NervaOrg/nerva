---
id: O2b
date: 2026-11-21
area: Releases
---

# `v0.7.1` here is the old repository's own tag, pushed from a clone that kept it

**Decision.** The restore (`3aa4d1c`) came from a source zip of `NervaLog/nerva`'s `main` at
`d24340fd`. That commit is later than v0.7.1 (released 2026-11-14 from the candidate `c886c9f`,
P388) and already holds work not yet released (CHANGELOG, "Unreleased (v0.7.2)": #335, #336 and
the rest). This repository has no tags. The owner pushes the real `v0.7.1` tag from a local clone
of `NervaLog/nerva` that still has it, along with the history it points at:

    git push git@github.com:NervaOrg/nerva.git v0.7.1

That history does not connect to `main` here, but git compares trees, not ancestry. So
`git diff v0.7.1 main` is the true change from v0.7.1 to v0.7.2, and both of v0.7.2's
adversarial reviewers (P147b) start from it. Only that two-dot (tree) form works across the two
histories. The three-dot form `git diff v0.7.1...main` (the form CLAUDE.md uses for pull request
diffs), GitHub's compare view `v0.7.1...main` and GitHub's generated release notes from the
previous tag all fail with "no merge base". Never use them for this release.

The restore point is **not** tagged `v0.7.1`. It contains unreleased work, so a review "since the
last tag" would skip that work.

**Why.** The release gate reviews "every change since the last tag". Without the real tag, that
diff either does not exist or leaves out the work between `c886c9f` and `d24340fd`.

**What it costs.**
- `git log v0.7.1..main` and `git merge-base --is-ancestor` mean nothing across the two
  histories. Only tree diffs do.
- No script reads the last tag: `release_check.sh candidate` uses `release/candidate`, and
  nothing runs on a tag push (`release.yml` runs on `main` pushes that change `VERSION`). So
  pushing it starts nothing.
- If no clone with the tag survives, this decision is superseded. The fallback is to tag the
  restore point as `restore-d24340fd`; the reviewers then also read, in full, the code behind each
  "Unreleased" item.
- `release/candidate` still names `c886c9f`, which is in that pushed history but is not an
  ancestor of `main`. The release check will refuse every v0.7.2 `VERSION` commit until a new
  candidate on `main` is written there (P374). That happens when v0.7.2's candidate is chosen.
- Order: pull request #2 must merge before v0.7.2's candidate is chosen, because it changes
  `src/nerva/mac_release.zig`, and the release check refuses a `VERSION` commit that changes `src/`
  since the candidate (P374).
