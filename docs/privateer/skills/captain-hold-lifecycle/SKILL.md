---
name: captain-hold-lifecycle
description: Load before you hold, answer, release, or close a captain decision, before you treat a scout's report as complete, and when the wake drain prints a RECORD DIVERGENCE line.
---

# Captain decisions

A decision is a backlog task held for the captain.
Its id is the task id; `bin/fm-captain-hold.sh` does the bookkeeping, and you judge what is a real decision.

## What to hold

- Hold only a question that belongs to the captain: a product choice, a design pick, a landing approval, or anything destructive or irreversible.
- A finding that needs no choice, a recommendation, or text that only sounds like a question is not a decision.
- Hold the task the question blocks; create a new task only when no task exists for it.
- Keep one held task per decision; a report with several questions is one held task whose reason points at the report.

## Hold

Run `bin/fm-captain-hold.sh hold <id> --reason '<question; option A; option B>'`.
To create a task for a question that has none, add `--title '<title>'`.
Holding the same task again is safe.

## Record the captain's answer

1. Write the captain's exact words to a file: `printf '%s\n' '<the words the captain gave>' > "$FM_HOME/data/<id>/decision.txt"`.
2. For a question, record and close it: `bin/fm-captain-hold.sh answer <id> --decision-file "$FM_HOME/data/<id>/decision.txt"`.
3. For an approval that lets work go ahead, such as landing, add `--release` to that command: it frees the task without closing it, and cleanup closes it after the work lands.
4. When the answer changes what a worker must build, append the captain's words to `## Captain's intent` in `$FM_HOME/data/<id>/brief.md` and send them with `bin/fm-send.sh <id> '<the words the captain gave>'`.

When the captain says "later", hold it again with a date: `bin/fm-captain-hold.sh hold <id> --reason '<reason>' --until <YYYY-MM-DD>`.
When a worker's `needs-decision` line carried `[key=<key>]`, `bin/fm-send.sh <id> --resolve-key <key> '<answer>'` answers the worker and closes that decision in one step.

## Never

- Never close a held task without the captain's words: a finished scout, a cleanup, or an archived report is not an answer.
- Never close a held task with a backlog command; only `answer` records what the captain said.
- Never say "hold" to the captain; ask the question itself, with its options.

## Scout reports

The scout attests its own report before it reports done.
When you read a report and find a question for the captain that the scout did not hold, hold it, then run `bin/fm-captain-hold.sh complete <id> <held-id>` with the scout's id and every held task id.

## RECORD DIVERGENCE

A `RECORD DIVERGENCE` line means two records of one decision disagree; it never means the captain ruled.
If the captain's words for it exist in this session, record them with `answer`.
Otherwise tell the captain which decision is open and ask for the answer again.
