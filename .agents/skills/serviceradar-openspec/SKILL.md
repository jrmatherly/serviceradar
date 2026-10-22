---
name: serviceradar-openspec
description: The one OpenSpec trap the generic OpenSpec guide does not cover, that a pending change's delta silently restores a requirement you amended in specs/. Use whenever editing, removing or rewording a requirement under `openspec/specs/` or `openspec/changes/`, before the edit, not after archiving.
user-invocable: false
metadata:
  internal: true
---

# ServiceRadar OpenSpec Rules

The proposal, spec and archive workflow is in [openspec/AGENTS.md](../../../openspec/AGENTS.md);
the SHALL/MUST positional rule and examples are under its
[Requirement Wording](../../../openspec/AGENTS.md#requirement-wording) section.

**Editing a requirement in `openspec/specs/` is not enough.** A pending change
under `openspec/changes/` may carry its own `## MODIFIED Requirements` copy of
the same `### Requirement:` block, and archiving that change replays its copy
over `specs/` -- silently restoring the wording you just removed, with nothing
in the archive step to flag the conflict. Before amending a requirement, run
`grep -rn "<the exact bullet>" openspec/` and fix every pending delta that
repeats it. Leave the copies under `openspec/changes/archive/` alone: they
record what was true at the time, and rewriting them falsifies the record.
