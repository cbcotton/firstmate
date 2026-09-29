#!/usr/bin/env bash
# Behavior tests for the phone mirror (bin/fm-castoff.sh): the flag's
# lifecycle, and its writer driven through the tracked hook registrations each
# primary harness runs, down to the mirrored messages bin/fm-inbox.sh receipts
# serves to the pinnace.
#
# Every writer runs as a child of a fake harness (a bash symlink named
# "claude") whose pid is the home's session lock, from a git checkout that
# passes the primary-scope check, exactly as a primary's own hook runs. Hook
# payloads are the shapes measured from the real harnesses
# (docs/verification/supervision.md "Dialog mirror writers").
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CASTOFF="$ROOT/bin/fm-castoff.sh"
INBOX="$ROOT/bin/fm-inbox.sh"
OPINPUT="$ROOT/bin/fm-operational-input.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'skip: python3 absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-castoff)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
trap fm_test_cleanup EXIT
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR

# A primary checkout: git, AGENTS.md, and this repo's bin.
PRIMARY_ROOT="$TMP_ROOT/primary"
mkdir -p "$PRIMARY_ROOT"
git init -q "$PRIMARY_ROOT"
: > "$PRIMARY_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY_ROOT/bin"

make_home() {  # <name> [mirror on: 1|0]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  [ "${2:-1}" != 1 ] || FM_HOME="$home" "$CASTOFF" on >/dev/null
  printf '%s\n' "$home"
}

# Run a shell script as the lock-owning primary session of <home>.
as_session() {  # <home> <script>
  FM_HOME="$1" PRIMARY_ROOT="$PRIMARY_ROOT" CASTOFF="$CASTOFF" OPINPUT="$OPINPUT" "$FAKE_CLAUDE" -c \
    'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; '"$2"
}

# The command string one tracked registration runs.
claude_cmd() { jq -r --arg e "$1" '.hooks[$e][].hooks[] | select(.command | contains("fm-castoff.sh")) | .command' "$ROOT/.claude/settings.json"; }
cursor_cmd() { jq -r --arg e "$1" '.hooks[$e][] | select(.command | contains("fm-castoff.sh")) | .command' "$ROOT/.cursor/hooks.json"; }

# Inside an as_session script: one Claude prompt-submit (captain) or Stop
# (main) payload carrying <text>, through the writer.
SAY='say() {  # <captain|main> <text> [<id>]
  if [ "$1" = captain ]; then
    jq -cn --arg t "$2" --arg id "${3:-}" "{hook_event_name: \"UserPromptSubmit\", prompt_id: \$id, prompt: \$t}"
  else
    jq -cn --arg t "$2" --arg id "${3:-}" "{hook_event_name: \"Stop\", prompt_id: \$id, last_assistant_message: \$t}"
  fi | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
}
'

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# "<cursor>|<turn>|<body>" per mirrored message, in order.
mirrored_at() {  # <home>
  FM_HOME="$1" "$INBOX" receipts --all-mate 2>/dev/null \
    | python3 -c 'import json,sys
for r in json.load(sys.stdin)["mate"]:
    if not r.get("removed"):
        print("%s|%s|%s" % (r["cursor"], r["turn"], r["body"]))'
}

# "<turn>|<body>" per mirrored message, in order.
mirrored() {  # <home>
  FM_HOME="$1" "$INBOX" receipts --all-mate 2>/dev/null \
    | python3 -c 'import json,sys
for r in json.load(sys.stdin)["mate"]:
    if not r.get("removed"):
        print("%s|%s" % (r["turn"], r["body"]))'
}

