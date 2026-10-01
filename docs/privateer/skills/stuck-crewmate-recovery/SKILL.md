---
name: stuck-crewmate-recovery
description: Load when a worker is blocked, waiting too long, looping, confused, asking what its instructions already answer, or ignoring a message, and when session start reports a worker's window missing or dead.
---

# A worker is stuck

Every worker in this home runs in a window of this session, in its own copy of the project.
`bin/fm-control.sh` interrupts, stops, and relaunches a worker; it never deletes work.

## Look first

1. Run `bin/fm-crew-state.sh <id>` for the current state.
2. Run `bin/fm-peek.sh <id>` to see the worker's screen.
3. Run `ls "$FM_HOME/state/<id>.inbox"`; a `.msg` file there is a message the worker has not read yet.

If the task's work has already landed, this is not a recovery: clean it up with `bin/fm-teardown.sh <id>`.

## Then act, in this order, and stop at the first step that works

1. **It asks what its instructions already answer.**
   Answer in one line: `bin/fm-send.sh <id> '<answer>'`.
2. **It is confused or looping.**
   Interrupt it with `bin/fm-control.sh <id> interrupt`, then send one corrective line: `bin/fm-send.sh <id> '<what to do instead>'`.
3. **It is wedged**: still looping after that, unresponsive, repeating the same obstacle, or dead.
   Relaunch it in the same copy: `bin/fm-control.sh <id> relaunch --note '<what it has done so far and what comes next>'`.
   Its copy and commits stay, and the new worker gets the same instructions plus your note, on the same sailor and model.
   If the relaunch is refused because the sailor is busy or down, load `privateer-sailors`.
4. **A second relaunch fails too.**
   Leave the task and its copy as they are.
   Tell the captain what the worker was doing, that its work is kept, and what you recommend.
   Hold the task for that choice: `bin/fm-captain-hold.sh hold <id> --reason 'worker failed twice; retry, change the ask, or drop it?'`.

A worker whose context is filling up is not wedged; it compacts and keeps going.

## Session start reports a worker's window missing or dead

1. Run `bin/fm-crew-state.sh <id>`.
2. Relaunch it in its copy: `bin/fm-control.sh <id> relaunch --note '<progress from its status and report>'`.
3. If the relaunch refuses, change nothing: tell the captain the task, the refusal, and that its copy is kept.

## Never

- Never start a second worker for a task that still has a copy; one task gets one copy.
- Never clean up, or pass `--force`, to get past a stuck worker.
- Never type into a worker's window with tmux; use `bin/fm-send.sh` and `bin/fm-control.sh`.
