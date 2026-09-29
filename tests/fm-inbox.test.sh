#!/usr/bin/env bash
# tests/fm-inbox.test.sh - captain inbox capture, receipts, replies, readiness.
#
# Covers the durable order contract: request-id idempotency, the crash window
# between save and announce, saved-but-unannounced repair, the unknown
# announced state of notes that predate the marker, bounded receipts JSON with
# omission disclosure, the reply cursor's strict order, the phone mirror's
# messages sharing that order without skips or duplicates, and the readiness
# projection's model-aware verdict and unknown path. Human note/list/drain
# behaviour stays unchanged when the new flags are omitted.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox)
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
LOCK_BIN="$ROOT/bin/fm-lock.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_inbox() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" "$@"
}

run_lock() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LOCK_BIN" "$@"
}

json_get() {
  python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1:]:
    if isinstance(v, list) and k.lstrip("-").isdigit():
        v=v[int(k)]
    else:
        v=v[k]
print(v)' "$@"
}

count_notes() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

count_wakes() {
  if [ -f "$1/state/.wake-queue" ]; then
    grep -c 'inbox:' "$1/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

# --- human note path is unchanged without the new flags ---------------------

home=$(make_home human)
out=$(run_inbox "$home" note "hello from the terminal") \
  || fail "plain note should succeed"
assert_contains "$out" "queued " "plain note should print queued <id>"
assert_contains "$out" "firstmate will pick this up at its next check." \
  "plain note should keep its human announcement line"
assert_equals "1" "$(count_notes "$home")" "plain note should write one record"
assert_equals "1" "$(count_wakes "$home")" "plain note should append one wake"
list_out=$(run_inbox "$home" list) || fail "list should succeed"
assert_contains "$list_out" "hello from the terminal" "list should show the body"
pass "plain note, list, and wake stay on the historical human path"

# A saved note whose wake fails still exits 1 for callers that omit the new flags.
isolated="$TMP_ROOT/isolated"
mkdir -p "$isolated/bin"
cp "$INBOX_BIN" "$isolated/bin/fm-inbox.sh"
chmod +x "$isolated/bin/fm-inbox.sh"
home=$(make_home human-wake-fail)
set +e
fail_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note "saved but not announced" 2>&1)
fail_code=$?
set -e
expect_code 1 "$fail_code" "plain note still exits 1 when announcement fails"
assert_equals "1" "$(count_notes "$home")" \
  "plain note is saved even when announcement fails"
assert_contains "$fail_out" "queued " "plain note still prints queued before the failure"
assert_contains "$fail_out" "NOT woken" "plain note still reports the wake failure"
pass "plain note keeps exit 1 for a saved-but-unannounced failure"

# --- duplicate request id returns the original identity ---------------------

home=$(make_home idempotent)
body=$'line one\nline two\n'
first=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "first request-id note should succeed"
first_id=$(printf '%s' "$first" | json_get id)
assert_equals "created" "$(printf '%s' "$first" | json_get outcome)" \
  "first submission is created"
assert_equals "True" "$(printf '%s' "$first" | json_get saved)" \
  "first submission is saved"
assert_equals "True" "$(printf '%s' "$first" | json_get announced)" \
  "first submission is announced"
assert_equals "req-1" "$(printf '%s' "$first" | json_get request_id)" \
  "receipt carries the request id"

second=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "replay of the same request id should succeed"
assert_equals "replay" "$(printf '%s' "$second" | json_get outcome)" \
  "repeat request id is a replay, not a second create"
assert_equals "$first_id" "$(printf '%s' "$second" | json_get id)" \
  "replay returns the original note id"
assert_equals "1" "$(count_notes "$home")" \
  "the same request id must not create a second note"
assert_equals "1" "$(count_wakes "$home")" \
  "replay of an already-announced note must not append a second wake"
replay_human=$(run_inbox "$home" note --request-id req-1 "line one") \
  || fail "human replay should succeed"
assert_contains "$replay_human" "replay $first_id" \
  "human replay is distinguishable from queued"
assert_equals "1" "$(count_notes "$home")" "human replay still does not duplicate"
pass "the same request id returns the original note as a distinguishable replay"

# --- crash window: reservation exists, note not yet published ---------------

home=$(make_home crash-reserve)
mkdir -p "$home/state/inbox/.requests"
crash_id="1700000000-crashwin"
printf '%s\n' "$crash_id" > "$home/state/inbox/.requests/crash-rid"
assert_absent "$home/state/inbox/$crash_id.note" \
  "fixture starts with a reservation and no published note"
crash_out=$(run_inbox "$home" note --request-id crash-rid --json "recover me") \
  || fail "retry after a reservation-only crash should complete the original note"
assert_equals "replay" "$(printf '%s' "$crash_out" | json_get outcome)" \
  "completing a reserved request id is a replay of that request"
assert_equals "$crash_id" "$(printf '%s' "$crash_out" | json_get id)" \
  "the reserved note id is reused"
assert_present "$home/state/inbox/$crash_id.note" \
  "the retry publishes the reserved note rather than minting a new id"
assert_equals "1" "$(count_notes "$home")" \
  "crash-window retry leaves exactly one note"
assert_grep "recover me" "$home/state/inbox/$crash_id.note" \
  "the completed note carries the caller's body"
pass "a crash between recording the request id and publishing the note reuses the original id"

# --- saved-but-unannounced, then repair without a second note ---------------

