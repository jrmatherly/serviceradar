# Upstream review skill for the serviceradar fork

Design record for a project skill that lists what changed upstream in
`carverauto/serviceradar`, classifies each pull request against our tree, and
tracks what we have reviewed and adopted. It is the fork counterpart of the
`upstream-review` skill in `jrmatherly/ai-kb`, which this document was
written from.

## Facts this design rests on

Measured 2026-10-21 in `/Users/jason/dev/serviceradar`.

- `jrmatherly/serviceradar` is a GitHub fork of `carverauto/serviceradar`
  (`gh api` reports `fork: true`, `parent: carverauto/serviceradar`). Default
  branch is `staging` on both. The fork point is `5993ec10432ccbddaeffb5fe3416ba7d261bede7`
  (2026-10-21, "Merge pull request #5874"). We have no commits of our own yet.
- Shared history. `git merge-base HEAD carverauto/staging` is our HEAD, so
  `<sha>..<sha>` ranges, `git cherry-pick -x`, and `--is-ancestor` all work.
  The ai-kb copy-not-fork machinery (seed SHA, archived `.git` bootstrap, the
  `<` marker) is not needed.
- Upstream merges every PR with a merge commit. In the first seven hours after
  the fork there were 9 PRs and 35 commits. `git log --first-parent` yields one
  entry per PR; `log <merge>^1..<merge>^2` yields its commits.
- Upstream subjects follow `type(scope): subject`, plus a house prefix
  `no-mistakes(scope):` on 72 of the last 200 commits. Picks keep them.
- git's `--cherry-pick` dedup does not detect an adopted PR. Tested in a
  scratch worktree on PR #5877 (5 commits): the merge commit stayed listed
  after a `-m 1` pick, after a squash, and after picking every inner commit
  (one of five inner commits also stayed listed). An explicit watermark plus a
  decision log is therefore required, as in ai-kb.
- `gh repo set-default` is unset. A remote named `upstream` would make `gh`
  prefer the parent repository, so the upstream remote is named `carverauto`.
- `.claude/` is gitignored (`.gitignore` line 27). The skill must be
  re-included to be tracked.
- No rebrand yet: module `github.com/carverauto/serviceradar`, images
  `ghcr.io/carverauto/*`, 23 upstream workflows in `.github/workflows/`.
- Tools present: git 2.56, gh 2.102, jq, bats 1.14, shellcheck, actionlint.

## Decisions (owner, 2026-10-21)

1. Adopt upstream PRs by cherry-picking their inner commits one by one with
   `-x`, oldest first. Not squashed, not `-m 1` merge picks.
2. A rebrand is planned for later. The skill reserves a step for a rebrand
   mapper (to be adapted from ai-kb `scripts/rebrand/`) that is a no-op until
   the mapper exists.
3. `.github/workflows/` becomes the fork's own CI (separate session). Upstream
   workflow changes are read for new validation commands and hand-ported,
   never cherry-picked.
4. Review state is tracked in git under `.upstream-review/`.

## What the skill does

Type: tool-wrapper plus workflow. A deterministic bash driver does the
listing, classification markers and watermark; the SKILL.md body carries the
review method and the repo rules; `references/` carry the deviations table,
the decision-log template and the per-area validation commands.

Driver `${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh`:

| Mode | Effect |
| --- | --- |
| (none) | fetch `carverauto/staging`, list unreviewed first-parent entries oldest first: PR number, branch, PR title (the merge commit's body), date, commit count |
| `--stat` | plus each entry's commits and, per touched file, a marker |
| `--urls` | plus the github.com commit URL per entry |
| `--show <sha>` | a PR merge: its commit list and combined diff; any other commit: `git show` |
| `--diverged` | `git diff --stat <forkPointSha> HEAD`, our footprint |
| `--advance <sha>` | set `lastReviewedSha` to a SHA that is on `carverauto/staging` and not behind the current watermark |

Markers compare our `HEAD:<path>` blob with the commit's parent blob (the
pre-image a cherry-pick merges from), falling back to the fork point's blob:
`=` equal (clean pick); `<` ours equals the fork point but not the pre-image,
or the file exists in neither (an earlier unreviewed upstream commit touched
it first; pick in order); `~` differs from both (we changed it; resolve or
hand-port); `x` we removed it; `+` new upstream file; `bin` binary. The
fork point plays the role ai-kb's seed SHA plays. Without the `<` case, any
file two window commits touch shows `~` on the second, and a file an earlier
window commit created shows `x`, both wrongly.

An entry is expanded into commits when it has two parents, whatever its
subject; the `Merge pull request #N from owner/branch` subject only supplies
the label.

State `.upstream-review/watermark.json`: `upstreamUrl`, `upstreamRemote`,
`upstreamBranch`, `forkPointSha`, `forkPointDate`, `lastReviewedSha`,
`lastReviewedShaShort`, `lastReviewedDate`, `lastAdvancedAt`, `note`.
Decision logs: `.upstream-review/reviews/<YYYY-MM-DD>-review.md`.

Review method: run `--stat`; group by PR; `--show` each; classify our state
(ALREADY-HAVE, ABSENT, DIVERGED, PARTIAL); verdict ADOPT, ADAPT, SKIP or
MONITOR with file-level evidence in the log; adopt on a branch oldest first;
rewrite `#NNNN` to `carverauto/serviceradar#NNNN` in picked messages; run the
per-area validation; `--advance` to the tip SHA the listing printed; commit
`.upstream-review/`; push only when asked, with an explicit refspec.

Per-area validation names only commands that run on the fork. `make check`
does not: `scripts/check.sh` uses `bazel --config=ci`, and `.bazelrc` points
that config at upstream's in-cluster remote cache.

Not decided yet, so not in the skill: how to treat upstream `VERSION` and
`CHANGELOG` bumps, and dependency-only PRs. ai-kb has rules for both; this
fork has no versioning or dependency divergence yet. They go into
`references/deviations.md` when the owner decides.

## Non-goals

Periodic wholesale merges of upstream. Automating `gh repo set-default` (one
manual command, documented). Any rebrand tooling (later task). Replacing CI
(separate session).
