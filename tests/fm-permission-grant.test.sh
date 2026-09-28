#!/usr/bin/env bash
# tests/fm-permission-grant.test.sh - bin/fm-permission-grant.sh: the record,
# each scope's lifetime, the refusal list, the captain's words, and how grants
# fold into the restricted profile bin/fm-opencode-permissions.sh composes.
# docs/configuration.md ("Permission grants") owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-permission-grant)
GRANT="$ROOT/bin/fm-permission-grant.sh"
PERMS="$ROOT/bin/fm-opencode-permissions.sh"
LOCK_HOLDER_PID=

cleanup() {
  [ -z "$LOCK_HOLDER_PID" ] || kill "$LOCK_HOLDER_PID" 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# Sets HOME_DIR and WORDS for one home with a live task t1 and a live session
# lock held by a sleeping process.
make_home() {  # <name>
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/t1"
  printf 'restricted\n' > "$HOME_DIR/config/opencode-permission-profile"
  printf 'harness=opencode\ndispatched_at=1000\n' > "$HOME_DIR/state/t1.meta"
  if [ -z "$LOCK_HOLDER_PID" ]; then
    sleep 600 &
    LOCK_HOLDER_PID=$!
  fi
  printf '%s\n' "$LOCK_HOLDER_PID" > "$HOME_DIR/state/.lock"
  WORDS="$HOME_DIR/words.txt"
  printf 'let the sailor run npm test for this task\n' > "$WORDS"
}

run_grant() {
  FM_HOME="$HOME_DIR" "$GRANT" "$@" 2>&1
}

compose() {
  FM_HOME="$HOME_DIR" "$PERMS" compose t1
}

test_task_grant_records_the_words_and_reaches_the_profile() {
  local out status record
  make_home task
  out=$(run_grant grant --scope task --task t1 --permission bash --pattern 'npm test *' --action allow --words-file "$WORDS" --channel chat)
  status=$?
  expect_code 0 "$status" "a task grant must be accepted"$'\n'"$out"
  assert_contains "$out" "bin/fm-control.sh <task> relaunch" "the grant must say how to apply it to a running worker"
  record=$(tail -1 "$HOME_DIR/state/permission-grants.jsonl")
  assert_equals '"let the sailor run npm test for this task\n"' "$(printf '%s' "$record" | jq -c .words)" "the captain's exact words must be recorded"
  assert_equals '"1000"' "$(printf '%s' "$record" | jq -c .task_dispatched_at)" "a task grant must bind the task's dispatch stamp"
  assert_equals '"allow"' "$(compose | jq -c '.bash["npm test *"]')" "the grant must reach the task's composed profile"
  assert_equals '"deny"' "$(compose | jq -c '.bash["*"]')" "the baseline catch-all must stay in place"
  pass "a task grant records the captain's exact words and reaches that task's profile"
}

test_task_grant_does_not_follow_a_reused_task_id() {
  make_home reuse
  run_grant grant --scope task --task t1 --permission bash --pattern 'npm test *' --action allow --words-file "$WORDS" --channel chat >/dev/null
  printf 'harness=opencode\ndispatched_at=2000\n' > "$HOME_DIR/state/t1.meta"
  assert_equals 'null' "$(compose | jq -c '.bash["npm test *"]')" "a later task reusing the id must not inherit the grant"
  pass "a task grant ends with its dispatch, so a reused task id starts without it"
}

test_session_grant_ends_with_the_session() {
  local other
  make_home session
  run_grant grant --scope session --permission bash --pattern 'npm run lint' --action allow --words-file "$WORDS" --channel pinnace --ref note-7 >/dev/null
  assert_equals '"allow"' "$(compose | jq -c '.bash["npm run lint"]')" "a session grant must apply during its session"
  sleep 600 &
  other=$!
  printf '%s\n' "$other" > "$HOME_DIR/state/.lock"
  touch -t 203001010000 "$HOME_DIR/state/.lock"
  assert_equals 'null' "$(compose | jq -c '.bash["npm run lint"]')" "a session grant must not survive into the next session"
  kill "$other" 2>/dev/null
  pass "a session grant applies while its session holds the lock and ends with it"
}

test_later_narrowing_wins_and_revoke_removes() {
  local id
  make_home narrow
  id=$(run_grant grant --scope standing --permission bash --pattern 'npm install' --action allow --words-file "$WORDS" --channel chat | cut -d: -f1)
  sleep 1
  run_grant grant --scope task --task t1 --permission bash --pattern 'npm install' --action deny --words-file "$WORDS" --channel chat >/dev/null
  assert_equals '"deny"' "$(compose | jq -c '.bash["npm install"]')" "a later deny must win over an earlier allow for the same pattern"
  run_grant revoke "$id" --words-file "$WORDS" --channel chat >/dev/null
  assert_equals '"deny"' "$(compose | jq -c '.bash["npm install"]')" "revoking the allow leaves the deny"
  assert_equals 1 "$(run_grant list --task t1 | grep -c 'npm install')" "list must show only the grants still in force"
  pass "a later narrowing wins over an earlier widening, and a revoked grant no longer applies"
}

test_protocol_rules_still_come_last() {
  make_home protocol
  run_grant grant --scope task --task t1 --permission bash --pattern "mv '$HOME_DIR/state/t1.inbox'/*.msg '$HOME_DIR/state/t1.inbox'/handled/" --action deny --words-file "$WORDS" --channel chat >/dev/null
  assert_equals '"allow"' "$(compose | jq -c --arg p "mv '$HOME_DIR/state/t1.inbox'/*.msg '$HOME_DIR/state/t1.inbox'/handled/" '.bash[$p]')" "the worker protocol must stay usable whatever a grant says"
  pass "the worker's own protocol commands stay allowed after every grant"
}

test_refused_classes_are_never_granted() {
  local perm pat out status n=0
  make_home refuse
  while IFS='|' read -r perm pat; do
    [ -n "$perm" ] || continue
    n=$((n + 1))
    out=$(run_grant grant --scope task --task t1 --permission "$perm" --pattern "$pat" --action allow --words-file "$WORDS" --channel chat)
    status=$?
    expect_code 1 "$status" "allow $perm '$pat' must be refused"
    assert_contains "$out" "refused:" "allow $perm '$pat' must say it was refused"
  done <<ROWS
*|*
webfetch|*
bash|*
bash|sudo make install
bash|git push --force origin main
bash|git push origin *
bash|git push origin +main
bash|git branch -D old
bash|gh pr merge 7
bash|rm -rf build
bash|rm /etc/hosts
bash|ssh stoker
bash|security find-generic-password -s x
bash|launchctl load x.plist
bash|curl https://example.com
bash|npm install -g left-pad
bash|npx create-thing
bash|tmux send-keys -t fm hi
bash|bin/fm-permission-grant.sh grant
bash|claude -p hi
bash|git *
bash|git b*
bash|g* status
bash|sh -c *
bash|bash scripts/x.sh
bash|zsh -c x
bash|python3 -c x
bash|/usr/bin/python script.py
bash|node x.js
bash|perl -e x
bash|ruby x.rb
bash|env FOO=1 npm test
bash|xargs rm
bash|find . -delete
bash|make build
external_directory|$HOME/*
external_directory|~/.*
external_directory|~/.zshrc
external_directory|$HOME/.bashrc
external_directory|~/.bash_profile
external_directory|~/.profile
external_directory|~/.gitconfig
external_directory|~/.local/bin/*
external_directory|~/bin/*
external_directory|/opt/homebrew/bin/*
external_directory|$HOME/.ssh/*
external_directory|/etc/*
external_directory|$HOME_DIR/state/*
ROWS
  [ ! -e "$HOME_DIR/state/permission-grants.jsonl" ] || fail "no refused grant may leave a record"
  pass "every never-pre-grantable class ($n cases) is refused and leaves no record"
}

test_ordinary_grants_and_every_deny_are_accepted() {
  local perm pat out status
  make_home accept
  while IFS='|' read -r perm pat; do
    [ -n "$perm" ] || continue
    out=$(run_grant grant --scope task --task t1 --permission "$perm" --pattern "$pat" --action allow --words-file "$WORDS" --channel chat)
    status=$?
    expect_code 0 "$status" "allow $perm '$pat' must be accepted: $out"
  done <<'ROWS'
bash|npm test *
bash|git status --short
bash|npm install
bash|git push origin fm/task-x
bash|rm build.log
external_directory|/opt/shared-fixtures/*
ROWS
  out=$(run_grant grant --scope standing --permission bash --pattern '*' --action deny --words-file "$WORDS" --channel chat)
  status=$?
  expect_code 0 "$status" "a deny must always be accepted"
  pass "ordinary project commands, one exact push, and every deny are accepted"
}

test_words_channel_and_scope_are_required() {
  local out status
  make_home required
  : > "$HOME_DIR/empty.txt"
  out=$(run_grant grant --scope task --task t1 --permission bash --pattern 'npm test' --action allow --words-file "$HOME_DIR/empty.txt" --channel chat)
  status=$?
  expect_code 2 "$status" "empty words must be refused"
  assert_contains "$out" "record the captain's actual words" "empty-words refusal must say why"
  out=$(run_grant grant --scope task --task t1 --permission bash --pattern 'npm test' --action allow --words-file "$WORDS" --channel email)
  status=$?
  expect_code 2 "$status" "an unknown channel must be refused"
  out=$(run_grant grant --scope task --task gone --permission bash --pattern 'npm test' --action allow --words-file "$WORDS" --channel chat)
  status=$?
  expect_code 1 "$status" "a task grant for a task with no record must be refused"
  rm -f "$HOME_DIR/state/.lock"
  out=$(run_grant grant --scope session --permission bash --pattern 'npm test' --action allow --words-file "$WORDS" --channel chat)
  status=$?
  expect_code 1 "$status" "a session grant with no live session must be refused"
  pass "a grant needs the captain's words, a known channel, and a scope it can bind to"
}

test_task_grant_records_the_words_and_reaches_the_profile
test_task_grant_does_not_follow_a_reused_task_id
test_session_grant_ends_with_the_session
test_later_narrowing_wins_and_revoke_removes
test_protocol_rules_still_come_last
test_refused_classes_are_never_granted
test_ordinary_grants_and_every_deny_are_accepted
test_words_channel_and_scope_are_required

echo "# all fm-permission-grant tests passed"
