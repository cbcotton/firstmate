#!/usr/bin/env bash
# Behavior tests for the decision card feature of the captain-hold workflow.
# Decision cards carry the options, hints, and recommendation the firstmate
# authored for a held task. They are stored alongside the held task and
# retrieved through the snapshot.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPTAIN_HOLD="$ROOT/bin/fm-captain-hold.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-card)
FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/projects" "$FM_HOME/config"
export FM_HOME

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck disable=SC2317
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# An idle ship task with an open needs-decision, so the snapshot lists it with
# pending_decision true.
make_held_task() {  # <task-id>
  local id=$1 gen
  mkdir -p "$FM_HOME/projects/$id"
  fm_write_meta "$FM_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$FM_HOME/projects/$id" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$FM_HOME/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$FM_HOME/state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'needs-decision [at=1727500000] [key=%s]: how should we proceed?\n' "$id" > "$FM_HOME/state/$id.status"
}

# The task's snapshot entry as compact JSON, or empty when it is not listed.
snapshot_task() {  # <task-id>
  bash "$SNAPSHOT" --json 2>/dev/null | jq -c --arg id "$1" '.tasks[] | select(.id == $id)'
}

# Test 1: Decision card can be created and retrieved
card_json='{"options":["option A","option B"],"hints":"use option A for simplicity","recommend_value":"option A"}'
bash "$CAPTAIN_HOLD" card card-task set "$card_json"
retrieved=$(bash "$CAPTAIN_HOLD" card card-task show)
recomm=$(echo "$retrieved" | jq -r '.recommend_value // "MISSING"' 2>/dev/null)
if [ "$recomm" = "option A" ]; then
  pass "decision card created and retrieved"
else
  fail "recommend_value=$recomm"
fi

# Test 2: Decision card is cleared correctly
bash "$CAPTAIN_HOLD" card card-task2 set '{"options":["A"]}'
bash "$CAPTAIN_HOLD" card card-task2 clear
retrieved=$(bash "$CAPTAIN_HOLD" card card-task2 show)
if [ "$retrieved" = "null" ]; then
  pass "decision card cleared"
else
  fail "expected null, got $retrieved"
fi

# Test 3: set refuses anything but one JSON object and keeps the stored card
bash "$CAPTAIN_HOLD" card guarded set '{"options":["keep"]}'
for bad in 'not json' '["a","b"]' '"text"' '{"a":1} {"b":2}' ''; do
  rc=0
  bash "$CAPTAIN_HOLD" card guarded set "$bad" 2>/dev/null || rc=$?
  expect_code 2 "$rc" "card set of '$bad'"
done
assert_equals '["keep"]' "$(bash "$CAPTAIN_HOLD" card guarded show | jq -c '.options')" \
  "a refused card set left the stored card unchanged"
pass "card set refuses input that is not one JSON object and keeps the stored card"

# Test 4: Snapshot includes decision cards for held tasks with pending decisions,
# and the served card comes from the stored one: without a card it is null.
make_held_task snap-card
entry=$(snapshot_task snap-card)
[ -n "$entry" ] || fail "held task snap-card is missing from the snapshot"
assert_equals true "$(printf '%s' "$entry" | jq -c '.hints.pending_decision')" "snap-card pending_decision"
assert_equals null "$(printf '%s' "$entry" | jq -c '.hints.decision_card')" "snap-card card before one is set"
bash "$CAPTAIN_HOLD" card snap-card set '{"options":["approve","reject"],"recommend_value":"approve"}'
recomm=$(snapshot_task snap-card | jq -r '.hints.decision_card.recommend_value // "MISSING"')
if [ "$recomm" = "approve" ]; then
  pass "snapshot includes decision card"
else
  fail "recomm=$recomm"
fi

# Test 5: A malformed card file on disk (one written before set validated its
# input, or by hand) never drops its held task from the snapshot; the card is
# served as null instead.
make_held_task bad-card
make_held_task good-neighbor
bash "$CAPTAIN_HOLD" card good-neighbor set '{"recommend_value":"ship"}'
for bad in 'not json' '["a"]' '{"a":1} {"b":2}' ''; do
  printf '%s\n' "$bad" > "$FM_HOME/state/bad-card.decision-card.json"
  entry=$(snapshot_task bad-card)
  [ -n "$entry" ] || fail "a malformed card ('$bad') dropped held task bad-card from the snapshot"
  assert_equals true "$(printf '%s' "$entry" | jq -c '.hints.pending_decision')" "bad-card pending_decision with card '$bad'"
  assert_equals null "$(printf '%s' "$entry" | jq -c '.hints.decision_card')" "bad-card served card with card '$bad'"
  assert_equals ship "$(snapshot_task good-neighbor | jq -r '.hints.decision_card.recommend_value')" \
    "a neighbour's valid card beside malformed card '$bad'"
done
pass "a malformed card is served as null and its held task stays in the snapshot"

echo "---"
echo "fm-captain-hold decision cards complete"
