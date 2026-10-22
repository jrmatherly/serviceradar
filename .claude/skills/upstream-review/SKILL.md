---
name: upstream-review
description: Reviews what changed upstream in carverauto/serviceradar (staging) since the last review and decides which pull requests to adopt into this fork. Use for "sync from upstream", "what changed upstream", "review upstream PRs", "did carverauto update", "bring upstream PR N in", "check upstream for new features", or any periodic upstream check. Encodes the fork facts, the watermark driver, the per-file divergence markers and the adoption rules for this repo.
argument-hint: "[--stat | --urls | --show <sha> | --diverged | --advance <sha>]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh *) Bash(git show *) Bash(git log *) Bash(git diff *) Bash(git rev-parse *) Read Grep Glob
---

# Upstream review

This repo is a GitHub fork of `carverauto/serviceradar`, cut from `staging` at
`5993ec10432ccbddaeffb5fe3416ba7d261bede7` (2026-10-21). It shares history
with upstream, so ranges, `git merge-base` and `git cherry-pick -x` all work.
What it does not share is intent: the fork deviates on purpose and adopts
upstream pull requests one at a time. Never merge `carverauto/staging`.

- The upstream remote is named `carverauto`, never `upstream`: `gh` prefers a
  remote called `upstream` as its default repository, and PRs must target the
  fork. Run `gh repo set-default jrmatherly/serviceradar` once per clone.
- Upstream merges every PR with a merge commit, so one first-parent entry is
  one PR. The adoption unit is the PR's inner commits, cherry-picked oldest
  first with `-x`. No squash picks, no `-m 1` merge picks.
- Review state is tracked in git under `.upstream-review/`. A watermark
  advance without a decision log is a lost review.

## Tooling

| Piece | Path |
| --- | --- |
| Driver | `${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh` |
| Watermark (tracked) | `.upstream-review/watermark.json` (`forkPointSha` fixed, `lastReviewedSha` advances) |
| Decision logs (tracked) | `.upstream-review/reviews/<YYYY-MM-DD>-review.md` |
| Tests | `${CLAUDE_SKILL_DIR}/tests/` (`bats` on the directory) |

```bash
${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh            # fetch, list un-reviewed entries oldest first
${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh --stat     # + each PR's commits and each touched file with a marker
${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh --urls     # + github commit URL per entry
${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh --show <sha>      # a PR merge: commits + combined diff; else git show
${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh --diverged        # our footprint: files that differ from the fork point
${CLAUDE_SKILL_DIR}/scripts/upstream-review.sh --advance <tip-sha>  # after the log is written; the listing prints the tip SHA
```

The first run adds the `carverauto` remote with `--no-tags` and fetches
`staging`. Offline it uses the cached ref and says so. It refuses to run when
`lastReviewedSha` is no longer on `carverauto/staging` (history rewritten).

An entry line reads `* <short>  <date>  PR #<n> <branch>: <title>  [<k> commits]`;
a direct push to staging shows its subject instead. Markers in `--stat`
compare our HEAD with each commit's own parent (the pre-image a cherry-pick
merges from), falling back to the fork point:

| | Meaning | Adoption path |
| --- | --- | --- |
| `=` | ours equals the pre-image | `git cherry-pick -x <sha>` applies cleanly |
| `<` | ours equals the fork point, not the pre-image; or the file exists in neither | an older un-reviewed entry touched it first (pick in order, it becomes `=`), or the PR branch was cut before the fork point and a commit we already carry touched it (the 3-way pick usually applies; read the hunk) |
| `~` | ours differs from both | we changed it; resolve the 3-way or hand-port |
| `x` | we removed it | check "Deleted or moved paths" in `references/deviations.md` |
| `+` | new upstream file | cherry-pick creates it |
| `bin` | binary | inspect by hand |

## Method

1. Run `--stat`. Group entries by area, the conventional-commit scope upstream
   uses: `fix(plugins):`, `feat(web-ng):`, `docs:`, `ci:`, `no-mistakes(review):`.
