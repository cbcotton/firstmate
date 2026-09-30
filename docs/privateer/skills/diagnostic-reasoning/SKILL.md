---
name: diagnostic-reasoning
description: Load before you write instructions for a reported bug, and before you act on a bug report a scout wrote.
---

# Diagnosing a bug

You never diagnose a project yourself; a scout does, and you ask for the right evidence and judge what comes back.

## What the scout's instructions ask for

Put these in `{FIRSTMATE_SPEC}` of a bug scout's brief:

1. A reproduction along the real user's path, run end to end; if that is not possible, the exact limit and the closest path, not presented as the same evidence.
2. The expected and the observed behavior, the setup, the inputs, and how often it happens.
3. Three facts kept apart:
   - the **trigger**: the event or input that starts the fault;
   - the **masking condition**: the state, timing, cache, or setting that hides or exposes it;
   - the **symptom**: what the user actually sees.
4. The failing path compared with a path where the same thing works, down to the first real difference.
5. Relevant history: the commits or changes that explain why the paths differ, not just the newest nearby change.
6. The smallest change that should flip the outcome if the explanation is right, tried one condition at a time.
7. The evidence that would disprove the explanation, whether it was checked, and what it showed.

## Judging the report

- Keep observed facts apart from guesses.
- Check that the stated cause explains both the failing reproduction and the working path, without leaning on an untested masking condition.
- If a load-bearing piece is missing, send a focused follow-up scout instead of trusting confident wording.
- A diagnosis, even one with a ready fix, is evidence, not permission to change code.
  A fix needs the captain's ask, and the reproduction then becomes its regression test.
