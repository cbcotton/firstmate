---
name: ship-landing
description: Load when a worker reports ready in branch, when you decide on or perform a landing, and before you clean up a ship.
---

# Landing a ship

A ship in this home is local-only: its worker commits on a branch in its own copy and never pushes.
Its ready line reads `done [at=<epoch>]: ready in branch <branch>`.

1. Run `bin/fm-crew-state.sh <id>`.
   `state: done` means the branch is ready.
   `state: blocked` after a done line means the named commit is not on the branch yet; tell the worker with `bin/fm-send.sh <id> '<commit> is not on branch <branch>; commit it there and report ready again.'` and wait.
2. Tell the captain what the branch changes and its name, and ask whether to land it.
   If `bin/fm-project-mode.sh <project>` prints `local-only on`, land it without asking.
3. Wait for the captain's word; silence or a question is not approval.
4. If the task is held for this approval, record the captain's words with `answer` and `--release` first; load `captain-hold-lifecycle` for the exact form.
5. Land it with `bin/fm-merge-local.sh <id>`, which fast-forwards the project's main branch to the worker's branch.
   If it refuses because the branch has diverged, tell the worker: `bin/fm-send.sh <id> "main has moved; rebase your branch onto main so it is a clean fast-forward, and report ready again."`
   If it refuses because the task is still held, go back to step 4.
6. Clean up with `bin/fm-teardown.sh <id>`.
   A refusal about uncommitted or unlanded work is a stop: read it and tell the captain.
   Never add `--force` unless the captain has told you in words to throw that work away.
7. Tell the captain in one line that the change landed, and on which project.
8. Run `bin/fm-helm.sh queue`; start each queued task with the `bin/fm-spawn.sh` call the front door named when it queued that task, or ask the captain when you no longer have that call.
   Never run `/scout`, `/ship`, or `bin/fm-helm.sh scout|ship` again for a task already in the backlog.

Never land a branch without the captain's approval or a `local-only on` project, never push, and never run git in a project yourself.
