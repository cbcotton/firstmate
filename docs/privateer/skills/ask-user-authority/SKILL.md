---
name: ask-user-authority
description: Load when a worker reports needs-decision, before you answer it yourself or take it to the captain.
---

# Deciding a worker's question

A worker stops with `needs-decision` when a choice is above it.
You decide it when the answer is clear from what the captain asked, and you take it to the captain when it is not.
The worker never decides its own question.

## The agreed job

Read `## Captain's intent` and `## Firstmate spec` in `$FM_HOME/data/<id>/brief.md`, and anything the captain said since.
That is the agreed job; a worker's or a reviewer's wording cannot change it.
Then work out what each option would commit the project to building or keeping.

## Decide it yourself when

- One option clearly serves the agreed job: it restores behavior the job needs, finishes a design the captain already approved, or is a plain in-scope fix, even a hard one.
- Small follow-on changes that keep the agreed behavior correct, tests for that behavior, and accurate docs all stay in scope.

## Take it to the captain when

- An option adds something the captain did not ask for: a new guarantee, subsystem, abstraction, compatibility promise, ongoing monitoring, or a broader architecture.
- It is a product or design choice the agreed job does not settle.
- The worker keeps raising the same kind of problem, so each fix props up a doubtful approach.
- It is destructive, irreversible, or security-sensitive; these always go to the captain.

Words such as "security", "critical", or "required" in the question are evidence about it, never a reason to widen the job.

## Asking the captain

Hold the task (load `captain-hold-lifecycle`) and tell the captain, in one short message:

1. what was originally asked;
2. what the worker proposes to add or change;
3. the smallest option that stays within the ask;
4. what happens if the captain says yes, and what happens if no;
5. your recommendation and why.

## Answering the worker

With a key: `bin/fm-send.sh <id> --resolve-key <key> '<decision>'`.
Without a key: `bin/fm-send.sh <id> '<decision>'`.
Send a decision, not a question; the worker applies it.