home=$(make_home announce-fail)
set +e
saved_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
saved_code=$?
set -e
expect_code 3 "$saved_code" "request-id note exits 3 when saved but not announced"
assert_equals "created" "$(printf '%s' "$saved_out" | json_get outcome)" \
  "first isolated submit is created"
assert_equals "True" "$(printf '%s' "$saved_out" | json_get saved)" \
  "isolated submit saved the note"
assert_equals "False" "$(printf '%s' "$saved_out" | json_get announced)" \
  "isolated submit could not announce"
saved_id=$(printf '%s' "$saved_out" | json_get id)
assert_equals "1" "$(count_notes "$home")" "isolated submit wrote one note"
assert_equals "0" "$(count_wakes "$home")" "isolated submit wrote no wake"

set +e
replay_fail=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
replay_fail_code=$?
set -e
expect_code 3 "$replay_fail_code" "replay while still unannounced also exits 3"
assert_equals "replay" "$(printf '%s' "$replay_fail" | json_get outcome)" \
  "retry with the same request id is a replay"
assert_equals "$saved_id" "$(printf '%s' "$replay_fail" | json_get id)" \
  "unannounced retry keeps the original id"
assert_equals "1" "$(count_notes "$home")" \
  "unannounced retry must not create a second note"

repair=$(run_inbox "$home" note --request-id repair-1 --json "please announce") \
  || fail "replay with a working announcer should repair the wake"
assert_equals "replay" "$(printf '%s' "$repair" | json_get outcome)" \
  "repair is still a replay"
assert_equals "True" "$(printf '%s' "$repair" | json_get announced)" \
  "repair announces the existing note"
assert_equals "$saved_id" "$(printf '%s' "$repair" | json_get id)" \
  "repair keeps the original id"
assert_equals "1" "$(count_notes "$home")" "repair does not create a second note"
assert_equals "1" "$(count_wakes "$home")" "repair appends exactly one wake"

already=$(run_inbox "$home" announce --json "$saved_id") \
  || fail "announce of an already-announced note should succeed"
assert_equals "replay" "$(printf '%s' "$already" | json_get outcome)" \
  "second announce is already-announced"
assert_equals "1" "$(count_wakes "$home")" \
  "already-announced must not append another wake"
home=$(make_home announce-repair)
set +e
unannounced=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-2 --json "announce me" 2>/dev/null)
set -e
unannounced_id=$(printf '%s' "$unannounced" | json_get id)
assert_equals "0" "$(count_wakes "$home")" "the isolated submit wrote no wake"
repaired=$(run_inbox "$home" announce "$unannounced_id") \
  || fail "announce should repair a note this version saved but could not announce"
assert_contains "$repaired" "announced $unannounced_id" "the repair reports the announcement"
assert_equals "1" "$(count_wakes "$home")" "repairing appends exactly one wake"
pass "saved-but-unannounced notes are repairable without creating a second note"

# A note firstmate already acknowledged needs no wake, so neither the repair
# path nor a request-id replay appends one.
home=$(make_home announce-acked)
set +e
acked=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id acked-1 --json "drained before repair" 2>/dev/null)
set -e
acked_id=$(printf '%s' "$acked" | json_get id)
run_inbox "$home" drain --ack "$acked_id" >/dev/null || fail "drain --ack failed"
acked_repair=$(run_inbox "$home" announce --json "$acked_id") \
  || fail "announce of an acknowledged note should succeed without waking"
assert_equals "True" "$(printf '%s' "$acked_repair" | json_get acknowledged)" \
  "announce reports the note as already acknowledged"
assert_equals "False" "$(printf '%s' "$acked_repair" | json_get announced)" \
  "announce does not claim a wake it never appended"
acked_human=$(run_inbox "$home" announce "$acked_id") \
  || fail "human announce of an acknowledged note should succeed"
assert_contains "$acked_human" "already-acknowledged $acked_id" \
  "human announce names the acknowledgement"
acked_replay=$(run_inbox "$home" note --request-id acked-1 --json "drained before repair") \
  || fail "replay of an acknowledged note should exit 0"
assert_equals "replay" "$(printf '%s' "$acked_replay" | json_get outcome)" \
  "retry of an acknowledged note is a replay"
assert_equals "True" "$(printf '%s' "$acked_replay" | json_get acknowledged)" \
  "replay reports the note as already acknowledged"
assert_equals "0" "$(count_wakes "$home")" \
  "an acknowledged note never gets a repair wake"
pass "repair and replay do not wake firstmate for an already-acknowledged note"

# --- bounded receipts JSON, omission disclosure, reply cursor ---------------

json_len() {  # <key>
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)[sys.argv[1]]))' "$1"
}

home=$(make_home receipts)
ids=""
i=0
while [ "$i" -lt 21 ]; do
  ids="$ids $(run_inbox "$home" note --request-id "bulk-$i" "bulk body $i" \
    | sed -n 's/^queued //p')"
  i=$((i + 1))
done

receipts=$(run_inbox "$home" receipts) || fail "receipts should succeed"
assert_equals "fm-inbox-receipts.v1" "$(printf '%s' "$receipts" | json_get schema)" \
  "receipts use the receipts schema"
assert_equals "20" "$(printf '%s' "$receipts" | json_len pending)" \
  "pending list is bounded without a reveal flag"
assert_contains "$receipts" "pending notes omitted by bound: 1" \
  "receipts disclose how many pending notes they omitted"
assert_contains "$receipts" "pass --all-pending" \
  "omission names the flag that reveals pending notes"
