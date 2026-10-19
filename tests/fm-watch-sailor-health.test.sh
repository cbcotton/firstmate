#!/usr/bin/env bash
# tests/fm-watch-sailor-health.test.sh - bin/fm-watch.sh's named-sailor health
# watch: a live sailor whose stub server flips up, down, and up again wakes
# firstmate exactly twice (check: sailor <name> down, then up), stays silent
# while it stays down, and writes one sailor.state fleet-ledger event per
# change. The sailor's endpoint belongs to a stub mlx-serve registry entry, so
# the watch reads the server's healthPath, and a login sailor on a fake codex
# is read by its local sign-in check alone, bounded by the probe timeout.
# bin/fm-sailor.sh owns the probe and docs/configuration.md ("Named sailors")
# the contract.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-sailor-health)

# --- the stub sailor server ---------------------------------------------------
# A python3 server answers GET /health with the status code in STUB_DIR/health.code
# (default 200) and GET /v1/models with a one-model list, logging one line per
# request to STUB_DIR/requests.log.

STUB_DIR="$TMP_ROOT/stub"
STUB_PID=
STUB=

stop_stub() {
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; }
  STUB_PID=
}
trap 'stop_stub; fm_test_cleanup' EXIT

start_stub() {
  [ -z "$STUB_PID" ] || return 0
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the sailor stub"
  mkdir -p "$STUB_DIR"
  rm -f "$STUB_DIR/port"
  cat > "$STUB_DIR/stub.py" <<'PY'
import http.server, os, sys, threading

root = sys.argv[1]
stop = threading.Timer(float(os.environ.get("FM_TEST_STUB_MAX_BLOCK_SECONDS", "300")), lambda: os._exit(0))
stop.daemon = True
stop.start()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(os.path.join(root, "requests.log"), "a") as f:
            f.write("GET " + self.path + "\n")
        if self.path == "/health":
            try:
                with open(os.path.join(root, "health.code")) as f:
                    code = int(f.read().strip())
            except (OSError, ValueError):
                code = 200
            body = b'{"status":"ok"}' if code == 200 else b'{"status":"loading"}'
        elif self.path == "/v1/models":
            code, body = 200, b'{"data":[{"id":"qwen-coder"}]}'
        else:
            code, body = 404, b'{"error":"not found"}'
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(root, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(root, "port.tmp"), os.path.join(root, "port"))
server.serve_forever()
PY
  python3 "$STUB_DIR/stub.py" "$STUB_DIR" > "$STUB_DIR/stub.err" 2>&1 &
  STUB_PID=$!
  for _ in $(seq 100); do
    [ -s "$STUB_DIR/port" ] && break
    sleep 0.1
  done
  [ -s "$STUB_DIR/port" ] || fail "the sailor stub did not start: $(cat "$STUB_DIR/stub.err" 2>/dev/null)"
  STUB="http://127.0.0.1:$(cat "$STUB_DIR/port")"
}

set_health() {  # <http-code>
  printf '%s\n' "$1" > "$STUB_DIR/health.code"
}

# make_sailor_case <name>: a throwaway home with the fleet ledger on, one live
# sailor served by the stub (registered in a stub mlx-serve registry with a
# healthPath), and one placeholder that must never be probed.
make_sailor_case() {
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/config"
  : > "$dir/config/fleet-ledger"
  jq -n --arg e "$STUB/v1" '{sailors: {
      tiller: {endpoint: $e, status: "live", models: ["qwen-coder"]},
      flint: {endpoint: "http://127.0.0.1:1/v1", status: "placeholder", models: ["qwen-coder"]}}}' \
    > "$dir/config/crew-dispatch.json"
  jq -n --arg b "$STUB" '{servers: [{id: "mlx-serve", kind: "mlx-serve", baseURL: $b, modelsPath: "/v1/models", healthPath: "/health", enabled: true}]}' \
    > "$dir/servers.json"
  printf '%s\n' "$dir"
}

# run_leg <dir> <tag>: one watcher run with the sailor watch on every poll and
# every other cadence held off; the pid lands in LEG_PID.
run_leg() {
  local dir=$1 tag=$2
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_MLX_SERVE_SERVERS="$dir/servers.json" \
    TMUX='' FM_BACKEND=tmux FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_SAILOR_HEALTH_SECS=1 \
    "$WATCH" > "$dir/watch-$tag.out" 2> "$dir/watch-$tag.err" &
  LEG_PID=$!
}

probe_count() {  # GET /health requests the stub has answered so far
  local n
  n=$(grep -c 'GET /health' "$STUB_DIR/requests.log" 2>/dev/null) || true
  printf '%s\n' "${n:-0}"
}

