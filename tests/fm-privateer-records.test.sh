#!/usr/bin/env bash
# tests/fm-privateer-records.test.sh - the Privateer record writer,
# bin/fm-privateer-records.py, with real processes and no harness: a stand-in
# first mate (a process that runs each script it is handed as its own child)
# and its children publish, append to, and remove task records through it,
# while the test's own shell, a sibling process, and an orphan of the first
# mate are refused and logged; once the first mate's process ends everything is
# refused, and a writer whose first mate does not run with the recorded start
# time never starts, whatever LC_TIME the captain's shell sets; a publish may
# ask for 0600 or a mode no wider than the writer's default, an append keeps the
# record's mode, and a wider mode is refused; ids that name nothing in the state
# directory, oversized content, and an append to a missing record are refused;
# and a publish is
# whole, so a reader never sees half a record and a bystander rewriting
# everything else in state/ changes nothing, because nothing is staged there.
# bin/fm-privateer-records.py's header owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-privateer-records)
WRITER="$ROOT/bin/fm-privateer-records.py"
# A Unix socket path must stay short, so the sockets live in a short directory.
SOCK_DIR=$(mktemp -d /tmp/pv-records.XXXXXX)
STARTED=()

cleanup() {
  local pid
  for pid in "${STARTED[@]+"${STARTED[@]}"}"; do kill "$pid" 2>/dev/null; done
  rm -rf "$SOCK_DIR"
  fm_test_cleanup
}
trap cleanup EXIT

if ! command -v python3 >/dev/null 2>&1; then
  pass "record writer checks not run: python3 is not available on this machine"
  exit 0
fi