assert_contains "$receipts" '"acknowledged":false' "pending notes are not acknowledged"

all_receipts=$(run_inbox "$home" receipts --all-pending) \
  || fail "unbounded receipts should succeed"
assert_equals "21" "$(printf '%s' "$all_receipts" | json_len pending)" \
  "--all-pending reveals every pending note"
assert_equals "[]" "$(printf '%s' "$all_receipts" | python3 -c 'import json,sys; print(json.load(sys.stdin)["omitted"])')" \
  "revealing every row leaves omitted empty"

# shellcheck disable=SC2086 # deliberate word splitting: one id per --ack arg.
run_inbox "$home" drain --ack $ids >/dev/null || fail "drain --ack of the bulk notes failed"
handled_receipts=$(run_inbox "$home" receipts) || fail "receipts after drain should succeed"
assert_equals "20" "$(printf '%s' "$handled_receipts" | json_len handled)" \
  "handled list is bounded without a reveal flag"
assert_contains "$handled_receipts" "handled notes omitted by bound: 1" \
  "receipts disclose how many handled notes they omitted"
assert_contains "$handled_receipts" "pass --all-handled" \
  "omission names the flag that reveals handled notes"
assert_equals "21" "$(run_inbox "$home" receipts --all-handled | json_len handled)" \
  "--all-handled reveals every handled note"
assert_contains "$handled_receipts" '"acknowledged":true' "handled notes are acknowledged"
pass "receipts JSON is bounded by fixed bounds and discloses what it omitted"

# A note written before this home tracked announcement markers already appended
# its own wake, and nothing proves that, so receipts say unknown rather than
# false and the repair path refuses it instead of appending a second wake.
home=$(make_home preexisting)
run_inbox "$home" note "establish the inbox" >/dev/null || fail "seed note failed"
legacy="1700000000-legacy"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\n--\nfrom before the marker\n' \
  "$legacy" > "$home/state/inbox/$legacy.note"
legacy_announced=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
rows={r["id"]: r["announced"] for r in json.load(sys.stdin)["pending"]}
print(json.dumps(rows[sys.argv[1]]))' "$legacy")
assert_equals "null" "$legacy_announced" \
  "a note that predates the marker reports announced as unknown, not false"
fresh_announced=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
print(json.dumps([r["announced"] for r in json.load(sys.stdin)["pending"] if r["id"] != sys.argv[1]]))' "$legacy")
assert_equals "[true]" "$fresh_announced" \
  "a note this version wrote still reports a definite announced state"
before_wakes=$(count_wakes "$home")
set +e
legacy_out=$(run_inbox "$home" announce "$legacy" 2>&1)
legacy_code=$?
set -e
expect_code 1 "$legacy_code" "announcing a note with an unknown announced state is refused"
assert_contains "$legacy_out" "UNKNOWN" "the refusal says the announced state is unknown"
assert_equals "$before_wakes" "$(count_wakes "$home")" \
  "the refused repair must not append a second wake"
pass "notes that predate the announcement marker are unknown, not re-announced"

# Reply cursor: replies recorded within the same second are both readable, in
# recording order, even when the later note id sorts below the earlier one.
home=$(make_home cursor)
mkdir -p "$home/state/inbox"
later="1700000000-aaaaaa"
earlier="1700000000-zzzzzz"
for nid in "$earlier" "$later"; do
  printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder %s\n' \
    "$nid" "$nid" > "$home/state/inbox/$nid.note"
done
run_inbox "$home" reply "$earlier" "answer one" >/dev/null || fail "first reply failed"
run_inbox "$home" reply "$later" "answer two" >/dev/null || fail "second reply failed"
replies=$(run_inbox "$home" receipts --all-replies) || fail "receipts with replies should succeed"
assert_equals "2" "$(printf '%s' "$replies" | json_len replies)" \
  "both replies appear without a cursor"
order=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(" ".join(r["id"] for r in json.load(sys.stdin)["replies"]))')
assert_equals "$earlier $later" "$order" "replies are ordered by when they were recorded"
first_cursor=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(json.load(sys.stdin)["replies"][0]["cursor"])')
after=$(run_inbox "$home" receipts --all-replies --after "$first_cursor") \
  || fail "receipts --after should succeed"
assert_equals "1" "$(printf '%s' "$after" | json_len replies)" \
  "--after returns only replies recorded later"
after_id=$(printf '%s' "$after" | python3 -c 'import json,sys; print(json.load(sys.stdin)["replies"][0]["id"])')
assert_equals "$later" "$after_id" \
  "a same-second reply recorded after the cursor is still delivered"

set +e
conflict=$(run_inbox "$home" reply "$earlier" "answer one" 2>&1)
conflict_code=$?
set -e
expect_code 1 "$conflict_code" "a second reply for the same note is refused"
assert_contains "$conflict" "already recorded" "the refusal names the existing record"
pass "the reply channel is durable and its cursor is a strict order"

