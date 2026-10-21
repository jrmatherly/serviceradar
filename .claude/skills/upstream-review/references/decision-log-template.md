# Decision log template

File: `.upstream-review/reviews/<YYYY-MM-DD>-review.md`. One log per review
window; the window's tip SHA is what `--advance` receives afterwards.

```markdown
# Upstream review - <YYYY-MM-DD>

Window: `<from-short>..<full tip sha>` on carverauto/staging, N PRs (M direct commits).
Driver output: `--stat`.

## Headline
One paragraph: what to adopt now, what to port, what to skip.

## Verdicts
| # | PR | Area | Our state | Markers | Verdict | Evidence |
|---|----|------|-----------|---------|---------|----------|
| 1 | #5877 feat/wasm-plugin-rollout-trigger | plugins | ABSENT | all `=`/`+` | ADOPT | 12 files, no `~` |

## Adopted
Cherry-picked SHAs in order, one line each with the upstream PR number, then
the validation result per area (command and outcome).

## Skipped or monitored
One line per PR with the reason, so the next review does not re-read it.
```

Our state values: ALREADY-HAVE, ABSENT, DIVERGED, PARTIAL. Verdicts: ADOPT,
ADAPT, SKIP, MONITOR. Rewrite upstream `#NNNN` references as
`carverauto/serviceradar#NNNN` everywhere in the log.