test_flag_lifecycle() {
  local home out at
  home="$TMP_ROOT/lifecycle"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$CASTOFF" status)
  expect_code 1 "$?" "status must exit 1 while the mirror is off"
  assert_equals "off" "$out" "status must say off before the first on"
  out=$(FM_HOME="$home" "$CASTOFF" on) || fail "on failed"
  assert_contains "$out" "The phone mirror is on" "on must say the mirror is on"
  assert_contains "$out" "No pinnace is configured" "on must say when no pinnace reads the mirror"
  assert_equals "on" "$(head -n 1 "$home/state/.castoff")" "the flag's first line must be on"
  at=$(sed -n 's/^at=//p' "$home/state/.castoff")
  case "$at" in ''|*[!0-9]*) fail "the flag must record the epoch it was set, got: $at" ;; esac
  assert_equals "600" "$(mode_of "$home/state/.castoff")" "the flag must be owner-only"
  out=$(FM_HOME="$home" "$CASTOFF" status) || fail "status must exit 0 while the mirror is on"
  assert_equals "on since $(date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ)" "$out" \
    "status must say since when the mirror is on"
  out=$(FM_HOME="$home" "$CASTOFF" on) || fail "a refresh of a fresh flag failed"
  assert_contains "$out" "already on" "a refresh of the flag on wrote must say the mirror was already on"
  assert_equals "at=$at" "$(sed -n '2p' "$home/state/.castoff")" "a refresh of the flag on wrote must keep its at="

  printf 'on\nat=1700000000\n' > "$home/state/.castoff"
  : > "$home/config/pinnace"
  out=$(FM_HOME="$home" "$CASTOFF" on) || fail "a refresh failed"
  assert_contains "$out" "already on, since 2023-11-14T22:13:20Z" "a refresh must say the mirror was already on"
  assert_equals "at=1700000000" "$(sed -n '2p' "$home/state/.castoff")" "a refresh must keep the original at="

  printf 'turn\ncaptain\n' > "$home/state/.castoff-turn"
  out=$(FM_HOME="$home" "$CASTOFF" off) || fail "off failed"
  assert_contains "$out" "The phone mirror is off" "off must say the mirror is off"
  assert_absent "$home/state/.castoff" "off must remove the flag"
  assert_absent "$home/state/.castoff-turn" "off must remove the turn stamp"
  out=$(FM_HOME="$home" "$CASTOFF" off) || fail "a second off failed"
  assert_contains "$out" "already off" "a second off must say nothing changed"
  out=$(FM_HOME="$home" "$CASTOFF" on) || fail "on with a pinnace failed"
  assert_not_contains "$out" "No pinnace" "on must not warn when a pinnace is configured"
  expect_code 2 "$(FM_HOME="$home" "$CASTOFF" >/dev/null 2>&1; echo $?)" "no subcommand must be a usage error"
  pass "castoff: on writes an owner-only flag, a refresh keeps its start, status reports it, and off removes it"
}

test_every_harness_registration_mirrors_the_final_message() {
  local home
  home=$(make_home harnesses)
  CLAUDE_PROMPT=$(claude_cmd UserPromptSubmit) CLAUDE_STOP=$(claude_cmd Stop) \
  CURSOR_PROMPT=$(cursor_cmd beforeSubmitPrompt) CURSOR_RESPONSE=$(cursor_cmd afterAgentResponse) \
  as_session "$home" '
    run() { printf "%s" "$2" | env CLAUDE_PROJECT_DIR="$PRIMARY_ROOT" CURSOR_PROJECT_DIR="$PRIMARY_ROOT" \
      bash -c "cd \"$PRIMARY_ROOT\" && $1"; }
    run "$CLAUDE_PROMPT" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"c1\",\"prompt\":\"claude captain\"}"
    run "$CLAUDE_STOP" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"c1\",\"last_assistant_message\":\"claude main\"}"
    run "$CURSOR_PROMPT" "{\"hook_event_name\":\"beforeSubmitPrompt\",\"generation_id\":\"u1\",\"prompt\":\"cursor captain\",\"cursor_version\":\"x\"}"
    run "$CURSOR_RESPONSE" "{\"hook_event_name\":\"afterAgentResponse\",\"generation_id\":\"u1\",\"text\":\"cursor main\",\"cursor_version\":\"x\"}"
  ' || fail "a tracked castoff hook failed"
  assert_equals "captain|claude main
captain|cursor main" "$(mirrored "$home")" \
    "every tracked registration must mirror the final message, and never the captain's own prompt"
  pass "castoff: the Claude and Cursor registrations mirror each turn's final message, never the prompt"
}