# A lost sequence counter must not move the cursor backwards: the next reply
# still sorts after every reply a client has already read.
lost_cursor=$(printf '%s' "$replies" | python3 -c 'import json,sys
print(json.load(sys.stdin)["reply_cursor"])')
rm -f "$home/state/inbox/.replies/.seq"
third="1700000000-mmmmmm"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder three\n' \
  "$third" > "$home/state/inbox/$third.note"
run_inbox "$home" reply "$third" "answer three" >/dev/null || fail "third reply failed"
after_lost=$(run_inbox "$home" receipts --after "$lost_cursor") \
  || fail "receipts after a lost counter should succeed"
assert_equals "$third" "$(printf '%s' "$after_lost" | json_get replies 0 id)" \
  "a reply recorded after the counter was lost is still after the client cursor"
pass "the reply cursor never goes backwards when the sequence counter is lost"

# A reply without a valid sequence is malformed: it gets no invented position
# and receipts say so instead of silently ordering it.
home=$(make_home malformed-reply)
mkdir -p "$home/state/inbox/.replies"
bad="1700000000-badseq"
printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\nannounce_marker=1\n--\norder\n' \
  "$bad" > "$home/state/inbox/$bad.note"
printf 'id=%s\nat=2026-01-01T00:00:00Z\n--\nno sequence here\n' \
  "$bad" >"$home/state/inbox/.replies/$bad"
malformed=$(run_inbox "$home" receipts) || fail "receipts with a malformed reply should succeed"
assert_equals "0" "$(printf '%s' "$malformed" | json_len replies)" \
  "a reply without a sequence is not placed in the reply stream"
assert_contains "$malformed" "malformed replies without a valid sequence: 1 ($bad)" \
  "receipts name the malformed reply"
pass "a reply without a valid sequence is reported as malformed"

# --- mirrored first-mate messages (mate) ------------------------------------

seed_note() {  # <home> <id>
  mkdir -p "$1/state/inbox"
  printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=pinnace\nannounce_marker=1\n--\nfrom the phone\n' \
    "$2" > "$1/state/inbox/$2.note"
}

mate() {  # <home> <body> [mate flags...]
  local home=$1 body=$2
  shift 2
  printf '%s' "$body" | run_inbox "$home" mate "$@" -
}

cursors() {  # <key> -> "<cursor>" per row, one line
  python3 -c 'import json,sys; print(" ".join(r["cursor"] for r in json.load(sys.stdin)[sys.argv[1]]))' "$1"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# One sequence orders replies and mirrored messages: a mirrored message takes
# the number after a reply, and a later reply takes the number after it.
home=$(make_home mate-order)
seed_note "$home" 1700000000-first
seed_note "$home" 1700000000-second
run_inbox "$home" reply 1700000000-first "answer one" >/dev/null || fail "first reply failed"
assert_equals "created 2" "$(mate "$home" "mirrored one" --id p1 --turn captain)" \
  "a mirrored message takes the sequence after the reply"
run_inbox "$home" reply 1700000000-second "answer two" >/dev/null || fail "second reply failed"
assert_equals "created 4" "$(mate "$home" "mirrored two" --id p2 --turn operational)" \
  "a later mirrored message takes the sequence after the later reply"
receipts=$(run_inbox "$home" receipts) || fail "receipts with mirrored messages should succeed"
assert_equals "000000000001 000000000003" "$(printf '%s' "$receipts" | cursors replies)" \
  "replies keep their own cursors in the shared order"
assert_equals "000000000002 000000000004" "$(printf '%s' "$receipts" | cursors mate)" \
  "mirrored messages carry cursors in the shared order"
assert_equals "operational" "$(printf '%s' "$receipts" | json_get mate 1 turn)" \
  "a mirrored message keeps its turn stamp"
assert_equals "p1" "$(printf '%s' "$receipts" | json_get mate 0 id)" \
  "a mirrored message keeps its turn id"
assert_equals "000000000004" "$(printf '%s' "$receipts" | json_get reply_cursor)" \
  "the receipts cursor covers both kinds"
after=$(run_inbox "$home" receipts --after 000000000002) || fail "receipts --after should succeed"
assert_equals "000000000003" "$(printf '%s' "$after" | cursors replies)" \
  "--after returns only replies strictly after the cursor"
assert_equals "000000000004" "$(printf '%s' "$after" | cursors mate)" \
  "--after returns only mirrored messages strictly after the cursor"
pass "replies and mirrored messages share one sequence and one receipts cursor"

# A mirrored message is recorded once: the same id and text replay, a
# different text under the same id updates the message at its cursor, and an
# empty body or a missing turn is refused.
assert_equals "replay 2" "$(mate "$home" "mirrored one" --id p1 --turn captain)" \
  "the same id and text replays the recorded message"
assert_equals "updated 2" "$(mate "$home" "a later final reply" --id p1 --turn captain)" \
  "a different text under the same id updates the message at its cursor"
set +e
empty_out=$(mate "$home" "$(printf ' \n\t ')" --turn captain 2>&1)
empty_code=$?
noturn_out=$(mate "$home" "no turn" 2>&1)
noturn_code=$?
set -e
expect_code 1 "$empty_code" "an empty mirrored message is refused"
assert_contains "$empty_out" "refusing to record an empty message" "the refusal names the empty message"
expect_code 1 "$noturn_code" "a mirrored message without a turn stamp is refused"
assert_contains "$noturn_out" "usage: fm-inbox.sh mate" "the refusal shows the usage"
assert_equals "2" "$(find "$home/state/inbox/.mate" -maxdepth 1 -type f ! -name '.*' | wc -l | tr -d ' ')" \
  "replays, updates, and refusals add no record"
pass "a mirrored message replays by id and text, updates by id, and an empty or unstamped one is refused"

# A reader already past an updated message's cursor receives it once more, at
# its original cursor, and then not again.
page=$(run_inbox "$home" receipts --after 000000000004) || fail "receipts past the updated cursor failed"
assert_equals "000000000002" "$(printf '%s' "$page" | cursors mate)" \
  "the updated message is served again at its original cursor"
assert_equals "a later final reply" "$(printf '%s' "$page" | json_get mate 0 body)" \
  "the updated message carries its new body"
assert_equals "0" "$(printf '%s' "$page" | json_len replies)" "no reply is served twice"
cursor=$(printf '%s' "$page" | json_get reply_cursor)
assert_equals "000000000005" "$cursor" "the receipts cursor moves to the update"
page=$(run_inbox "$home" receipts --after "$cursor") || fail "receipts past the update failed"
assert_equals "0" "$(printf '%s' "$page" | json_len mate)" "the update is served exactly once"
assert_equals "000000000002 000000000004" "$(run_inbox "$home" receipts | cursors mate)" \
  "a full read still holds one message per cursor"
seed_note "$home" 1700000000-third
run_inbox "$home" reply 1700000000-third "answer three" >/dev/null || fail "third reply failed"
assert_equals "000000000006" "$(run_inbox "$home" receipts --after "$cursor" | cursors replies)" \
  "a reply after an update takes the sequence after the update"
pass "an updated mirrored message reaches a reader past its cursor exactly once"

# The turn that answered a phone note with a reply and ends with the same
# words is one message, not two; different words stay two messages.
home=$(make_home mate-duplicate)
seed_note "$home" 1700000000-phone
seed_note "$home" 1700000000-later
mate "$home" "an earlier turn" --id p0 --turn captain >/dev/null || fail "seed mirrored message failed"
since=$(date +%s)
run_inbox "$home" reply 1700000000-phone "Aye, the fix is merged." >/dev/null || fail "reply failed"
assert_equals "duplicate 1700000000-phone" \
  "$(mate "$home" "$(printf '  Aye, the fix\nis merged.  ')" --id p1 --since "$since" --turn captain)" \
  "a final message equal to the same turn's reply is a duplicate of that reply"
assert_equals "created 3" "$(mate "$home" "Aye, the fix is merged. The next one is under way." --id p1 --since "$since" --turn captain)" \
  "a final message with different words is recorded beside the reply"
assert_equals "created 4" "$(mate "$home" "Aye, the fix is merged." --id p2 --since "$since" --turn captain)" \
  "a reply recorded before the newest mirrored message belongs to an earlier turn"
pass "a final message repeating the same turn's phone reply is recorded once, as the reply"

# A reply recorded before the turn started never suppresses its final message:
# not on the first Cast Off, with no mirrored message yet, and not after a
# Make Fast then Cast Off, with replies recorded while the mirror was off.
home=$(make_home mate-earlier-turn)
seed_note "$home" 1700000000-old
seed_note "$home" 1700000000-off
run_inbox "$home" reply 1700000000-old "Done." >/dev/null || fail "old reply failed"
later=$(( $(date +%s) + 5 ))
assert_equals "created 2" "$(mate "$home" "Done." --id p1 --since "$later" --turn captain)" \
  "a reply from before the first Cast Off does not suppress a final message"
run_inbox "$home" reply 1700000000-off "On it." >/dev/null || fail "reply while off failed"
assert_equals "created 4" "$(mate "$home" "On it." --id p2 --since "$later" --turn captain)" \
  "a reply recorded while the mirror was off does not suppress a final message"
assert_equals "created 5" "$(printf 'On it.' | run_inbox "$home" mate --id p3 --turn captain -)" \
  "without a turn start no reply counts as this turn's"
pass "a final message equal to a reply from before its turn is still mirrored"

# Long messages keep their head and tail inside the 8000-character cap, the
# records are owner-only, and no mirrored message ever wakes firstmate.
home=$(make_home mate-cap)
long="HEAD$(awk 'BEGIN { for (i = 0; i < 9000; i++) printf "x" }')TAIL"
(umask 022; mate "$home" "$long" --id long --turn captain >/dev/null) || fail "a long mirrored message should be recorded"
body=$(run_inbox "$home" receipts | json_get mate 0 body)
[ "${#body}" -eq 8000 ] || fail "a capped mirrored message must hold 8000 characters with its note, got ${#body}"
kept=$(printf '%s' "$body" | tr -cd x | wc -c | tr -d ' ')
assert_contains "$body" "[mirror truncated: $((9000 - kept)) characters omitted]" \
  "a capped message names how much it left out"
case "$body" in HEAD*TAIL) ;; *) fail "a capped message must keep its head and its tail" ;; esac
assert_equals "replay 1" "$(mate "$home" "$long" --id long --turn captain)" \
  "a capped message replays against its capped record"
