#!/usr/bin/env bash
# Behavior tests for the fleet activity ledger's validation, pr_ready risk and
# touches, and decided records through bin/fm-fleet-ledger.sh's own interface.
# tests/fm-fleet-ledger.test.sh drives the producers that call it.
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

rows() {  # <jq filter>
  jq -c "$1" "$FM_HOME/state/fleet-ledger.jsonl"
}

# Test 1: validation records each changed step outcome once per run
bash "$LEDGER" validation val-task 01RUNA review running tests running
bash "$LEDGER" validation val-task 01RUNA review running tests running
bash "$LEDGER" validation val-task 01RUNA review passed tests running
bash "$LEDGER" validation val-task 01RUNB review passed
assert_equals '["01RUNA","review","running"]
["01RUNA","tests","running"]
["01RUNA","review","passed"]
["01RUNB","review","passed"]' \
  "$(rows 'select(.event == "task.validation" and .task == "val-task") | [.run, .step, .outcome]')" \
  "validation rows"
pass "validation records a step outcome only when it changed for that run"

# Test 2: bad validation arguments are usage errors that record nothing
before=$(wc -l < "$FM_HOME/state/fleet-ledger.jsonl")
for args in "val-task 01RUNA review" "val-task 01RUNA" "val-task 01RUNA review running tests" \
  "val-task 01RUNA 'review x' running" "../x 01RUNA review running"; do
  rc=0
  eval "bash \"\$LEDGER\" validation $args" 2>/dev/null || rc=$?
  expect_code 2 "$rc" "validation $args"
done
assert_equals "$before" "$(wc -l < "$FM_HOME/state/fleet-ledger.jsonl")" "records after refused validation calls"
pass "validation refuses a missing outcome, an odd pair, a spaced word, and a bad task id"

# Test 3: pr_ready carries the risk and touches of the newest done line naming the PR
{
  printf 'working: PR https://github.com/acme/app/pull/42 risk=low touches=not a done line\n'
  printf 'done [at=1790000000]: PR https://github.com/acme/app/pull/42 checks green risk=medium touches=auth, middleware\n'
  printf 'done: PR https://github.com/acme/app/pull/43 checks green risk=high touches=another PR\n'
  printf 'done: PR https://github.com/acme/app/pull/44\n'
} > "$FM_HOME/state/risk-task.status"
bash "$LEDGER" pr_ready risk-task "https://github.com/acme/app/pull/42"
bash "$LEDGER" pr_ready risk-task "https://github.com/acme/app/pull/44"
bash "$LEDGER" pr_ready risk-task "https://github.com/acme/app/pull/45"
assert_equals '["https://github.com/acme/app/pull/42","medium","auth, middleware"]
["https://github.com/acme/app/pull/44",null,null]
["https://github.com/acme/app/pull/45",null,null]' \
  "$(rows 'select(.event == "task.pr_ready" and .task == "risk-task") | [.pr, .risk, .touches]')" \
  "pr_ready risk rows"
pass "pr_ready records the risk and touches of the newest done line naming the PR, else null"

# Test 4: task.decided event is recorded
bash "$LEDGER" decided decide-task "go with option A"
answer=$(rows 'select(.event == "task.decided") | .answer')
assert_equals '"go with option A"' "$answer" "decided answer"
pass "decided event recorded correctly"

echo "---"
echo "fm-fleet-ledger new event types complete"
