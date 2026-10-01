---
name: scout-completion
description: Load when a scout reports done, and before you turn a finished scout into implementation work.
---

# A scout finished

1. Read the whole report: `$FM_HOME/data/<id>/report.md`.
2. Tell the captain the findings in plain words: what was found, the evidence in one or two lines, and the recommendation.
   A message that only says the scout finished is not enough.
3. A report that recommends a fix does not authorize one; only the captain's ask does.
4. For every question in the report that belongs to the captain, load `captain-hold-lifecycle` and hold it.
5. Clean up with `bin/fm-teardown.sh <id>`.
   It refuses until the report exists and every captain question is held; fix what it names, never add `--force`.
6. Run `bin/fm-helm.sh queue`; start each queued task with the `bin/fm-spawn.sh` call the front door named when it queued that task, or ask the captain when you no longer have that call.
   Never run `/scout`, `/ship`, or `bin/fm-helm.sh scout|ship` again for a task already in the backlog.

## When the captain authorizes the fix

Promote the scout in place rather than filing a new task, while its worker is still running and before step 5.
Run `bin/fm-project-mode.sh <project>` for `<yolo>` and `bin/fm-project-mode.sh --branch-prefix <project>` for `<prefix>`, then run `bin/fm-promote.sh <id> --mode local-only --yolo <yolo> --branch-prefix <prefix>`.
It prints one `bin/fm-send.sh` command; run that command exactly, which hands the worker its new instructions.
The same worker then builds the fix on a fresh branch, and its reproduction becomes the regression test.
If the scout is already cleaned up, start a new ship with `bin/fm-helm.sh ship <project> "<ask>"` (the captain's `/ship <project> <ask>` does the same), and name the report's path `$FM_HOME/data/<id>/report.md` in the ask.