2. For each entry, `--show <merge-sha>` and read the combined diff; drop to a
   single inner commit with `--show <sha>` when the PR mixes concerns.
3. Classify our state from the markers and the diff: ALREADY-HAVE, ABSENT,
   DIVERGED, PARTIAL.
4. Verdict per PR: `ADOPT` (all files `=`, `+`, or `<` with its predecessors
   adopted first), `ADAPT` (hand-port, some `~`), `SKIP`, `MONITOR`.
5. Write every verdict with file-level evidence to the dated decision log.
   Before writing, read `references/decision-log-template.md`.
6. Adopt in a batch on a branch: for each adopted PR, cherry-pick its inner
   commits oldest first with `-x`, skipping any commit `--stat` tagged
   `[merge: not picked]` (a merge of staging into the PR branch; its
   staging-side content arrives through earlier entries). If a pick after such
   a merge conflicts, or the merge is the last commit to touch a file, the
   upstream resolution lives only in that merge: read it with `--show <sha>`
   and resolve by hand. Then run the per-area commands in
   `references/validation.md` for every area the batch touched.
7. Then `--advance <tip-sha>` with the tip SHA from the listing you reviewed
   (a fresh fetch may have moved on) and commit `.upstream-review/` with the
   adopted commits. Push only when the user asks, with an explicit refspec:
   `git push origin <branch>:refs/heads/<branch>`.

For a large window (more than about 20 PRs), dispatch one reviewer subagent
per area with the SHAs, the marker output, and steps 2 to 5. Synthesize into
one log.

## Rules for this repo

- Keep `-x` on every cherry-pick so the log line "cherry picked from commit"
  carries provenance. Upstream `#NNNN` issue and PR numbers autolink to the
  wrong repo on GitHub; rewrite them to `carverauto/serviceradar#NNNN` in the
  picked commit message (`git commit --amend`) and in the decision log.
- Keep upstream's subject form, `type(scope): imperative subject`, including
  its `no-mistakes(scope):` prefix, so adopted commits read consistently.
- `.github/` and the other CI paths listed in `references/deviations.md` are
  ours: the fork runs its own CI. Upstream commits that touch them are never
  cherry-picked. Hand-port what matters per `docs/fork-ci.md`, run
  `scripts/ci/check-fork-ci.sh` (must exit 0), and port new validation
  commands into `references/validation.md`. Record the decision in the log.
- Rebrand step: when `scripts/rebrand/apply.sh` exists, run it on every file a
  pick touched and `scripts/rebrand/check-repo.sh` before validation. Until
  the rebrand lands this step is a no-op; `references/deviations.md` tracks it.
- Version, changelog and dependency-only PRs: ADOPT while they would ADOPT by
  the step 4 rule (every file `=`, `+`, or `<` with its predecessors adopted);
  at the first `~` the file is ours, so SKIP and take only the versions the PR
  names, never the hunk (the row in `references/deviations.md` has the commands).
- A deviation we decide gets a row in `references/deviations.md`; a path we
  remove gets a line under "Deleted or moved paths" there. Read that file
  before classifying any `~` or `x` file.

## Red flags

- `git merge carverauto/staging`, or any merge-base based range. Use the watermark.
- Cherry-picking a `~` file without reading our side first.
- Review state anywhere except `.upstream-review/`.
- Advancing the watermark to a SHA other than the tip printed by the listing you classified.
- A batch that lands with any area's validation failing.
- Pushing with a bare `git push`: `push.default=upstream` can redirect it to `staging`.

## Resources

- `scripts/upstream-review.sh`: the driver; run it, do not read it into context.
- `references/deviations.md`: decided deviations, open decisions, and deleted or moved paths. Read before classifying `~` or `x` files.
- `references/decision-log-template.md`: the shape of `.upstream-review/reviews/<date>-review.md`. Read before writing a log.
- `references/validation.md`: per-area commands a batch must pass, and what cannot run on the fork. Read at step 6.
