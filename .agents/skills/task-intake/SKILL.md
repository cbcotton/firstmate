---
name: task-intake
description: >-
  Load before classifying or routing a captain request, writing a crewmate brief, dispatching a ship or scout, or writing a backlog item note.
  Owns project resolution, secondmate routing, ship-or-scout classification, concurrency, brief filling, and backlog-note hygiene.
user-invocable: false
metadata:
  internal: true
---

# task-intake

This skill is the single owner of Firstmate's intake procedure: resolving the project, routing to a secondmate, classifying the deliverable, deciding concurrency, filling the brief, and keeping backlog item notes healthy.
`AGENTS.md` section 7 keeps its load trigger and the always-loaded authority lines: never reading a secondmate's chat, that a diagnostic report is evidence rather than authorization, delivery-posture resolution through `project-management`, isolated spawning, steering, permission decisions, and mid-task captain asks.
`AGENTS.md` section 11 keeps the brief safety lines: the worktree-isolation assertion, the `--herdr-lab` scaffold, and charter briefs.

## Resolve the project

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.
For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.

## Route to a secondmate

Route by the nature of the work against each registered secondmate scope, not by a non-exclusive clone list; a scope drives routing, while a secondmate's project list is non-exclusive provisioning data, not ownership.
Keep `local-only` work in the main home.
Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it; marked routed replies return through its status or a referenced document, never its chat.
If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.

## Classify the deliverable

Before commissioning an investigation, consult existing reports and established evidence.
Classify the deliverable:

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.

If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.

## Concurrency

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.

## Fill the brief

Write the task-specific brief before spawning.
`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics; use its scaffold as the contract.
Fill `## Captain's intent` (`{TASK}`) with the captain's own ask and any boundary the captain stated, plus the context needed to read it, including the substance of any report, decision, or PR the ask refers to; never widen the ask there into a general goal or an enumerated coverage list, because the reviewer treats that subsection as acceptance criteria.
Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with only the build instructions that ask requires, naming what stays out of scope when the ask is narrow; a generalization, consistency sweep, or extra hardening the captain did not ask for is follow-up work to note, not scope to add.
`bin/fm-dod-lib.sh` owns intent authoring without added speaker labels or direct address, its provenance markers, what a no-mistakes worker may pass as `--intent`, and the string's self-sufficiency rule.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.
If a ship task touches firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.

## Backlog item notes

Record each ship task's delivery posture in its note as `project-management` directs.
Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge to `AGENTS.md` section 6 rather than scattering it through task notes.