# quiet_leg <dir> <tag>: a run that must not wake. It waits for two fresh
# probes, so at least one full sweep after the first has been compared, then
# stops the watcher.
quiet_leg() {
  local dir=$1 tag=$2 before
  before=$(probe_count)
  run_leg "$dir" "$tag"
  for _ in $(seq 150); do
    [ "$(probe_count)" -ge $((before + 2)) ] && break
    sleep 0.1
  done
  is_live_non_zombie "$LEG_PID" \
    || fail "the $tag watcher woke when nothing changed: $(cat "$dir/watch-$tag.out" "$dir/watch-$tag.err")"
  [ "$(probe_count)" -ge $((before + 2)) ] \
    || fail "the $tag watcher never probed the sailor twice: $(cat "$dir/watch-$tag.err")"
  kill -TERM "$LEG_PID" 2>/dev/null || true
  wait_for_exit "$LEG_PID" 50 >/dev/null || true
}

# waking_leg <dir> <tag>: a run that must wake; it ends on its own.
waking_leg() {
  run_leg "$1" "$2"
  wait_for_exit "$LEG_PID" 150 || fail "the $2 watcher did not wake: $(cat "$1/watch-$2.out" "$1/watch-$2.err")"
}

# drain_leg <dir> <tag>: present the durable queue through the real drain into
# drain-<tag>.out and post the acknowledgement it names, as firstmate would, so
# the next leg starts clean.
drain_leg() {
  local dir=$1 tag=$2
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$dir/drain-$tag.out" 2> "$dir/drain-$tag.err" || true
  ack_drain_err "$dir/state" "$dir/drain-$tag.err" > /dev/null 2>&1 || true
}

ledger_states() {  # <dir>: the sailor.state events, one compact object per line
  jq -c 'select(.event == "sailor.state") | {task, name, state}' "$1/state/fleet-ledger.jsonl" 2>/dev/null
}

test_sailor_flipping_up_down_up_wakes_exactly_twice() {
  local dir state
  start_stub
  set_health 200
  dir=$(make_sailor_case flip)
  state="$dir/state"

  # First sight of an answering sailor is recorded without a wake.
  quiet_leg "$dir" up
  assert_equals "tiller up" "$(cat "$state/.sailor-health" 2>/dev/null)" "the watch must record the live sailor's state, and only the live sailor's"
  drain_leg "$dir" up
  assert_no_grep "sailor" "$dir/drain-up.out" "an answering sailor must queue nothing"

  set_health 503
  waking_leg "$dir" down
  assert_equals "check: sailor tiller down" "$(cat "$dir/watch-down.out")" "a sailor that stops answering must wake once with its name and state"
  drain_leg "$dir" down
  assert_equals 1 "$(grep -c 'check: sailor tiller down' "$dir/drain-down.out")" "the down wake must be queued exactly once"

  # A sailor that stays down wakes nothing more.
  quiet_leg "$dir" still-down
  drain_leg "$dir" still-down
  assert_no_grep "sailor" "$dir/drain-still-down.out" "a sailor that stays down must not wake again"

  set_health 200
  waking_leg "$dir" back
  assert_equals "check: sailor tiller up" "$(cat "$dir/watch-back.out")" "a sailor that answers again must wake once"
  drain_leg "$dir" back
  assert_equals 1 "$(grep -c 'check: sailor tiller up' "$dir/drain-back.out")" "the up wake must be queued exactly once"

  assert_equals 2 "$(cat "$dir"/watch-*.out | grep -c '^check: sailor ')" "the up-down-up flip must wake exactly twice"
  assert_equals '{"task":null,"name":"tiller","state":"down"}
{"task":null,"name":"tiller","state":"up"}' "$(ledger_states "$dir")" "each change must write exactly one sailor.state ledger event"
  assert_no_grep "GET /v1/models" "$STUB_DIR/requests.log" "an mlx-serve sailor's health must be read at its server's healthPath"
  pass "watch: a sailor flipping up, down, and up wakes exactly twice and ledgers each change"
}

test_sailor_first_seen_down_wakes_once() {
  local dir
  start_stub
  set_health 503
  dir=$(make_sailor_case first-down)
  waking_leg "$dir" first
  assert_equals "check: sailor tiller down" "$(cat "$dir/watch-first.out")" "a live sailor first seen down must wake once"
  drain_leg "$dir" first
  quiet_leg "$dir" again
  drain_leg "$dir" again
  assert_no_grep "sailor" "$dir/drain-again.out" "a sailor first seen down must not wake again while it stays down"
  pass "watch: a live sailor first seen down wakes once"
}