assert_equals "600" "$(mode_of "$home/state/inbox/.mate/000000000001")" \
  "a mirrored message is owner-only"
assert_equals "0" "$(count_wakes "$home")" "a mirrored message appends no wake"
assert_absent "$home/state/.wake-queue" "a mirrored message never touches the wake queue"
pass "a long mirrored message keeps head and tail within the cap, is owner-only, and wakes nothing"

# Without --after each list is a snapshot of its newest rows, so the phone
# never stalls past 20 mirrored messages; with --after, a list cut by its bound
# never lets the shared cursor skip the other list's unread entries, and every
# entry arrives exactly once across pages.
home=$(make_home mate-pages)
i=0
while [ "$i" -lt 25 ]; do
  mate "$home" "message $i" --id "m$i" --turn operational >/dev/null || fail "mirrored message $i failed"
  i=$((i + 1))
done
seed_note "$home" 1700000000-late
run_inbox "$home" reply 1700000000-late "a late reply" >/dev/null || fail "late reply failed"
page=$(run_inbox "$home" receipts) || fail "the snapshot failed"
assert_equals "20" "$(printf '%s' "$page" | json_len mate)" "mirrored messages are bounded to 20"
assert_equals "000000000006" "$(printf '%s' "$page" | json_get mate 0 cursor)" \
  "the snapshot holds the newest mirrored messages, not the oldest"
