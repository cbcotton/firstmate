#!/usr/bin/env bash
# Live driver: real fm-captain-hold.sh / tasks-axi / fm-teardown.sh against a disposable lab home.
set -u
ROOT=$1; MODE=${2:-target}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/stubbin" "$LAB/user"
for t in treehouse no-mistakes gh gh-axi orca; do printf '#!/bin/sh\nexit 0\n' > "$LAB/stubbin/$t"; chmod +x "$LAB/stubbin/$t"; done
cat > "$LAB/data/backlog.md" <<'B'
## In flight

## Queued

## Done
B
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" HOME_REAL=$HOME
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export PATH="$LAB/stubbin:$PATH"
cap() { "$ROOT/bin/fm-captain-hold.sh" "$@"; }
ta() { (cd "$LAB" && tasks-axi "$@"); }
meta() { # id [extra]
  { echo "window=firstmate:fm-$1"; echo "worktree=$LAB/projects/missing-$1"; echo "project=$LAB/projects/sample"
    echo "harness=codex"; echo "kind=scout"; echo "mode=scout"; echo "spawn_gen=lab-$1"; shift; for x in "$@"; do echo "$x"; done; } > "$LAB/state/$id.meta"; }
origin() { id=$1; mkdir -p "$LAB/data/$id"; ta add "$id" "Investigate $id" --kind scout --repo sample --start >/dev/null; meta "$id"
  printf 'done: report complete\n' > "$LAB/state/$id.status"; printf '# Report\n\nOne captain choice remains.\n' > "$LAB/data/$id/report.md"; }
push_out() { ta add "$1" "Later finished work" --kind ship --repo sample >/dev/null; ta done "$1" >/dev/null; }
step() { echo; echo "\$ $*"; "$@"; echo "[exit $?]"; }
retention() { printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' "$@" 'done_keep = 1' > "$LAB/.tasks.toml"; }

echo "=== S1: answered call archived -> verify, complete --none, teardown ==="
retention 'archive = "data/done-archive.md"'
id=lab-archive-review; call=lab-archive-call; origin $id
cap hold $call --title "Choose the archive path" --reason "captain choice pending" --repo sample --origin $id >/dev/null
cap complete $id $call >/dev/null
printf 'Take the first path.\n' > "$LAB/answer.txt"
cap answer $call --decision-file "$LAB/answer.txt" >/dev/null
push_out lab-later-1
echo "--- archive row for $call:"; grep -n -A12 "\] $call " "$LAB/data/done-archive.md"
echo "--- live show:"; ta show $call 2>&1 | head -3
echo "--- meta:"; cat "$LAB/state/$id.meta"
step cap verify $id
step cap complete $id --none
step "$ROOT/bin/fm-teardown.sh" $id
echo "--- state after teardown:"; ls "$LAB/state" | grep "$id" || echo "(no state files left for $id)"

echo; echo "=== S2: archived row WITHOUT resolution block still refuses ==="
id=lab-plain-scout; push_out lab-plain-row; push_out lab-later-2
grep -n "lab-plain-row" "$LAB/data/done-archive.md"
mkdir -p "$LAB/data/$id"; meta $id decisions_reviewed=1 decision_keys=lab-plain-row
printf 'done: report complete\n' > "$LAB/state/$id.status"; printf '# Report\n' > "$LAB/data/$id/report.md"
step cap verify $id
step "$ROOT/bin/fm-teardown.sh" $id

echo; echo "=== S3: entry in neither backlog nor archive still refuses ==="
id=lab-missing-scout; mkdir -p "$LAB/data/$id"; meta $id decisions_reviewed=1 decision_keys=lab-never-existed
printf 'done: report complete\n' > "$LAB/state/$id.status"; printf '# Report\n' > "$LAB/data/$id/report.md"
step cap verify $id

echo; echo "=== S4: archive path only in \$HOME/.tasks-axi/config.toml ==="
retention
mkdir -p "$LAB/user/.tasks-axi"; printf '%s\n' '[markdown]' 'archive = "data/answered-calls.md"' > "$LAB/user/.tasks-axi/config.toml"
export HOME="$LAB/user"
id=lab-user-scout; call=lab-user-call; origin $id
cap hold $call --title "Choose" --reason "pending" --repo sample --origin $id >/dev/null
cap answer $call --decision-file "$LAB/answer.txt" >/dev/null
push_out lab-later-3
grep -n "Resolution mode: answered" "$LAB/data/answered-calls.md"
meta $id decisions_reviewed=1 decision_keys=$call
step cap verify $id
export HOME=$HOME_REAL

echo; echo "=== S5: legacy derived identity <origin>-decision-<key> archived ==="
retention 'archive = "data/done-archive.md"'
id=lab-legacy; call=$id-decision-choice; origin $id
cap hold $call --title "Choose" --reason "pending" --repo sample --origin $id >/dev/null
cap answer $call --decision-file "$LAB/answer.txt" >/dev/null
push_out lab-later-4
grep -n "\] $call " "$LAB/data/done-archive.md"
meta $id decisions_reviewed=1 decision_keys=choice
step cap verify $id

echo; echo "=== S6: keyed decide loop unchanged for archived key (resolve_entry untouched) ==="
step cap open lab-archive-review
rm -rf "$LAB"; echo; echo "lab removed: $( [ -e "$LAB" ] && echo no || echo yes)"
