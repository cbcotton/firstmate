#!/usr/bin/env bash
# tests/fm-helm.test.sh - the Privateer front door, bin/fm-helm.sh, through its
# verbs in a Privateer home, run from inside the home's session. scout and ship
# file the backlog row, write the instructions with the ask as the captain's
# intent, take the first sailor that can take the work, and start it through
# the real bin/fm-spawn.sh against a fake tmux and treehouse; work no sailor
# can take waits in the queue until the same verb starts it; a home with
# dispatch rules is asked to choose one before anything is written; the
# --stdin form the slash commands use keeps the captain's words exactly and
# refuses words that lost their end line; the other verbs reach their scripts;
# and each malformed call, a home without the quarantine, and a caller outside
# the session are refused. The real tasks-axi holds the backlog, and a fake
# curl answers for the sailors. docs/configuration.md ("The front door") owns
# the contract, and tests/fm-helm-live-e2e.test.sh proves the slash commands
# against the real OpenCode.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

HELM="$ROOT/bin/fm-helm.sh"
TMP_ROOT=$(fm_test_tmproot fm-helm)
SEALED_REFUSAL='this is a sealed Privateer home; attach with bin/fm-privateer.sh attach, and never drive its session from outside'
DISPATCH='{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["coder"]},"bonsai":{"endpoint":"http://127.0.0.1:11235/v1","status":"live","models":["small"]}},"default":[{"harness":"opencode","sailor":"tiller","model":"coder"},{"harness":"opencode","sailor":"bonsai","model":"small"}]}'
RULES_DISPATCH='{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["coder"]},"bonsai":{"endpoint":"http://127.0.0.1:11235/v1","status":"live","models":["small"]}},"rules":[{"when":"reading and reporting only","use":{"harness":"opencode","sailor":"bonsai","model":"small"}}],"default":{"harness":"opencode","sailor":"tiller","model":"coder"}}'

# make_case <name> [<dispatch-json>]: a Privateer home with one registered
# project, app, whose ships take the pv/ prefix, a markdown backlog, and a
# fake curl that answers for every sailor except those named in
# <case-dir>/down; sets CASE_DIR, HOME_DIR, PROJ_DIR, WT_DIR, FAKEBIN_DIR.
make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$HOME_DIR/projects/app"
  WT_DIR="$CASE_DIR/wt"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" opencode
  printf 'tiller/coder\n' > "$HOME_DIR/config/privateer"
  : > "$HOME_DIR/config/sailor-sandbox"
  printf '%s\n' "${2:-$DISPATCH}" > "$HOME_DIR/config/crew-dispatch.json"
  mkdir -p "$HOME_DIR/state/privateer/egress"
  printf '18080\n' > "$HOME_DIR/state/privateer/egress/port"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  printf -- '- app [local-only branch=pv/] - the test project (added 2026-09-30)\n' > "$HOME_DIR/data/projects.md"
  : > "$CASE_DIR/down"
  cat > "$FAKEBIN_DIR/curl" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *11234*) grep -qx tiller '$CASE_DIR/down' && exit 7 ;;
    *11235*) grep -qx bonsai '$CASE_DIR/down' && exit 7 ;;
  esac
done
printf '%s' '{"data":[{"id":"coder"},{"id":"small"}]}'
SH
  chmod +x "$FAKEBIN_DIR/curl"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1"
  : > "$CASE_DIR/launch.log"
}

session_socket() {
  (. "$ROOT/bin/fm-privateer-lib.sh" && fm_privateer_socket_name "$1")
}

# helm_env: the environment a front-door call runs in, as fm_test_run_spawn
# gives a spawn, inside the home's session unless TMUX is given.
helm_env() {
  mkdir -p "$HOME_DIR/user-home"
  printf '%s\n' FM_ROOT_OVERRIDE= "FM_HOME=$HOME_DIR" "HOME=$HOME_DIR/user-home" CLAUDE_CONFIG_DIR= \
    "FM_STATE_OVERRIDE=$HOME_DIR/state" "FM_DATA_OVERRIDE=$HOME_DIR/data" \
    "FM_PROJECTS_OVERRIDE=$HOME_DIR/projects" "FM_CONFIG_OVERRIDE=$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 "FM_FAKE_PANE_PATH=$WT_DIR" "FM_FAKE_LAUNCH_LOG=$CASE_DIR/launch.log" \
    "TMUX=${TMUX_AS:-/tmp/tmux-fake/$(session_socket "$HOME_DIR"),1,0}" "PATH=$FAKEBIN_DIR:$PATH"
}