assert_equals "message 24" "$(printf '%s' "$page" | json_get mate 19 body)" \
  "the snapshot ends at the newest mirrored message"
assert_equals "000000000026" "$(printf '%s' "$page" | cursors replies)" "the snapshot holds the newest reply"
assert_contains "$page" "mirrored messages omitted by bound: 5" "receipts disclose the omitted mirrored messages"
assert_contains "$page" "pass --all-mate" "omission names the flag that reveals mirrored messages"
assert_equals "000000000026" "$(printf '%s' "$page" | json_get reply_cursor)" \
  "the snapshot's cursor is the newest entry in either list"
mate "$home" "after the snapshot" --id m25 --turn operational >/dev/null || fail "mirrored message 25 failed"
page=$(run_inbox "$home" receipts --after 000000000026) || fail "the page after the snapshot failed"
assert_equals "000000000027" "$(printf '%s' "$page" | cursors mate)" \
  "a reader continuing from the snapshot gets only what came after it"
assert_equals "0" "$(printf '%s' "$page" | json_len replies)" "the snapshot's reply is not repeated"

page=$(run_inbox "$home" receipts --after 000000000000) || fail "first page failed"
assert_equals "20" "$(printf '%s' "$page" | json_len mate)" "an --after page is bounded to 20"
assert_equals "000000000001" "$(printf '%s' "$page" | json_get mate 0 cursor)" "an --after page starts oldest first"
assert_equals "0" "$(printf '%s' "$page" | json_len replies)" \
  "a reply after the cut is held for the next page"
cursor=$(printf '%s' "$page" | json_get reply_cursor)
assert_equals "000000000020" "$cursor" "the cursor stops at the cut"
page=$(run_inbox "$home" receipts --after "$cursor") || fail "second page failed"
assert_equals "6" "$(printf '%s' "$page" | json_len mate)" "the second page carries the rest of the mirrored messages"
assert_equals "000000000026" "$(printf '%s' "$page" | cursors replies)" "the second page carries the held reply"
assert_equals "26" "$(run_inbox "$home" receipts --all-mate | json_len mate)" "--all-mate reveals every mirrored message"
pass "bounded pages of replies and mirrored messages never skip or repeat an entry"

# A mirrored message without a valid sequence or turn is malformed, and the
# oldest records are pruned once the retention bound is passed.
home=$(make_home mate-malformed)
mate "$home" "a sound message" --turn captain >/dev/null || fail "sound mirrored message failed"
printf 'at=2026-01-01T00:00:00Z\nturn=captain\n--\nno sequence\n' > "$home/state/inbox/.mate/nosequence"
printf 'seq=9\nat=2026-01-01T00:00:00Z\nturn=loud\n--\nbad turn\n' > "$home/state/inbox/.mate/badturn"
malformed=$(run_inbox "$home" receipts) || fail "receipts with a malformed mirrored message should succeed"
assert_equals "1" "$(printf '%s' "$malformed" | json_len mate)" "malformed mirrored messages are not placed in the stream"
assert_contains "$malformed" "malformed mirrored messages without a valid sequence or turn: 2 (badturn, nosequence)" \
  "receipts name the malformed mirrored messages"
pass "a mirrored message without a valid sequence or turn is reported as malformed"

home=$(make_home mate-retention)
mkdir -p "$home/state/inbox/.mate"
i=1
while [ "$i" -le 600 ]; do
  printf 'seq=%s\nat=2026-01-01T00:00:00Z\nid=\nturn=operational\n--\nold %s\n' "$i" "$i" \
    > "$home/state/inbox/.mate/$(printf '%012d' "$i")"
  i=$((i + 1))
done
assert_equals "created 601" "$(mate "$home" "the newest" --turn captain)" "a message past the bound is still recorded"
assert_equals "500" "$(find "$home/state/inbox/.mate" -maxdepth 1 -type f ! -name '.*' | wc -l | tr -d ' ')" \
  "the oldest mirrored messages are pruned to the retention bound"
assert_absent "$home/state/inbox/.mate/000000000101" "the oldest records go first"
assert_present "$home/state/inbox/.mate/000000000102" "the newest records stay"
pass "mirrored messages are pruned oldest first past the retention bound"

# One undecodable note must not fail the whole receipts view.
home=$(make_home non-utf8)
run_inbox "$home" note "readable note" >/dev/null || fail "seed note failed"
printf 'id=1700000000-binary\nat=2026-01-01T00:00:00Z\nsource=text\n--\n\377\376 bytes\n' \
  > "$home/state/inbox/1700000000-binary.note"
binary=$(run_inbox "$home" receipts) || fail "receipts must survive a non-UTF-8 note"
assert_equals "2" "$(printf '%s' "$binary" | json_len pending)" \
  "the undecodable note and the readable note are both listed"
pass "a non-UTF-8 note does not break the receipts view"

# --- readiness projection, including unknown -------------------------------

