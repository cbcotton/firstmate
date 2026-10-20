---
name: privateer-sailors
description: Load when bin/fm-sailor.sh check, bin/fm-sailor.sh pick, or bin/fm-spawn.sh refuses a sailor, when a worker stops because its model server is down or busy, and when the captain asks which sailors can take work.
---

# Sailors

A sailor is a model server, local or external, listed under `sailors` in `$FM_HOME/config/crew-dispatch.json`.
Every worker runs on one sailor and one of its models; nothing here ever falls back to a model outside that list.
You only read the sailor list: the captain adds, changes, and retires sailors from outside this session.
The captain may rebind a sailor to another model from outside this session, for example in MLX Serve, so its model can change between tasks; read the list again before choosing.

## See the sailors

- `bin/fm-sailor.sh status` shows each live sailor: whether it answers, its tasks against its capacity, its grade when it has one, and which models are loaded.
- `bin/fm-sailor.sh list` shows every sailor with its endpoint, capacity, grade when it has one, and models.

## The candidates for a task

The rule you matched, or `default`, has a `use` entry: one profile or a list of profiles.
A profile names a `sailor`, sometimes with a `model`, or a `grade`.
The grades, lowest to highest, are `deckhand`, `sailor`, `specialist`, `expert`; a grade profile takes any sailor of that grade or higher.
Try them in the order listed, and run `bin/fm-sailor.sh pick --sailor <sailor> --model <model>`, without `--model` when the profile names none, or `bin/fm-sailor.sh pick --grade <grade>` for each until one prints a sailor and a model.
Spawn on that one, with that exact sailor and model.
Add `--spend` to both `pick` and `bin/fm-spawn.sh` only when the rule says `"spend": "allowed"` or the captain okayed a paid sailor for this one task.

## What each refusal means

| `refused:` says | Meaning | What to do |
| --- | --- | --- |
| `unknown sailor` or `is not listed for sailor` | You read the file wrong | Read the file again and use a sailor and model it lists |
| `is a placeholder` | The captain has not switched it on | Skip it; never spawn on it |
| `is at capacity` | It already runs as many tasks as it may | Try the next candidate; it frees up when one of its tasks is cleaned up |
| `has no token` | The captain has not set the token variable it names | Try the next candidate, and tell the captain which variable that sailor needs in `$FM_HOME/.env` |
| `is not answering` | Its server is down or unreachable | Try the next candidate |
| `does not serve` | The server runs but lacks that model | Try the next candidate |
| `did not answer a one-token request` | The server lists the model but failed a tiny test request; the server's own error follows the last colon | Try the next candidate, and tell the captain that sailor's error |
| `has no grade` or `below` | It is weaker than the task's grade | Try the next candidate |
| `is paid` | It costs money per request | Skip it; only the captain's okay for this task, or a rule allowing spend, adds `--spend` |
| `lists several models` | The profile must name a model | Read the file again and add `--model` |

## When no candidate is free

1. Do not spawn: the task stays in the queue, which is correct.
2. Tell the captain in one line which sailors are busy or down and that the task waits for one.
3. After each cleanup, run `bin/fm-helm.sh queue`, then start the task with the `bin/fm-spawn.sh` call the front door named when it queued it, or ask the captain when you no longer have that call.
   Never run `/scout`, `/ship`, or `bin/fm-helm.sh scout|ship` again for a task already in the backlog.

## A running worker's sailor stopped answering

The worker usually reports `blocked` or goes quiet.
A relaunch keeps the same sailor and model, so first run `bin/fm-sailor.sh check <sailor> <model> --task <id>`.
When it prints `ok:`, relaunch with `bin/fm-control.sh <id> relaunch --note '<progress so far>'`.
While it refuses, leave the worker alone and tell the captain which sailor is down.
There is no command to move a running worker to another sailor; if the captain wants that, say so.

## Never

- Never add `--harness` other than `opencode`, and never spawn without `--sailor`.
- Never edit `$FM_HOME/config/crew-dispatch.json`; it is read-only in this session.
- Never contact a sailor's server yourself with `curl` or any other tool; `bin/fm-sailor.sh` does that.