# wait_for_file <path>: up to ten seconds for <path> to exist.
wait_for_file() {
  local _
  for _ in $(seq 100); do
    [ -e "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

# make_case <name>: a state directory, a writer directory, and a socket for one
# case; sets DIR, STATE, EGRESS, SOCK.
make_case() {
  DIR="$TMP_ROOT/$1"
  STATE="$DIR/state"
  EGRESS="$DIR/egress"
  SOCK="$SOCK_DIR/$1"
  mkdir -p "$STATE" "$EGRESS"
}

# start_first_mate: a stand-in first mate in DIR that runs each script path
# written to DIR/in as its own child, leaving its output and exit status in
# <script>.done; sets MATE_PID.
start_first_mate() {
  mkfifo "$DIR/in"
  bash -c 'exec 3<>"$1"
    while IFS= read -r script <&3; do
      bash "$script" > "$script.out" 2>&1
      echo "rc=$?" >> "$script.out"
      mv "$script.out" "$script.done"
    done' _ "$DIR/in" &
  MATE_PID=$!
  STARTED+=("$MATE_PID")
}

# as_first_mate <name> <script>: run <script> as a child of the stand-in first
# mate; prints its output and a final rc=<status> line.
as_first_mate() {
  printf '%s\n' "$2" > "$DIR/$1.sh"
  printf '%s\n' "$DIR/$1.sh" > "$DIR/in"
  wait_for_file "$DIR/$1.sh.done" || fail "the stand-in first mate never ran $1"
  cat "$DIR/$1.sh.done"
}

# start_writer <anchor-pid> [<anchor-start>]: the record writer for that
# process on SOCK, its start time read under LC_ALL=C as the launcher reads it;
# sets WRITER_PID.
start_writer() {
  local start=${2:-$(LC_ALL=C ps -o lstart= -p "$1")}
  python3 -I "$WRITER" serve "$SOCK" "$STATE" "$EGRESS" "$1" "$start" 2>> "$DIR/writer.err" &
  WRITER_PID=$!
  STARTED+=("$WRITER_PID")
  wait_for_file "$EGRESS/records.ready" || fail "the record writer never listened: $(cat "$DIR/writer.err" 2>/dev/null)"
}

# request <op> [<id>]: one request from this process, the content on stdin.
request() {
  python3 -I "$WRITER" request "$SOCK" "$@" 2>&1
}

# client <op> [<id>]: the request command line for a script.
client() {
  printf "python3 -I '%s' request '%s' %s" "$WRITER" "$SOCK" "$*"
}

test_the_first_mate_publishes_appends_and_removes() {
  local out mode
  make_case lineage
  start_first_mate
  start_writer "$MATE_PID"
  out=$(as_first_mate ping "$(client ping)")
  assert_equals "rc=0" "$out" "the first mate's own child must be accepted"
  out=$(as_first_mate publish "printf 'window=w\nharness=opencode\n' | $(client publish pv-a)")
  assert_equals "rc=0" "$out" "the first mate must publish a record"
  assert_equals $'window=w\nharness=opencode' "$(cat "$STATE/pv-a.meta")" "the record must hold exactly the published content"
  mode=$(umask)
  mode=$(printf '%o' $((0666 & ~0$mode)))
  assert_equals "$mode" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$STATE/pv-a.meta")" \
    "a new record must get the mode a shell redirection gives it"
  out=$(as_first_mate append "printf 'decisions_reviewed=1\n' | $(client append pv-a)")
  assert_equals "rc=0" "$out" "the first mate must append to its record"
  assert_equals $'window=w\nharness=opencode\ndecisions_reviewed=1' "$(cat "$STATE/pv-a.meta")" "the append must add exactly its lines"
  out=$(as_first_mate grandchild "bash -c \"$(client remove pv-a)\"")
  assert_equals "rc=0" "$out" "a process the first mate's child starts must be accepted too"
  [ ! -e "$STATE/pv-a.meta" ] || fail "the record must be gone after its removal"
  out=$(as_first_mate again "$(client remove pv-a)")
  assert_equals "rc=0" "$out" "removing a record that is already gone must succeed"
  kill "$WRITER_PID"
  wait "$WRITER_PID" 2>/dev/null
  [ ! -e "$SOCK" ] && [ ! -e "$EGRESS/records.ready" ] || fail "a stopped writer must remove its socket and ready file"
  pass "the first mate and every process it starts publish, append to, and remove task records through the writer"
}

test_a_process_outside_the_first_mates_lineage_is_refused() {
  local out sibling orphan
  make_case outside
  start_first_mate
  start_writer "$MATE_PID"
  as_first_mate seed "printf 'window=w\n' | $(client publish pv-b)" >/dev/null
  out=$(printf 'window=forged\n' | request publish pv-b)
  expect_code 1 "$?" "the first mate's parent must be refused: $out"
  assert_equals "refused: only the first mate and the processes it starts may write task records" "$out" "the refusal must say who may write"
  out=$(request remove pv-b)
  expect_code 1 "$?" "a removal from outside the lineage must be refused: $out"
  bash -c 'printf "window=forged\n" | python3 -I "$1" request "$2" append pv-b > "$3" 2>&1; echo "rc=$?" >> "$3"' \
    _ "$WRITER" "$SOCK" "$DIR/sibling.out" &
  sibling=$!
  STARTED+=("$sibling")
  wait "$sibling"
  assert_contains "$(cat "$DIR/sibling.out")" "rc=1" "a sibling of the first mate must be refused"
  # A child the first mate detaches: it waits until the shell that started it
  # has exited, so it no longer descends from the first mate, then writes.
  cat > "$DIR/orphan.sh" <<SH
for _ in \$(seq 100); do kill -0 "\$1" 2>/dev/null || break; sleep 0.05; done
printf 'window=forged\n' | $(client publish pv-b) > '$DIR/orphan.tmp' 2>&1
echo "rc=\$?" >> '$DIR/orphan.tmp'
mv '$DIR/orphan.tmp' '$DIR/orphan.out'
SH
  as_first_mate detach "sh -c 'bash \"\$1\" \"\$\$\" &' _ '$DIR/orphan.sh'" >/dev/null
  wait_for_file "$DIR/orphan.out" || fail "the detached child never wrote"
  orphan=$(cat "$DIR/orphan.out")
  assert_contains "$orphan" "only the first mate and the processes it starts may write task records" "a detached child of the first mate must be refused"
  assert_equals "window=w" "$(cat "$STATE/pv-b.meta")" "every refused write must leave the record as the first mate published it"
  assert_equals "4" "$(jq -r 'select(.verdict == "refused" and .id == "pv-b") | .op' "$EGRESS/records.log" | wc -l | tr -d ' ')" \
    "the writer must log each refusal"
  assert_equals "publish remove append publish" "$(jq -r '.op' "$EGRESS/records.log" | tr '\n' ' ' | sed 's/ $//')" \
    "the log must name each refused request in order"
  pass "the writer refuses and logs the first mate's parent, a sibling, and a child the first mate detached"
}

test_without_the_first_mate_everything_is_refused() {
  local out
  make_case ended
  start_first_mate
  start_writer "$MATE_PID"
  as_first_mate seed "printf 'window=w\n' | $(client publish pv-c)" >/dev/null
  kill "$MATE_PID"
  wait "$MATE_PID" 2>/dev/null
  out=$(request remove pv-c)
  expect_code 1 "$?" "a request after the first mate ended must be refused: $out"
  assert_contains "$out" "the first mate's process has ended" "the refusal must say the first mate is gone"
  [ -e "$STATE/pv-c.meta" ] || fail "a refused removal must leave the record"
  make_case reused
  start_first_mate
  out=$(python3 -I "$WRITER" serve "$SOCK" "$STATE" "$EGRESS" "$MATE_PID" "Thu Jan  1 00:00:00 1970" 2>&1)
  expect_code 1 "$?" "a writer whose first mate does not run with the recorded start time must not start: $out"
  assert_contains "$out" "is not running with start time" "the writer must say why it did not start"
  [ ! -e "$EGRESS/records.ready" ] && [ ! -e "$SOCK" ] || fail "a writer that did not start must leave no socket or ready file"
  pass "once the first mate's process ends every write is refused, and a reused process id never starts a writer"
}

test_the_anchor_start_time_is_read_in_one_locale_whatever_lc_time_says() {
  local out
  make_case locale
  start_first_mate
  (
    export LC_TIME=nl_NL.UTF-8
    start_writer "$MATE_PID"
    out=$(as_first_mate ping "$(client ping)")
    assert_equals "rc=0" "$out" "a writer started under another LC_TIME must still accept the first mate"
    kill "$WRITER_PID"
    wait "$WRITER_PID" 2>/dev/null
  ) || exit 1
  pass "the writer reads the first mate's start time under LC_ALL=C, as the launcher does, whatever LC_TIME the captain sets"
}

test_a_publish_takes_a_mode_no_wider_than_the_default() {
  local out old_umask
  make_case mode
  start_first_mate
  old_umask=$(umask)
  umask 022
  start_writer "$MATE_PID"
  umask "$old_umask"
  out=$(as_first_mate private "printf 'window=w
' | $(client publish pv-m 0600)")
  assert_equals "rc=0" "$out" "the first mate must publish a record with mode 0600"
  assert_equals "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$STATE/pv-m.meta")" \
    "a publish asking for 0600 must land as 0600"
  out=$(as_first_mate keep "printf 'pr=x
' | $(client append pv-m)")
  assert_equals "rc=0" "$out" "the first mate must append to its private record"
  assert_equals "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$STATE/pv-m.meta")" \
    "an append must keep the record's mode"
  out=$(as_first_mate narrow "printf 'window=w
' | $(client publish pv-n 0640)")
  assert_equals "rc=0" "$out" "a mode no wider than the default must be accepted"
  assert_equals "640" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$STATE/pv-n.meta")" \
    "a publish asking for 0640 must land as 0640"
  out=$(as_first_mate wide "printf 'window=forged
' | $(client publish pv-m 0666)")
  assert_contains "$out" "mode 666 is wider than the writer's default 644" "a mode wider than the default must be refused"
  assert_contains "$out" "rc=1" "a mode wider than the default must be refused with status 1"
  out=$(as_first_mate append-mode "printf 'x=1
' | python3 -I '$WRITER' request '$SOCK' append pv-m 0600")
  assert_contains "$out" "rc=2" "only a publish takes a mode"
  assert_equals $'window=w
pr=x' "$(cat "$STATE/pv-m.meta")" "a refused publish must leave the record"
  assert_equals "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$STATE/pv-m.meta")" \
    "a refused publish must leave the record's mode"
  pass "a publish may ask for 0600 or a mode no wider than the default, an append keeps the mode, and a wider mode is refused"
}

test_requests_are_validated() {
  local out id n=0
  make_case validate
  start_first_mate
  start_writer "$MATE_PID"
  for id in ../pv-d sub/pv-d 'pv d' ''; do
    n=$((n + 1))
    out=$(as_first_mate "bad-$n" "printf 'window=w\n' | $(client publish "'$id'")")
    assert_contains "$out" "is not a task id" "the id '$id' must be refused"
    assert_contains "$out" "rc=1" "the id '$id' must be refused with status 1"
  done
  [ -z "$(ls -A "$STATE")" ] || fail "a refused id must write nothing: $(ls -A "$STATE")"
  [ ! -e "$DIR/pv-d.meta" ] || fail "a refused id must write nothing outside the state directory"
  out=$(as_first_mate big "head -c 65537 /dev/zero | tr '\\0' x | $(client publish pv-d)")
  assert_contains "$out" "the content is larger than 65536 bytes" "oversized content must be refused"
  out=$(as_first_mate missing "printf 'x=1\n' | $(client append pv-d)")
  assert_contains "$out" "there is no task record pv-d to append to" "an append to a missing record must be refused"
  [ ! -e "$STATE/pv-d.meta" ] || fail "no refused request may create the record"
  pass "the writer refuses ids that name nothing in the state directory, oversized content, and an append to a missing record"
}

test_a_publish_is_whole_and_staged_nowhere_in_state() {
  local out a b reader bystander bad
  make_case whole
  start_first_mate
  start_writer "$MATE_PID"
  a=$(head -c 40000 /dev/zero | tr '\0' a)
  b=$(head -c 40000 /dev/zero | tr '\0' b)
  printf '%s\n' "$a" > "$DIR/a"
  printf '%s\n' "$b" > "$DIR/b"
  : > "$STATE/pv-e.status"
  : > "$STATE/.pv-e.meta.spawn.1"
  # A reader that records every read that is neither whole record.
  bash -c 'while [ ! -e "$1/stop" ]; do
      c=$(cat "$2" 2>/dev/null) || continue
      [ "$c" = "$3" ] || [ "$c" = "$4" ] || echo bad >> "$1/bad"
    done' _ "$DIR" "$STATE/pv-e.meta" "$a" "$b" &
  reader=$!
  STARTED+=("$reader")
  # A bystander that rewrites every other file in state/ as fast as it can.
  bash -c 'while [ ! -e "$1/stop" ]; do
      for f in "$2"/* "$2"/.*; do
        [ -f "$f" ] && [ "$f" != "$2/pv-e.meta" ] && printf forged > "$f"
      done
    done' _ "$DIR" "$STATE" &
  bystander=$!
  STARTED+=("$bystander")
  out=$(as_first_mate flip "for i in 1 2 3 4 5 6 7 8 9 10; do
      $(client publish pv-e) < '$DIR/a' || exit 1
      $(client publish pv-e) < '$DIR/b' || exit 1
    done")
  : > "$DIR/stop"
  wait "$reader" "$bystander" 2>/dev/null
  assert_equals "rc=0" "$out" "every publish must be accepted"
  bad=0
  [ ! -e "$DIR/bad" ] || bad=$(wc -l < "$DIR/bad" | tr -d ' ')
  assert_equals "0" "$bad" "a reader must never see a half-written record"
  assert_equals "$b" "$(cat "$STATE/pv-e.meta")" "the last publish must be the record, whatever a bystander wrote in state/"
  assert_equals ".pv-e.meta.spawn.1
pv-e.meta
pv-e.status" "$(cd "$STATE" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort)" "the writer must stage nothing in state/"
  pass "a publish replaces the record whole, and nothing a bystander writes in state/ reaches it"
}

test_the_first_mate_publishes_appends_and_removes
test_a_process_outside_the_first_mates_lineage_is_refused
test_without_the_first_mate_everything_is_refused
test_the_anchor_start_time_is_read_in_one_locale_whatever_lc_time_says
test_a_publish_takes_a_mode_no_wider_than_the_default
test_requests_are_validated
test_a_publish_is_whole_and_staged_nowhere_in_state

echo "# all fm-privateer-records tests passed"