# run_helm <args...>: the front door with its output, stdout then stderr.
run_helm() {
  local -a env_args=()
  local line
  while IFS= read -r line; do env_args+=("$line"); done < <(helm_env)
  env "${env_args[@]}" "$HELM" "$@" 2>&1
}

# row <id> <field>: one field of the task's backlog row.
row() {
  local -a env_args=()
  local line
  while IFS= read -r line; do env_args+=("$line"); done < <(helm_env)
  env "${env_args[@]}" "$ROOT/bin/fm-tasks-axi.sh" show "$1" 2>/dev/null | sed -n "s/^  $2: //p" | head -1
}

# intent_of <id>: the body of the task's `## Captain's intent`.
intent_of() {
  awk '/^## Captain.s intent$/ { on = 1; next } /^## Firstmate spec$/ { exit } on' "$HOME_DIR/data/$1/brief.md" |
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

filed_id() {  # <output>
  printf '%s\n' "$1" | sed -n 's/^filed: \([^ ]*\) - .*/\1/p' | head -1
}

# track <output>: ID, the task <output> filed, whose per-task temp roots under
# /tmp, once a spawn has made them, are removed with the suite's fixtures.
track() {
  local dir
  ID=$(filed_id "$1")
  [ -n "$ID" ] || return 0
  for dir in "/tmp/fm-$ID" "/tmp/fm-$ID+"*; do
    [ ! -e "$dir" ] || FM_TEST_CLEANUP_DIRS+=("$dir")
  done
}

backlog_rows() {
  grep -c '^- \[' "$HOME_DIR/data/backlog.md"
}

assert_nothing_filed() {  # <label>
  assert_equals 0 "$(backlog_rows)" "$1: nothing may be filed"
  [ -z "$(ls "$HOME_DIR/state"/*.meta 2>/dev/null)" ] || fail "$1: nothing may be spawned"
}

# --- scout and ship -----------------------------------------------------------

test_scout_files_writes_and_starts() {
  local out status id
  make_case scout
  out=$(run_helm scout app "check why the captain's \"build\" fails")
  status=$?
  expect_code 0 "$status" "a scout through the front door must start"$'\n'"$out"
  track "$out"; id=$ID
  [ -n "$id" ] || fail "the front door must name the task it filed: $out"
  assert_contains "$out" "sailor: tiller/coder can take it" "the first default sailor must take the scout"
  assert_contains "$out" "started: $id, a scout on app, on tiller/coder" "the front door must say what started"
  assert_equals "check why the captain's \"build\" fails" "$(intent_of "$id")" "the ask must be the captain's intent, exactly as given"
  assert_no_grep '{TASK}' "$HOME_DIR/data/$id/brief.md" "the instructions must carry no intent placeholder"
  assert_no_grep '{FIRSTMATE_SPEC}' "$HOME_DIR/data/$id/brief.md" "the instructions must carry no spec placeholder"
  assert_grep 'Firstmate spec' "$HOME_DIR/data/$id/brief.md" "the instructions must keep the Firstmate spec"
  assert_equals in_flight "$(row "$id" state)" "the spawn must move the row In flight"
  assert_equals scout "$(row "$id" kind)" "the row must record the kind"
  assert_equals app "$(row "$id" repo)" "the row must record the project"
  assert_grep 'kind=scout' "$HOME_DIR/state/$id.meta" "the task record must be a scout"
  assert_grep 'sailor=tiller' "$HOME_DIR/state/$id.meta" "the task record must name the sailor"
  pass "scout files the row, writes the ask as the captain's intent, and starts the scout on the first sailor that can take it"
}

test_ship_is_local_only_on_the_registered_prefix() {
  local out status id
  make_case ship
  printf -- '- app [local-only +yolo branch=pv/] - the test project (added 2026-09-30)\n' > "$HOME_DIR/data/projects.md"
  out=$(run_helm ship app add a health check)
  status=$?
  expect_code 0 "$status" "a ship through the front door must start"$'\n'"$out"
  track "$out"; id=$ID
  assert_contains "$out" "started: $id, a ship on app, on tiller/coder" "the front door must say what started"
  assert_equals "add a health check" "$(intent_of "$id")" "the words after the project must be the ask"
  assert_grep 'Delivery contract: mode=local-only' "$HOME_DIR/data/$id/brief.md" "the instructions must ship local-only"
  assert_grep "pv/$id" "$HOME_DIR/data/$id/brief.md" "the instructions must use the project's registered prefix"
  assert_grep 'mode=local-only' "$HOME_DIR/state/$id.meta" "the task record must ship local-only"
  assert_grep 'yolo=on' "$HOME_DIR/state/$id.meta" "the task record must carry the project's registered merge authority"
  assert_equals ship "$(row "$id" kind)" "the row must record the kind"
  pass "ship starts a local-only ship on the project's registered branch prefix and merge authority"
}

test_work_no_sailor_can_take_waits_in_the_queue() {
  local out status id first
  make_case queued
  printf 'tiller\nbonsai\n' > "$CASE_DIR/down"
  out=$(run_helm scout app survey the tests)
  status=$?
  expect_code 0 "$status" "work no sailor can take must still be filed"$'\n'"$out"
  track "$out"; id=$ID
  assert_contains "$out" "queued: no sailor can take $id now" "the front door must say the work waits"
  assert_contains "$out" "tiller/coder:" "the front door must say why the first sailor refused"
  assert_contains "$out" "bonsai/small:" "the front door must say why the second sailor refused"
  assert_contains "$out" "start it once a sailor is free with: bin/fm-helm.sh scout $id" "the front door must name the call that starts it"
  assert_equals queued "$(row "$id" state)" "the row must stay Queued"
  assert_absent "$HOME_DIR/state/$id.meta" "nothing may be spawned"
  assert_present "$HOME_DIR/data/$id/brief.md" "the instructions must be written"

  printf 'tiller\n' > "$CASE_DIR/down"
  first=$out
  out=$(run_helm scout "$id")
  status=$?
  track "$first"
  expect_code 0 "$status" "the queued task must start once a sailor is free"$'\n'"$out"
  assert_contains "$out" "sailor: bonsai/small can take it" "the next sailor in order must take it"
  assert_contains "$out" "started: $id, a scout on app, on bonsai/small" "the front door must say what started"
  assert_equals in_flight "$(row "$id" state)" "the start must move the row In flight"
  assert_equals "survey the tests" "$(intent_of "$id")" "starting it must keep its instructions"
  pass "work no sailor can take waits in the queue with its instructions, and the same verb with its id starts it on the next free sailor"
}

test_dispatch_rules_are_chosen_before_anything_is_written() {
  local out status id
  make_case rules "$RULES_DISPATCH"
  out=$(run_helm scout app "read the captain's notes")
  status=$?
  expect_code 1 "$status" "a home with rules must ask for one"$'\n'"$out"
  assert_contains "$out" "refused: this home's dispatch rules are chosen by judgment" "the refusal must say a rule needs choosing"
  assert_contains "$out" "--rule 1: reading and reporting only (bonsai/small)" "the refusal must list each rule's condition and sailors"
  assert_contains "$out" "--rule default (tiller/coder)" "the refusal must list the default"
  assert_contains "$out" "the call: bin/fm-helm.sh scout --rule <n> app 'read the captain'\\''s notes'" "the refusal must give the call to repeat, with the ask quoted"
  assert_nothing_filed "a call without a rule"

  out=$(run_helm scout --rule 1 app "read the captain's notes")
  status=$?
  expect_code 0 "$status" "the chosen rule must start the scout"$'\n'"$out"
  track "$out"; id=$ID
  assert_contains "$out" "started: $id, a scout on app, on bonsai/small" "the rule's sailor must take the scout"

  out=$(run_helm ship --rule default app "fix the notes")
  status=$?
  track "$out"
  expect_code 0 "$status" "the default must start the ship"$'\n'"$out"
  assert_contains "$out" "on tiller/coder" "the default's sailor must take the ship"
  pass "a home with dispatch rules is asked to choose one, with each condition and the call to repeat, before anything is written, and --rule starts the work on that rule's sailors"
}

# --- the slash-command form ---------------------------------------------------

test_stdin_keeps_the_captains_words() {
  local out status id words
  make_case stdin
  words=$'fix the captain\'s "login" $(whoami); `true` && echo no\nand keep the second line'
  out=$(printf 'app %s\nFM_HELM_END_OF_ARGUMENTS\n' "$words" | run_helm ship --stdin)
  status=$?
  expect_code 0 "$status" "the slash-command form must start the ship"$'\n'"$out"
  track "$out"; id=$ID
  assert_equals "$words" "$(intent_of "$id")" "every quote, \$, ;, and line of the captain's words must reach the intent unchanged"
  assert_contains "$out" "filed: $id - fix the captain's \"login\" \$(whoami); \`true\` && echo no" "the title must be the ask's first line"

  out=$(printf -- '--rule default app look around\nFM_HELM_END_OF_ARGUMENTS\n' | run_helm scout --stdin)
  status=$?
  track "$out"
  expect_code 0 "$status" "the slash-command form must take a leading --rule"$'\n'"$out"
  assert_equals "look around" "$(intent_of "$ID")" "the words after the project must be the ask"
  pass "the --stdin form keeps the captain's words exactly, quotes, \$, ;, and newlines included, and takes a leading --rule"
}

test_stdin_without_its_end_line_is_refused() {
  local out status
  make_case cut
  out=$(printf 'app fix \n' | run_helm scout --stdin)
  status=$?
  expect_code 1 "$status" "words without their end line must be refused"$'\n'"$out"
  assert_contains "$out" "refused: the words arrived without their end line, most likely cut at a backtick" "the refusal must say the words were cut"
  assert_nothing_filed "words cut short"
  pass "words that arrive without their end line, as a backtick leaves them, are refused before anything is written"
}

# --- the other verbs ----------------------------------------------------------

test_steer_queue_and_sailors_reach_their_scripts() {
  local out status id
  make_case verbs
  out=$(run_helm scout app look at the logs)
  track "$out"; id=$ID
  [ -n "$id" ] || fail "the scout must start before it can be steered: $out"
  out=$(printf '%s look again, and\nreport twice\nFM_HELM_END_OF_ARGUMENTS\n' "$id" | run_helm steer --stdin)
  status=$?
  expect_code 0 "$status" "steer must send the text"$'\n'"$out"
  grep -rqF 'report twice' "$HOME_DIR/state/$id.inbox" || fail "steer must leave the text as a durable inbox record: $out"

  out=$(run_helm queue)
  status=$?
  expect_code 0 "$status" "queue must show the backlog"$'\n'"$out"
  assert_contains "$out" "$id" "queue must list the task"
  assert_not_contains "$out" "help[" "queue must leave out tasks-axi's own hints"
  assert_not_contains "$out" "--start" "queue must not suggest starting a row by hand"

  out=$(run_helm sailors)
  status=$?
  expect_code 0 "$status" "sailors must show the sailors"$'\n'"$out"
  assert_contains "$out" "tiller" "sailors must list the first sailor"
  assert_contains "$out" "bonsai" "sailors must list the second sailor"

  echo "needs-decision [at=$(date +%s)] [key=pick]: choose left or right" >> "$HOME_DIR/state/$id.status"
  out=$(run_helm wake)
  status=$?
  expect_code 0 "$status" "wake must drain the wake queue"$'\n'"$out"
  assert_contains "$out" "$id [key=pick] needs-decision: choose left or right" "wake must present the worker's open decision"
  pass "steer sends the text as a durable record, queue shows the backlog without tasks-axi's hints, sailors shows every sailor, and wake presents what waits"
}

test_helm_runs_the_session_start() {
  local out status
  make_case helm
  # Detached from this shell, the session start finds no harness in its
  # ancestry on any host, so it runs read-only and starts nothing in the home.
  ( (
    run_helm helm > "$CASE_DIR/helm.out"
    echo "$?" > "$CASE_DIR/helm.status"
  ) & )
  for _ in $(seq 1200); do
    [ -s "$CASE_DIR/helm.status" ] && break
    sleep 0.1
  done
  [ -s "$CASE_DIR/helm.status" ] || fail "helm never finished: $(tail -5 "$CASE_DIR/helm.out" 2>/dev/null)"
  status=$(cat "$CASE_DIR/helm.status")
  out=$(cat "$CASE_DIR/helm.out")
  expect_code 0 "$status" "helm must run the session start"$'\n'"$out"
  assert_contains "$out" "NEXT STEP" "helm must print the whole session-start digest"
  assert_equals "front door: /scout <project> <ask>, /ship <project> <ask>, /scout or /ship <task-id> for queued work, /queue, /sailors, /steer <task-id> <text>, /land <task-id>, /wake" \
    "$(printf '%s\n' "$out" | tail -1)" "helm must end by naming the front door's commands"
  pass "helm runs the session start and then names the front door's commands"
}

test_land_reaches_the_guarded_local_merge() {
  local out status
  make_case land
  out=$(run_helm land pv-none)
  status=$?
  expect_code 1 "$status" "land must pass the local merge's refusal through"$'\n'"$out"
  assert_contains "$out" "error: no meta for task pv-none" "land must run the guarded local merge"
  assert_not_contains "$out" "landed:" "a refused landing must not claim to have landed"
  pass "land runs the guarded local merge and passes its refusal through"
}

# --- refusals -------------------------------------------------------------------

test_malformed_calls_are_refused() {
  local out status call needle
  make_case malformed
  while IFS='|' read -r call needle; do
    # shellcheck disable=SC2086
    out=$(run_helm $call)
    status=$?
    [ "$status" -ne 0 ] || fail "'fm-helm.sh $call' must be refused, got: $out"
    assert_contains "$out" "$needle" "'fm-helm.sh $call' refusal"
  done <<'EOF'
|refused: no verb given; the verbs are helm, scout, ship, queue, sailors, steer, land, wake
launch app go|refused: unknown verb 'launch'; the verbs are helm, scout, ship, queue, sailors, steer, land, wake
scout|refused: scout needs a project and the ask, or the id of a queued task
scout app|refused: 'app' is not a task in the backlog; to start new work give the project and then the ask
scout nosuch go|refused: 'nosuch' is not a registered project with a clone under projects/; the projects here are: app
scout projects/app go|refused: 'projects/app' is a path; give the name of a project under projects/
scout --project app go|refused: unknown flag '--project'; scout takes only --rule <n>|default, before the project
ship --rule 0 app go|refused: --rule takes a rule number from 1, or default, not '0'
ship --rule 3 app go|refused: there is no rule 3; config/crew-dispatch.json declares 0
scout --rule|refused: --rule needs a rule number or default
steer pv-x|refused: steer needs a task id and the text to send
land|refused: land takes exactly one task id
land a b|refused: land takes exactly one task id
helm now|refused: helm takes no arguments
queue all|refused: queue takes no arguments
wake up|refused: wake takes no arguments
scout --stdin extra|refused: --stdin takes the arguments on standard input, and nothing else
EOF
  assert_nothing_filed "a malformed call"
  pass "every malformed call is refused with what was wrong and the accepted forms, before anything is written"
}

test_a_queued_task_of_another_kind_is_not_started() {
  local out status id
  make_case kind
  printf 'tiller\nbonsai\n' > "$CASE_DIR/down"
  id=$(filed_id "$(run_helm scout app look)")
  : > "$CASE_DIR/down"
  out=$(run_helm ship "$id")
  status=$?
  expect_code 1 "$status" "a queued scout must not start as a ship"$'\n'"$out"
  assert_contains "$out" "refused: task $id is a scout, not a ship" "the refusal must name the task's kind"
  assert_absent "$HOME_DIR/state/$id.meta" "nothing may be spawned"
  pass "a queued task starts only through the verb of its own kind"
}

test_only_a_privateer_home_inside_its_session() {
  local out status
  make_case outside
  out=$(TMUX_AS=/tmp/tmux-fake/default,1,0 run_helm scout app go)
  status=$?
  expect_code 2 "$status" "the front door must refuse outside the session"$'\n'"$out"
  assert_contains "$out" "error: fm-helm.sh refused: $SEALED_REFUSAL" "the refusal must be the session gate's"
  assert_not_contains "$out" "$(session_socket "$HOME_DIR")" "the refusal must not name the session's socket"
  assert_nothing_filed "a call from outside the session"

  make_case plain
  rm -f "$HOME_DIR/config/privateer"
  out=$(run_helm queue)
  status=$?
  expect_code 2 "$status" "the front door must refuse a home without the quarantine"$'\n'"$out"
  assert_contains "$out" "refused: the front door serves only a Privateer home" "the refusal must name the reason"
  pass "the front door refuses a home without the quarantine and a caller outside the home's session"
}

test_scout_files_writes_and_starts
test_ship_is_local_only_on_the_registered_prefix
test_work_no_sailor_can_take_waits_in_the_queue
test_dispatch_rules_are_chosen_before_anything_is_written
test_stdin_keeps_the_captains_words
test_stdin_without_its_end_line_is_refused
test_steer_queue_and_sailors_reach_their_scripts
test_helm_runs_the_session_start
test_land_reaches_the_guarded_local_merge
test_malformed_calls_are_refused
test_a_queued_task_of_another_kind_is_not_started
test_only_a_privateer_home_inside_its_session

echo "# all fm-helm tests passed"