home=$(make_home ready-free)
ready=$(run_inbox "$home" ready) || fail "ready should succeed with no lock"
assert_equals "fm-primary-ready.v1" "$(printf '%s' "$ready" | json_get schema)" \
  "ready uses the readiness schema"
assert_equals "free" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "no lock file is free, not live"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a free lock cannot receive work"
assert_equals "present" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["posture"]["state"])')" \
  "no away flag is present posture"

# A live non-harness pid in the lock file must not be treated as a live primary.
home=$(make_home ready-unknown)
printf '%s\n' "$$" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for an unclassified pid"
lock_state=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')
assert_equals "unknown" "$lock_state" \
  "a live process that is not a verified harness is unknown, not held"
live=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["live_harness"])')
assert_equals "False" "$live" "a bash test pid is not a live harness"
can=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')
[ "$can" = "False" ] || [ "$can" = "unknown" ] \
  || fail "unknown lock must not claim can_receive true (got $can)"

human_lock=$(run_lock "$home" status) || fail "lock status should succeed"
assert_contains "$human_lock" "stale (pid $$ dead or not a harness)" \
  "human lock status keeps its historical stale wording"

# Dead pid is stale, not held.
home=$(make_home ready-stale)
printf '%s\n' "999999" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a dead pid"
assert_equals "stale" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a dead recorded pid is stale"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a stale lock cannot receive work"

# Existence of a pane-like leftover must not become liveness: unreadable lock.
home=$(make_home ready-unreadable)
mkdir -p "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a directory lock"
assert_equals "unreadable" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a non-file lock is unreadable rather than held"
# A Claude primary mid-turn runs no watcher process - its watcher is armed at
# turn end - so the model-aware supervision verdict, not the pid-strict watcher
# check, owns whether the wake will be drained.
home=$(make_home ready-midturn)
touch "$home/state/.last-watcher-beat"
midturn=$(FM_SUPERVISION_MODEL=autoarm run_inbox "$home" ready) \
  || fail "ready should succeed for a mid-turn autoarm primary"
assert_equals "healthy" "$(printf '%s' "$midturn" | json_get wake_consumer state)" \
  "a mid-turn autoarm primary with a fresh beacon has a healthy wake consumer"

# A home that never ran a watcher has no observation, so it reports no age
# rather than the missing-path sentinel. With no lock holder the model is
# unknown for this home, which is the honest caller path.
home=$(make_home ready-no-beacon)
nobeat=$(run_inbox "$home" ready) || fail "ready should succeed with no beacon"
assert_equals "supervision-model-unknown-for-home" \
  "$(printf '%s' "$nobeat" | json_get wake_consumer reason)" \
  "no lock holder means the home's supervision model is unknown"
assert_equals "None" "$(printf '%s' "$nobeat" | json_get wake_consumer beacon_age_seconds)" \
  "a beacon that does not exist has no age"

# The intended caller (HTTP backend, ssh host fm-inbox.sh ready) does not set
# FM_SUPERVISION_MODEL. A live non-harness lock pid must not invent a model
# from the caller's own process tree.
home=$(make_home ready-no-override)
printf '%s\n' "$$" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
no_override=$(run_inbox "$home" ready) || fail "ready should succeed with no model override"
assert_equals "unknown" "$(printf '%s' "$no_override" | json_get wake_consumer state)" \
  "without a lock-holder harness, wake-consumer is unknown"
assert_equals "supervision-model-unknown-for-home" \
  "$(printf '%s' "$no_override" | json_get wake_consumer reason)" \
  "the unknown reason names that the model could not be determined for this home"
can=$(printf '%s' "$no_override" | json_get can_receive)
assert_equals "unknown" "$can" "unknown lock plus unknown consumer is not can_receive true"

# A live lock holder whose ancestry names a known harness, plus a fresh
# beacon, is the yes path: the inspected home can receive work.
home=$(make_home ready-holder)
# A process whose ps comm is the harness name, so lock inspect and
# fm-harness.sh ancestry both classify it without PATH tricks.
perl -e '$0="claude"; sleep 60' &
holder_pid=$!
# Give ps a moment to report the renamed comm.
sleep 0.2
kill_holder() {
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}
trap 'kill_holder; fm_test_cleanup' EXIT
printf '%s\n' "$holder_pid" > "$home/state/.lock"
touch "$home/state/.last-watcher-beat"
held=$(run_inbox "$home" ready) || fail "ready should succeed for a lock-holder harness"
assert_equals "held" "$(printf '%s' "$held" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a live claude-named holder is a held lock"
assert_equals "healthy" "$(printf '%s' "$held" | json_get wake_consumer state)" \
  "lock-holder ancestry plus a fresh beacon is a healthy wake consumer"
assert_equals "True" "$(printf '%s' "$held" | json_get can_receive)" \
  "a held lock with a healthy wake consumer can receive work"
kill_holder
trap fm_test_cleanup EXIT
pass "readiness says unknown (or not-receivable) instead of inferring liveness from a lock"

# --- invalid input ----------------------------------------------------------