test_home_without_sailors_stays_silent() {
  local dir
  start_stub
  dir=$(make_case no-sailors)
  mkdir -p "$dir/config"
  printf '%s\n' '{"default": {"harness": "claude"}}' > "$dir/config/crew-dispatch.json"
  : > "$STUB_DIR/requests.log"
  run_leg "$dir" none
  sleep 3
  is_live_non_zombie "$LEG_PID" || fail "a home with no sailors woke: $(cat "$dir/watch-none.out" "$dir/watch-none.err")"
  kill -TERM "$LEG_PID" 2>/dev/null || true
  wait_for_exit "$LEG_PID" 50 >/dev/null || true
  [ ! -e "$dir/state/.sailor-health" ] || fail "a home with no sailors kept a sailor health record"
  pass "watch: a home that declares no sailors stays silent"
}

# make_login_case <name>: make_sailor_case plus a live login sailor on codex,
# whose sign-in check runs a fake codex from the case's fakebin. The check
# runs under env -i, so the fake reads its signed-out toggle from a file under
# the case's own HOME, which each leg exports.
make_login_case() {
  local dir
  dir=$(make_sailor_case "$1")
  jq '.sailors.teach = {harness: "codex", login: "chatgpt", status: "live", models: ["gpt-6-sol"], grade: "specialist"}' \
    "$dir/config/crew-dispatch.json" > "$dir/config/crew-dispatch.json.new" && mv "$dir/config/crew-dispatch.json.new" "$dir/config/crew-dispatch.json"
  mkdir -p "$dir/home"
  cat > "$dir/fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "$HOME/codex.log"
[ ! -e "$HOME/codex.sleep" ] || sleep 20
[ ! -e "$HOME/codex.down" ] || exit 1
exit 0
SH
  chmod +x "$dir/fakebin/codex"
  printf '%s\n' "$dir"
}

test_login_sailor_signing_out_wakes_once_without_a_prompt() {
  local dir state
  start_stub
  set_health 200
  dir=$(make_login_case login)
  state="$dir/state"

  HOME="$dir/home" quiet_leg "$dir" signed-in
  assert_equals "teach up
tiller up" "$(sort "$state/.sailor-health" 2>/dev/null)" "the watch must record the login sailor beside the endpoint sailor"
  drain_leg "$dir" signed-in
  assert_no_grep "sailor" "$dir/drain-signed-in.out" "a signed-in login sailor must queue nothing"

  : > "$dir/home/codex.down"
  HOME="$dir/home" waking_leg "$dir" signed-out
  assert_equals "check: sailor teach down" "$(cat "$dir/watch-signed-out.out")" "a login sailor that signs out must wake once with its name"
  drain_leg "$dir" signed-out
  assert_equals 1 "$(grep -c 'check: sailor teach down' "$dir/drain-signed-out.out")" "the down wake must be queued exactly once"

  rm "$dir/home/codex.down"
  HOME="$dir/home" waking_leg "$dir" signed-back
  assert_equals "check: sailor teach up" "$(cat "$dir/watch-signed-back.out")" "a login sailor that signs in again must wake once"
  assert_equals '{"task":null,"name":"teach","state":"down"}
{"task":null,"name":"teach","state":"up"}' "$(ledger_states "$dir")" "each change of the login sailor must write exactly one sailor.state ledger event"
  assert_no_grep "-p" "$dir/home/codex.log" "the watch must never send the login sailor a prompt"
  assert_equals 0 "$(grep -vc '^codex login status$' "$dir/home/codex.log")" "the watch must ask codex only for its login status"
  pass "watch: a login sailor signing out and back in wakes exactly twice, by its sign-in check alone"
}

test_login_sailor_check_is_bounded_by_the_probe_timeout() {
  local dir
  start_stub
  set_health 200
  dir=$(make_login_case login-slow)

  HOME="$dir/home" quiet_leg "$dir" signed-in
  drain_leg "$dir" signed-in
  : > "$dir/home/codex.sleep"
  HOME="$dir/home" FM_SAILOR_PROBE_TIMEOUT=1 FM_SAILOR_LOGIN_TIMEOUT=60 waking_leg "$dir" stalled
  assert_equals "check: sailor teach down" "$(cat "$dir/watch-stalled.out")" "a codex that stalls past the probe timeout must read as down on the next tick, not after the login timeout"
  pass "watch: a stalled login sailor's sign-in check is bounded by the probe timeout, not the login timeout"
}

test_sailor_flipping_up_down_up_wakes_exactly_twice
test_sailor_first_seen_down_wakes_once
test_home_without_sailors_stays_silent
test_login_sailor_signing_out_wakes_once_without_a_prompt
test_login_sailor_check_is_bounded_by_the_probe_timeout

echo "# all fm-watch-sailor-health tests passed"
