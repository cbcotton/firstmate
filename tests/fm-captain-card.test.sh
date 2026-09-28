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

# Test 3: Snapshot includes decision cards for held tasks with pending decisions
printf 'needs-decision [at=1727500000] [key=snap-card]: how should we proceed?\n' > "$FM_HOME/state/snap-card.status"
bash "$CAPTAIN_HOLD" card snap-card set '{"options":["approve","reject"],"recommend_value":"approve"}'
output=$(bash "$SNAPSHOT" --json 2>/dev/null)
card=$(echo "$output" | jq -r '.tasks[] | select(.id=="snap-card") | .hints.decision_card' 2>/dev/null)
recomm=$(echo "$card" | jq -r '.recommend_value // "MISSING"' 2>/dev/null)
if [ "$recomm" = "approve" ]; then
  pass "snapshot includes decision card"
else
  fail "recomm=$recomm"
fi

echo "---"
echo "fm-captain-hold decision cards complete"
