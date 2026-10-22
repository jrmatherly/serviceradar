# Upstream provenance and review

- This repo is a GitHub fork of `carverauto/serviceradar` (`gh api` says `fork: true`, parent `carverauto/serviceradar`); default branch `staging` on both. Fork point: `5993ec10432ccbddaeffb5fe3416ba7d261bede7` (2026-10-21, "Merge pull request #5874"). Shared history, so ranges, merge-base and `git cherry-pick -x` work.
- The fork deviates on purpose and adopts upstream PRs one at a time (owner decision 2026-10-21). Never merge `carverauto/staging`.
- Upstream remote is named `carverauto`, never `upstream` (`gh` would default PRs to the parent). Run `gh repo set-default jrmatherly/serviceradar` once per clone.
- Upstream merges every PR with a merge commit; one `--first-parent` entry is one PR. Adoption unit: the PR's inner commits, cherry-picked oldest first with `-x`. Upstream subjects use `type(scope):` plus a `no-mistakes(scope):` house prefix; keep them.
- git's `--cherry-pick` dedup does not detect an adopted PR (tested 2026-10-21 on PR #5877 three ways), so the explicit watermark plus decision log is required.
- Review workflow = `upstream-review` skill: `.claude/skills/upstream-review/SKILL.md` + `scripts/upstream-review.sh` (bats tests in `tests/`). Tracked state: `.upstream-review/watermark.json` (`forkPointSha` fixed, `lastReviewedSha` advances only via `--advance <tip-sha>`) and `.upstream-review/reviews/<date>-review.md`.
- `--stat` markers vs each commit's pre-image, fork point as fallback: `=` clean pick, `<` older entry first, `~` we changed it, `x` we removed it, `+` new, `bin`.
- Decided deviations and open decisions: `.claude/skills/upstream-review/references/deviations.md`. Open as of 2026-10-21: upstream VERSION/CHANGELOG/dependency bumps. Planned: own CI in `.github/` (PR jrmatherly/serviceradar#1), rebrand (mapper to adapt from ai-kb `scripts/rebrand/`).
- `make check` and `make test` cannot run on the fork (Bazel `--config=ci` / `--config=remote` use upstream's cache and BuildBuddy executor); `references/validation.md` lists what can.
- Design record: `docs/superpowers/specs/2026-10-21-upstream-review-skill.md`; plan: `docs/superpowers/plans/2026-10-21-upstream-review-skill.md`.