# A home with the mirror off is untouched, byte for byte, by every tracked
# registration, even for the lock-owning primary session in a primary checkout.
test_home_with_the_mirror_off_is_untouched() {
  local home before after
  home=$(make_home off 0)
  printf 'working: demo\n' > "$home/state/demo.status"
  snapshot() { (cd "$1/state" && find . -type f ! -name .lock | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
  before=$(snapshot "$home")
  CLAUDE_PROMPT=$(claude_cmd UserPromptSubmit) CLAUDE_STOP=$(claude_cmd Stop) \
  CURSOR_PROMPT=$(cursor_cmd beforeSubmitPrompt) CURSOR_RESPONSE=$(cursor_cmd afterAgentResponse) \
  as_session "$home" '
    run() { printf "%s" "$2" | env CLAUDE_PROJECT_DIR="$PRIMARY_ROOT" CURSOR_PROJECT_DIR="$PRIMARY_ROOT" \
      bash -c "cd \"$PRIMARY_ROOT\" && $1"; }
    run "$CLAUDE_PROMPT" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hello\"}"
    run "$CURSOR_PROMPT" "{\"hook_event_name\":\"beforeSubmitPrompt\",\"prompt\":\"hello\",\"cursor_version\":\"x\"}"
    run "$CLAUDE_STOP" "{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"hi\"}"
    run "$CURSOR_RESPONSE" "{\"hook_event_name\":\"afterAgentResponse\",\"text\":\"hi\",\"cursor_version\":\"x\"}"
  ' > "$home/writers.out" 2>&1 || fail "a castoff registration failed with the mirror off: $(cat "$home/writers.out")"
  [ ! -s "$home/writers.out" ] || fail "a castoff registration printed with the mirror off: $(cat "$home/writers.out")"
  after=$(snapshot "$home")
  assert_equals "$before" "$after" "a castoff writer changed the state of a home with the mirror off"
  pass "castoff: a home with the mirror off is untouched by every tracked registration"
}

test_foreign_unowned_and_crewmate_writes_nothing() {
  local home other crew out
  home=$(make_home foreign)
  as_session "$home" '
    printf "%s" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\",\"last_assistant_message\":\"from cursor\",\"cursor_version\":\"x\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
    printf "%s" "{\"hook_event_name\":\"PreToolUse\",\"last_assistant_message\":\"not dialog\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
    printf "%s" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\",\"last_assistant_message\":\"  \\n \"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
    printf "%s" "{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"wrong harness\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook codex
  ' || fail "a writer failed"
  assert_equals "" "$(mirrored "$home")" \
    "a Cursor payload on the Claude registration, another event, an empty message, and an unknown harness must mirror nothing"

  other=$(make_home unowned)
  sleep 30 &
  printf '%s\n' "$!" > "$other/state/.lock"
  printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"not the owner"}' \
    | FM_HOME="$other" FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$FAKE_CLAUDE" -c '"$0" hook claude' "$CASTOFF"
  kill "$(cat "$other/state/.lock")" 2>/dev/null || true
  assert_absent "$other/state/inbox" "a session that does not hold the fleet lock must mirror nothing"

  crew="$TMP_ROOT/crew-worktree"
  mkdir -p "$crew"
  out=$(printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"hi"}' | FM_HOME="$crew" "$CASTOFF" hook claude 2>&1)
  [ -z "$out" ] || fail "an inert writer printed: $out"
  assert_absent "$crew/state" "an inert writer must create nothing in a home without state/"
  pass "castoff: a foreign host's payload, other events, empty messages, a session without the lock, and a crewmate write nothing"
}

# A turn the captain typed is stamped captain; a turn fleet machinery started
# (an operational envelope, a harness-started rewake, a verified doorbell) is
# stamped operational; a doorbell naming no record of this home is not proof.
test_turns_are_stamped_captain_or_operational() {
  local home envelope doorbell forged
  home=$(make_home stamps)
  envelope=$(printf 'signal: demo.status' | "$OPINPUT" encode watcher) || fail "could not encode an envelope"
  doorbell=$(printf 'away digest' | FM_STATE_OVERRIDE="$home/state" "$OPINPUT" record away-supervisor) \
    || fail "could not record a doorbell"
  mkdir -p "$TMP_ROOT/elsewhere/state"
  forged=$(printf 'forged' | FM_STATE_OVERRIDE="$TMP_ROOT/elsewhere/state" "$OPINPUT" record away-supervisor) \
    || fail "could not record a foreign doorbell"
  ENVELOPE=$envelope DOORBELL=$doorbell FORGED=$forged as_session "$home" "$SAY"'
    say main "the reply that turned the mirror on" p0
    say captain "a typed order" p1; say main "typed answer" p1
    say captain "$ENVELOPE" p2; say main "watcher answer" p2
    say captain "$(printf "\n<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>")" p3
    say main "rewake answer" p3
    say captain "$DOORBELL" p4; say main "doorbell answer" p4
    say captain "$FORGED" p5; say main "forged doorbell answer" p5
    say captain "a stamp for another turn" p6; say main "unstamped answer" p7
  ' || fail "a writer failed"
  assert_equals "captain|the reply that turned the mirror on
captain|typed answer
operational|watcher answer
operational|rewake answer
operational|doorbell answer
captain|forged doorbell answer
captain|unstamped answer" "$(mirrored "$home")" "each turn must be stamped by how its prompt arrived"
  pass "castoff: typed turns are stamped captain, and operational input, rewakes, and this home's doorbells operational"
}

# A turn-end guard that blocks a Claude Stop sends the same turn back to work
# with no new prompt, so the turn ends twice under one prompt id: only its last
# final message stands, at the first one's cursor.
test_repeats_and_later_replies_under_one_id() {
  local home
  home=$(make_home repeats)
  as_session "$home" "$SAY"'
    say captain "ship it" p1
    printf "%s" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\",\"stop_hook_active\":false,\"last_assistant_message\":\"interim reply before the guard blocked\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
    printf "%s" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\",\"stop_hook_active\":true,\"last_assistant_message\":\"the real final answer\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
    say main "the real final answer" p1
    say main "an id the record would refuse" "bad id/with space"
  ' || fail "a writer failed"
  assert_equals "000000000001|captain|the real final answer
000000000003|captain|an id the record would refuse" "$(mirrored_at "$home")" \
    "a guard-blocked Stop must leave one record with the last final message at the first cursor, and a refused id must not lose the message"
  pass "castoff: a guard-blocked turn end leaves one message, the last, at its first cursor, and an unusable id is dropped, not the message"
}

# A guard-blocked turn that answers a phone note and then ends with the reply's
# words leaves no mirrored message: the interim one is removed, and a reader
# already past it receives the removal exactly once.
test_final_message_repeating_the_turns_reply_removes_the_interim() {
  local home page cursor
  home=$(make_home interim-removed)
  mkdir -p "$home/state/inbox"
  printf 'id=1700000000-phone\nat=2026-01-01T00:00:00Z\nsource=pinnace\nannounce_marker=1\n--\nmerged yet?\n' \
    > "$home/state/inbox/1700000000-phone.note"
  as_session "$home" "$SAY"'
    say captain "ship it" p1
    printf "%s" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\",\"stop_hook_active\":false,\"last_assistant_message\":\"interim reply before the guard blocked\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
  ' || fail "a writer failed"
  page=$(FM_HOME="$home" "$INBOX" receipts) || fail "receipts failed"
  cursor=$(printf '%s' "$page" | jq -r .reply_cursor)
  assert_equals "000000000001" "$cursor" "the reader has read the interim message"
  FM_HOME="$home" "$INBOX" reply 1700000000-phone "Aye, merged." >/dev/null || fail "reply failed"
  as_session "$home" '
    for n in 1 2; do
      printf "%s" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\",\"stop_hook_active\":true,\"last_assistant_message\":\"Aye,  merged.\"}" \
        | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
    done
  ' || fail "a writer failed"
  assert_equals "" "$(mirrored "$home")" "the turn must leave no mirrored message beside its reply"
  page=$(FM_HOME="$home" "$INBOX" receipts --after "$cursor") || fail "receipts --after failed"
  assert_equals '[{"cursor":"000000000001","removed":true,"body":null}]' \
    "$(printf '%s' "$page" | jq -c '[.mate[] | {cursor, removed, body}]')" \
    "a reader past the interim message must receive its removal"
  assert_equals '["Aye, merged."]' "$(printf '%s' "$page" | jq -c '[.replies[].body]')" \
    "the reply carries the words"
  cursor=$(printf '%s' "$page" | jq -r .reply_cursor)
  page=$(FM_HOME="$home" "$INBOX" receipts --after "$cursor") || fail "receipts --after failed"
  assert_equals "0" "$(printf '%s' "$page" | jq '.mate | length')" "the removal must be served exactly once"
  pass "castoff: a final message repeating the turn's phone reply removes the interim message, served once"
}

# Cursor may deliver afterAgentResponse more than once for one generation:
# only the last text stands, as one message.
test_repeated_cursor_response_is_one_message() {
  local home
  home=$(make_home cursor-repeats)
  CURSOR_PROMPT=$(cursor_cmd beforeSubmitPrompt) CURSOR_RESPONSE=$(cursor_cmd afterAgentResponse) \
  as_session "$home" '
    run() { printf "%s" "$2" | env CURSOR_PROJECT_DIR="$PRIMARY_ROOT" bash -c "cd \"$PRIMARY_ROOT\" && $1"; }
    run "$CURSOR_PROMPT" "{\"hook_event_name\":\"beforeSubmitPrompt\",\"generation_id\":\"g1\",\"prompt\":\"status?\",\"cursor_version\":\"x\"}"
    run "$CURSOR_RESPONSE" "{\"hook_event_name\":\"afterAgentResponse\",\"generation_id\":\"g1\",\"text\":\"first text\",\"cursor_version\":\"x\"}"
    run "$CURSOR_RESPONSE" "{\"hook_event_name\":\"afterAgentResponse\",\"generation_id\":\"g1\",\"text\":\"the last text\",\"cursor_version\":\"x\"}"
  ' || fail "a tracked castoff hook failed"
  assert_equals "000000000001|captain|the last text" "$(mirrored_at "$home")" \
    "a repeated afterAgentResponse for one generation must leave one message with the last text"
  pass "castoff: a repeated Cursor response for one generation is one message, the last"
}

# Replies recorded before a turn began, before the first Cast Off or while the
# mirror was off, never suppress the turn's final message.
test_earlier_replies_never_suppress_a_final_message() {
  local home
  home=$(make_home earlier-replies 0)
  old_reply() {  # <home> <note id> <text>
    mkdir -p "$1/state/inbox"
    printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=pinnace\nannounce_marker=1\n--\nfrom the phone\n' "$2" \
      > "$1/state/inbox/$2.note"
    FM_HOME="$1" "$INBOX" reply "$2" "$3" >/dev/null || fail "reply to $2 failed"
    sed -i.bak 's/^at=.*/at=2020-01-01T00:00:00Z/' "$1/state/inbox/.replies/$2" && rm -f "$1/state/inbox/.replies/$2.bak"
  }
  old_reply "$home" 1700000000-before "Done."
  FM_HOME="$home" "$CASTOFF" on >/dev/null
  as_session "$home" "$SAY"'
    say captain "anything left?" p1; say main "Done." p1
  ' || fail "a writer failed"
  FM_HOME="$home" "$CASTOFF" off >/dev/null
  old_reply "$home" 1700000000-while-off "On it."
  FM_HOME="$home" "$CASTOFF" on >/dev/null
  as_session "$home" "$SAY"'
    say captain "take the next one" p2; say main "On it." p2
  ' || fail "a writer failed"
  assert_equals "captain|Done.
captain|On it." "$(mirrored "$home")" \
    "a final message equal to a reply from before its turn must still be mirrored"
  pass "castoff: replies from before the first Cast Off or from while the mirror was off never suppress a final message"
}

# The turn that runs Make Fast ends with the flag gone, so its own reply is
# not mirrored, and nothing after it is.
test_make_fast_turn_is_not_mirrored() {
  local home
  home=$(make_home makefast)
  as_session "$home" "$SAY"'
    say captain "a typed order" p1; say main "mirrored answer" p1
    say captain "/makefast" p2
    "$CASTOFF" off >/dev/null
    say main "The phone mirror is off." p2
    say captain "later" p3; say main "terminal only" p3
  ' || fail "a writer failed"
  assert_equals "captain|mirrored answer" "$(mirrored "$home")" "nothing after Make Fast may be mirrored"
  pass "castoff: the Make Fast turn and every later turn stay in the terminal"
}

# A PATH that logs every jq and python3 argument list, then runs the real one.
SHIM="$TMP_ROOT/argv-shim"
mkdir -p "$SHIM"
for tool in jq python3; do
  {
    printf '#!/usr/bin/env bash\nREAL=%q\n' "$(command -v "$tool")"
    cat <<'SH'
printf '%s\n' "$@" >> "$FM_HOME/argv.log"
exec "$REAL" "$@"
SH
  } > "$SHIM/$tool"
  chmod +x "$SHIM/$tool"
done

test_dialog_text_never_enters_process_arguments() {
  local home
  home=$(make_home argv)
  PATH="$SHIM:$PATH" as_session "$home" '
    printf "%s" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt_id\":\"p1\",\"prompt\":\"captain-secret-7f3a\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
    printf "%s" "{\"hook_event_name\":\"Stop\",\"prompt_id\":\"p1\",\"last_assistant_message\":\"main-secret-9c1e\"}" \
      | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$CASTOFF" hook claude
  ' || fail "a writer failed"
  assert_equals "captain|main-secret-9c1e" "$(mirrored "$home")" "the final message must be mirrored"
  [ -s "$home/argv.log" ] || fail "the writer must have run through the recording tools"
  ! grep -q 'secret' "$home/argv.log" \
    || fail "dialog text must never appear in a process argument list: $(grep -B2 'secret' "$home/argv.log")"
  assert_equals "600" "$(mode_of "$home/state/inbox/.mate/000000000001")" "a mirrored message must be owner-only"
  pass "castoff: prompts and final messages reach the mirror without ever entering a process argument list"
}

test_flag_lifecycle
test_every_harness_registration_mirrors_the_final_message
test_home_with_the_mirror_off_is_untouched
test_foreign_unowned_and_crewmate_writes_nothing
test_turns_are_stamped_captain_or_operational
test_repeats_and_later_replies_under_one_id
test_final_message_repeating_the_turns_reply_removes_the_interim
test_repeated_cursor_response_is_one_message
test_earlier_replies_never_suppress_a_final_message
test_make_fast_turn_is_not_mirrored
test_dialog_text_never_enters_process_arguments
