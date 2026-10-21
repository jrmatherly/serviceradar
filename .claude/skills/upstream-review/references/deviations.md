# Deviations from upstream

A row per decided deviation. An upstream hunk that conflicts with a landed row
keeps ours; a `planned` row warns that the conflict is coming; an `open` row
means ask the owner before adopting the PR.

| Upstream | Ours | Status | Notes |
| --- | --- | --- | --- |
| `.github/` workflows that publish images, charts, npm and releases with carverauto secrets | our own CI: lint and test workflows only | planned (session "Replace upstream CI workflows with the fork's own", PR jrmatherly/serviceradar#1) | upstream workflow changes are read for new validation commands and hand-ported into our workflows and `validation.md`; never cherry-picked |
| carverauto names: module `github.com/carverauto/serviceradar`, images `ghcr.io/carverauto/*`, product name | rebrand | planned | the mapper is to be adapted from ai-kb `scripts/rebrand/` (`map.tsv`, `apply.sh`, `check.sh`, `check-repo.sh`); until it exists the rebrand step in SKILL.md is a no-op |
| upstream `VERSION`, `CHANGELOG` and dependency-only bumps | undecided | open | ai-kb skips version bumps and takes dependency versions, never hunks; the owner decides for this fork |

## Deleted or moved paths

An `x` marker means we removed the path, not always that the change is
irrelevant. Add a line here for every path we remove, with where the content
went or why it is gone.
