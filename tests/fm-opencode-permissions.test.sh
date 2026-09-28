#!/usr/bin/env bash
# tests/fm-opencode-permissions.test.sh - profile selection and composition in
# bin/fm-opencode-permissions.sh. Whether OpenCode itself honors the composed
# profile is proven against the real harness by
# tests/fm-opencode-restricted-live-e2e.test.sh; docs/configuration.md
# ("OpenCode permission profile") owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-permissions)
PERMS="$ROOT/bin/fm-opencode-permissions.sh"

# Sets HOME_DIR for one isolated home; <token> is written to the selector
# unless it is the literal "absent".
make_home() {  # <name> <token>
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data/t1"
  [ "$2" = absent ] || printf '%s\n' "$2" > "$HOME_DIR/config/opencode-permission-profile"
}

run_perms() {
  FM_HOME="$HOME_DIR" "$PERMS" "$@" 2>&1
}

test_absent_and_allow_keep_every_tool() {
  local token out
  for token in absent allow '  allow  '; do
    make_home "allow-$RANDOM" "$token"
    assert_equals allow "$(run_perms profile)" "selector '$token' must select allow"
    assert_equals '{"*":"allow"}' "$(run_perms compose t1)" "selector '$token' must compose today's launch permission"
    out=$(run_perms worker-note)
    assert_equals "" "$out" "an allow profile has no worker note"
  done
  pass "an absent or allow selector keeps today's allow-everything permission and adds no worker note"
}

test_unknown_selector_value_is_refused() {
  local out status
  make_home unknown bypass
  out=$(run_perms compose t1)
  status=$?
  expect_code 2 "$status" "an unknown selector value must refuse"
  assert_contains "$out" "holds 'bypass'; accepted values are: allow" "refusal must name the accepted values"
  make_home unreadable restricted
  rm -f "$HOME_DIR/config/opencode-permission-profile"
  mkdir "$HOME_DIR/config/opencode-permission-profile"
  out=$(run_perms profile)
  status=$?
  expect_code 2 "$status" "a selector that is not a regular file must refuse"
  pass "an unknown or unreadable selector refuses rather than choosing a posture"
}

test_restricted_puts_the_catch_all_deny_first() {
  local json
  make_home restricted restricted
  json=$(run_perms compose t1)
  assert_equals '"*"' "$(printf '%s' "$json" | jq -c 'keys_unsorted[0]')" "the catch-all must be the first rule"
  assert_equals '"deny"' "$(printf '%s' "$json" | jq -c '.["*"]')" "the catch-all must deny"
  assert_equals '"*"' "$(printf '%s' "$json" | jq -c '.bash | keys_unsorted[0]')" "the bash catch-all must precede every bash pattern"
  assert_equals '"deny"' "$(printf '%s' "$json" | jq -c '.bash["git push*"]')" "push must be denied"
  assert_equals '"allow"' "$(printf '%s' "$json" | jq -c '.bash["git commit *"]')" "local commits must be allowed"
  assert_equals '"deny"' "$(printf '%s' "$json" | jq -c '.webfetch')" "web fetch must be denied"
  assert_equals '"deny"' "$(printf '%s' "$json" | jq -c '.external_directory["*"]')" "paths outside the copy must be denied first"
  pass "the restricted profile denies by default with every allow after its catch-all"
}

test_restricted_allows_exactly_this_tasks_protocol_paths() {
  local json state data
  make_home protocol restricted
  state=$(cd "$HOME_DIR/state" && pwd -P)
  data=$(cd "$HOME_DIR/data" && pwd -P)
  json=$(run_perms compose t1)
  assert_equals '"allow"' "$(printf '%s' "$json" | jq -c --arg p "$state/t1.status" '.external_directory[$p]')" "the task's status file must be reachable"
  assert_equals '"allow"' "$(printf '%s' "$json" | jq -c --arg p "$state/t1.inbox/*" '.external_directory[$p]')" "the task's inbox must be reachable"
  assert_equals '"allow"' "$(printf '%s' "$json" | jq -c --arg p "$data/t1/*" '.external_directory[$p]')" "the task's brief directory must be reachable"
  assert_equals 'null' "$(printf '%s' "$json" | jq -c --arg p "$state/t2.status" '.external_directory[$p]')" "another task's status file must stay denied"
  assert_equals '"allow"' "$(printf '%s' "$json" | jq -c --arg p "echo * >> '$HOME_DIR/state/t1.status'" '.bash[$p]')" "the brief's status command must be allowed as the brief spells it"
  assert_equals '"allow"' "$(printf '%s' "$json" | jq -c --arg p "mv '$HOME_DIR/state/t1.inbox'/*.msg '$HOME_DIR/state/t1.inbox'/handled/" '.bash[$p]')" "the inbox acknowledgement must be allowed"
  pass "the restricted profile opens exactly this task's status file, inbox, and brief directory"
}

test_restricted_worker_note_tells_the_worker_to_ask() {
  local out
  make_home note restricted
  out=$(run_perms worker-note)
  assert_contains "$out" "# Restricted tools" "worker note heading missing"
  assert_contains "$out" "[key=perm-<slug>]" "worker note must name the decision key shape"
  assert_contains "$out" "do not look for another way" "worker note must forbid working around a denial"
  pass "a restricted worker is told to report a denied tool call instead of routing around it"
}

test_compose_refuses_a_malformed_task_id() {
  local out status
  make_home badid restricted
  out=$(run_perms compose '../t1')
  status=$?
  expect_code 2 "$status" "a task id with a path separator must be refused"
  pass "compose refuses a task id that is not a plain slug"
}

test_absent_and_allow_keep_every_tool
test_unknown_selector_value_is_refused
test_restricted_puts_the_catch_all_deny_first
test_restricted_allows_exactly_this_tasks_protocol_paths
test_restricted_worker_note_tells_the_worker_to_ask
test_compose_refuses_a_malformed_task_id

echo "# all fm-opencode-permissions tests passed"
