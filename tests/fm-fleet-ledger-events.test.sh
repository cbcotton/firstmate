#!/usr/bin/env bash
# Behavior tests for the fleet activity ledger's new event types: task.validation,
# task.pr_ready with risk, and task.decided.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-fleet-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-ledger-events)
FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/projects" "$FM_HOME/config"
export FM_HOME

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck disable=SC2317
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# Turn the ledger on
: > "$FM_HOME/config/fleet-ledger"

# Test 1: task.validation event is recorded
bash "$LEDGER" validation val-task review running
sleep 0.05
bash "$LEDGER" capture
line=$(grep '"task.validation"' "$FM_HOME/state/fleet-ledger.jsonl" | head -1)
step=$(echo "$line" | jq -r '.step // "MISSING"' 2>/dev/null)
outcome=$(echo "$line" | jq -r '.outcome // "MISSING"' 2>/dev/null)
if [ "$step" = "review" ] && [ "$outcome" = "running" ]; then
  pass "validation event recorded correctly"
else
  fail "step=$step outcome=$outcome"
fi

# Test 2: task.pr_ready with risk event is recorded
bash "$LEDGER" pr_ready_risk risk-task "https://github.com/acme/app/pull/42" "medium" "auth,middleware"
sleep 0.05
bash "$LEDGER" capture
line=$(grep '"task.pr_ready"' "$FM_HOME/state/fleet-ledger.jsonl" | grep 'risk-task' | head -1)
risk=$(echo "$line" | jq -r '.risk // "MISSING"' 2>/dev/null)
touches=$(echo "$line" | jq -r '.touches // "MISSING"' 2>/dev/null)
if [ "$risk" = "medium" ] && [ "$touches" = "auth,middleware" ]; then
  pass "pr_ready risk event recorded correctly"
else
  fail "risk=$risk touches=$touches"
fi

# Test 3: task.decided event is recorded
bash "$LEDGER" decided decide-task "go with option A"
sleep 0.05
bash "$LEDGER" capture
line=$(grep '"task.decided"' "$FM_HOME/state/fleet-ledger.jsonl" | head -1)
answer=$(echo "$line" | jq -r '.answer // "MISSING"' 2>/dev/null)
if [ "$answer" = "go with option A" ]; then
  pass "decided event recorded correctly"
else
  fail "answer=$answer"
fi

echo "---"
echo "fm-fleet-ledger new event types complete"