home=$(make_home invalid)
set +e
empty_out=$(run_inbox "$home" note --request-id x --json "   " 2>&1)
empty_code=$?
bad_out=$(run_inbox "$home" note --request-id '../etc/passwd' --json "nope" 2>&1)
bad_code=$?
# An empty request id must be refused, never treated as "no request id given":
# falling through to the non-idempotent path would make a retry a second note.
blank_out=$(run_inbox "$home" note --request-id '' --json "silently duplicated" 2>&1)
blank_code=$?
set -e
expect_code 1 "$empty_code" "empty body is still refused"
expect_code 1 "$bad_code" "path-like request ids are refused"
expect_code 1 "$blank_code" "an empty request id is refused, not ignored"
assert_contains "$empty_out" "empty" "empty-body refusal says the note was empty"
assert_contains "$bad_out" "invalid request id" "unsafe request ids are rejected by name"
assert_contains "$blank_out" "invalid request id" "an empty request id is rejected by name"
assert_equals "0" "$(count_notes "$home")" "refusals must not write a note"
pass "empty bodies and unsafe request ids are refused"

# The voice handover passes a raw transcript as the first argument, so a body
# that opens with a double dash is text, not an option.
home=$(make_home dash-body)
transcript="--- handover: ship the console backend --now"
dash_out=$(run_inbox "$home" note "$transcript") \
  || fail "a note body opening with dashes should be queued"
assert_contains "$dash_out" "queued " "a dash-leading body is queued like any other"
assert_equals "1" "$(count_notes "$home")" "a dash-leading body writes one note"
dash_body=$(run_inbox "$home" receipts --all-pending | python3 -c 'import json,sys
print(json.load(sys.stdin)["pending"][0]["body"])')
assert_equals "$transcript" "$dash_body" "the transcript is stored verbatim"
escaped=$(run_inbox "$home" note -- "--request-id is body text here") \
  || fail "-- should end option parsing"
assert_contains "$escaped" "queued " "-- escapes a body that looks like a flag"
pass "a note body that opens with a double dash is queued as text"

# --- note provenance: --source and --meta -----------------------------------

# The pinnace (the phone channel) queues its orders as notes that say who
# spoke, through the same header block `say` already fills for its extras.
home=$(make_home provenance)
prov_out=$(run_inbox "$home" note --source pinnace --meta node=phone --meta login=captain@example --json "merge it when green") \
  || fail "a note with --source and --meta should be queued"
prov_id=$(printf '%s' "$prov_out" | json_get id)
prov_record="$home/state/inbox/$prov_id.note"
assert_present "$prov_record" "the provenance note is recorded"
prov_headers=$(sed -n '/^--$/q;p' "$prov_record")
assert_contains "$prov_headers" "source=pinnace" "the record names the pinnace as its source"
assert_contains "$prov_headers" "node=phone" "the record carries the node header"
assert_contains "$prov_headers" "login=captain@example" "the record carries the login header"
prov_receipts=$(run_inbox "$home" receipts) || fail "receipts of a provenance note should succeed"
assert_equals "pinnace" "$(printf '%s' "$prov_receipts" | json_get pending 0 source)" \
  "receipts return the pinnace source"
assert_equals "merge it when green" "$(printf '%s' "$prov_receipts" | json_get pending 0 body)" \
  "the provenance headers leave the body unchanged"
default_out=$(run_inbox "$home" note --json "typed at the desk") || fail "a plain note should still queue"
default_id=$(printf '%s' "$default_out" | json_get id)
assert_equals "text" "$(sed -n 's/^source=//p' "$home/state/inbox/$default_id.note")" \
  "the default source stays text"
set +e
space_source_out=$(run_inbox "$home" note --source 'pin nace' --json "nope" 2>&1)
space_source_code=$?
path_source_out=$(run_inbox "$home" note --source '../x' --json "nope" 2>&1)
path_source_code=$?
forged_meta_out=$(run_inbox "$home" note --meta 'source=forged' --json "nope" 2>&1)
forged_meta_code=$?
bare_meta_out=$(run_inbox "$home" note --meta 'novalue' --json "nope" 2>&1)
bare_meta_code=$?
newline_meta_out=$(run_inbox "$home" note --meta "$(printf 'node=phone\nid=forged')" --json "nope" 2>&1)
newline_meta_code=$?
set -e
expect_code 1 "$space_source_code" "a source token with a space is refused"
expect_code 1 "$path_source_code" "a path-like source token is refused"
expect_code 1 "$forged_meta_code" "a meta key that reuses a fixed header is refused"
expect_code 1 "$bare_meta_code" "a meta without = is refused"
expect_code 1 "$newline_meta_code" "a meta value with a line break is refused"
assert_contains "$space_source_out" "invalid source token" "an invalid source is rejected by name"
assert_contains "$path_source_out" "invalid source token" "a path-like source is rejected by name"
assert_contains "$forged_meta_out" "invalid --meta" "a reused header name is rejected by name"
assert_contains "$bare_meta_out" "invalid --meta" "a meta without = is rejected by name"
assert_contains "$newline_meta_out" "invalid --meta" "a line break in a meta value is rejected by name"
assert_equals "2" "$(count_notes "$home")" "refused provenance flags write no note"
pass "a note records its source and provenance headers, defaults to text, and refuses malformed tokens"

# --- drain still acks by moving the note ------------------------------------

home=$(make_home drain)
queued=$(run_inbox "$home" note "ack me") || fail "note for drain failed"
did=${queued#queued }
did=${did%%$'\n'*}
run_inbox "$home" drain --ack "$did" >/dev/null || fail "drain --ack failed"
assert_absent "$home/state/inbox/$did.note" "acked note leaves pending"
assert_present "$home/state/inbox/handled/$did.note" "acked note is in handled"
pass "drain --ack still moves the note to handled"
