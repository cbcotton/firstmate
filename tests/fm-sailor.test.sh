#!/usr/bin/env bash
# tests/fm-sailor.test.sh - named local sailors through bin/fm-sailor.sh:
# map validation, the placeholder lock, the capacity count, the endpoint probe,
# and the OpenCode provider fragment, then the warm-up, the status view, and
# the registry commands. The first cases use a fake curl that logs every URL it
# is asked for, so a test can prove a probe did or did not happen; the later
# cases run the real curl against a local HTTP stub standing in for the
# sailor's model server. docs/configuration.md ("Named sailors") owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sailor)
SAILOR="$ROOT/bin/fm-sailor.sh"

MAP='{"sailors":{
  "tiller":{"title":"Tiller","endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["qwen-coder"],"max_concurrent":1},
  "flint":{"endpoint":"http://flint.local:8000/v1/","status":"live","models":["qwen-coder-large"],"max_concurrent":2},
  "stoker":{"endpoint":"http://stoker.invalid:8000/v1","status":"placeholder","models":["qwen-coder"]}},
 "rules":[{"when":"clear-path code","use":[{"harness":"opencode","sailor":"stoker","model":"qwen-coder"},{"harness":"opencode","sailor":"tiller","model":"qwen-coder"}]}],
 "sailor_fallback":{"harness":"claude","model":"claude-opus-5-5"}}'

# Sets CASE_DIR, FAKEBIN and CURL_LOG for one isolated home holding <map>.
make_case() {  # <name> <map-json>
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/config" "$CASE_DIR/state"
  [ -z "$2" ] || printf '%s\n' "$2" > "$CASE_DIR/config/crew-dispatch.json"
  FAKEBIN=$(fm_fakebin "$CASE_DIR")
  CURL_LOG="$CASE_DIR/curl.log"
  : > "$CURL_LOG"
  cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
url=${!#}
printf '%s\n' "$url" >> "$FM_FAKE_CURL_LOG"
[ "${FM_FAKE_CURL_DOWN:-0}" = 1 ] && exit 7
body=${FM_FAKE_MODELS_BODY:-}
[ -n "$body" ] || body='{"object":"list","data":[{"id":"qwen-coder"},{"id":"qwen-coder-large"}]}'
printf '%s' "$body"
SH
  chmod +x "$FAKEBIN/curl"
}

run_sailor() {
  PATH="$FAKEBIN:$PATH" FM_FAKE_CURL_LOG="$CURL_LOG" \
    FM_CONFIG_OVERRIDE="$CASE_DIR/config" FM_STATE_OVERRIDE="$CASE_DIR/state" \
    "$SAILOR" "$@" 2>&1
}

test_live_sailor_serving_the_model_passes_check() {
  local out status
  make_case live "$MAP"
  out=$(run_sailor check tiller qwen-coder)
  status=$?
  expect_code 0 "$status" "a live sailor that lists the model must pass"
  assert_contains "$out" "ok: sailor tiller serves qwen-coder at http://127.0.0.1:11234/v1" "check did not report the sailor as ready"
  assert_equals "http://127.0.0.1:11234/v1/models" "$(cat "$CURL_LOG")" "check must probe the endpoint's model list"
  pass "a live sailor serving the model passes check after one probe of <endpoint>/models"
}

test_endpoint_trailing_slash_is_not_doubled() {
  make_case slash "$MAP"
  run_sailor check flint qwen-coder-large >/dev/null
  assert_equals "http://flint.local:8000/v1/models" "$(cat "$CURL_LOG")" "a trailing slash on the endpoint must not double in the probe URL"
  pass "the probe URL joins an endpoint with a trailing slash cleanly"
}

test_placeholder_is_refused_without_a_probe() {
  local out status
  make_case placeholder "$MAP"
  out=$(run_sailor check stoker qwen-coder)
  status=$?
  expect_code 1 "$status" "a placeholder sailor must be refused"
  assert_contains "$out" "refused: sailor stoker is a placeholder" "placeholder refusal missing"
  [ ! -s "$CURL_LOG" ] || fail "a placeholder must be refused before any probe, but curl was called: $(cat "$CURL_LOG")"
  pass "a placeholder sailor is refused before anything is probed, even if its address answers"
}

test_silent_endpoint_is_refused() {
  local out status
  make_case down "$MAP"
  out=$(FM_FAKE_CURL_DOWN=1 run_sailor check tiller qwen-coder)
  status=$?
  expect_code 1 "$status" "an endpoint that does not answer must be refused"
  assert_contains "$out" "refused: sailor tiller is not answering at http://127.0.0.1:11234/v1" "down refusal missing"
  pass "a sailor whose endpoint does not answer is refused"
}

test_endpoint_without_the_model_is_refused() {
  local out status
  make_case unserved "$MAP"
  out=$(FM_FAKE_MODELS_BODY='{"data":[{"id":"something-else"}]}' run_sailor check tiller qwen-coder)
  status=$?
  expect_code 1 "$status" "an endpoint that does not list the model must be refused"
  assert_contains "$out" "refused: sailor tiller at http://127.0.0.1:11234/v1 does not serve qwen-coder" "unserved refusal missing"
  pass "a sailor whose endpoint does not list the model is refused"
}

test_unlisted_model_and_unknown_sailor_are_refused() {
  local out status
  make_case unlisted "$MAP"
  out=$(run_sailor check tiller uncensored-merge)
  status=$?
  expect_code 1 "$status" "a model outside the sailor's list must be refused"
  assert_contains "$out" "refused: model uncensored-merge is not listed for sailor tiller" "unlisted-model refusal missing"
  out=$(run_sailor check nobody qwen-coder)
  status=$?
  expect_code 1 "$status" "an unknown sailor must be refused"
  assert_contains "$out" "refused: unknown sailor nobody" "unknown-sailor refusal missing"
  [ ! -s "$CURL_LOG" ] || fail "neither refusal may probe anything"
  pass "a model outside the sailor's list and an unknown sailor are refused without a probe"
}

test_capacity_counts_live_task_records() {
  local out status
  make_case capacity "$MAP"
  printf 'harness=opencode\nsailor=tiller\n' > "$CASE_DIR/state/busy-a1.meta"
  printf 'harness=claude\nmodel=claude-sonnet-5\n' > "$CASE_DIR/state/other-b1.meta"
  out=$(run_sailor check tiller qwen-coder)
  status=$?
  expect_code 1 "$status" "a sailor at max_concurrent must be refused"
  assert_contains "$out" "refused: sailor tiller is at capacity (1 of 1 tasks)" "capacity refusal missing"
  out=$(run_sailor check tiller qwen-coder --task busy-a1)
  status=$?
  expect_code 0 "$status" "the task being relaunched must not count against its own sailor"
  out=$(run_sailor check flint qwen-coder-large)
  status=$?
  expect_code 0 "$status" "another sailor's capacity is independent"
  pass "capacity counts live task records per sailor and excludes the task being relaunched"
}

test_provider_json_is_the_opencode_provider_entry() {
  local out expect
  make_case provider "$MAP"
  out=$(run_sailor provider-json tiller qwen-coder)
  expect='{"tiller":{"npm":"@ai-sdk/openai-compatible","name":"Tiller","options":{"baseURL":"http://127.0.0.1:11234/v1"},"models":{"qwen-coder":{"name":"qwen-coder"}}}}'
  assert_equals "$expect" "$out" "provider-json must be the OpenCode provider entry keyed by the sailor"
  [ ! -s "$CURL_LOG" ] || fail "provider-json must not probe"
  pass "provider-json prints the OpenCode provider entry for exactly that sailor and model"
}

test_validate_is_silent_without_sailors_and_names_the_first_problem() {
  local out status
  make_case absent ""
  out=$(run_sailor validate)
  status=$?
  expect_code 0 "$status" "an absent dispatch file has nothing to validate"
  assert_equals "" "$out" "validate must be silent when the file is absent"

  make_case no-sailors '{"default":{"harness":"claude"}}'
  out=$(run_sailor validate)
  expect_code 0 "$?" "a dispatch file without sailors is valid"
  assert_equals "" "$out" "validate must be silent without sailors"

  make_case good "$MAP"
  out=$(run_sailor validate)
  expect_code 0 "$?" "the example map must validate"

  make_case bad-capacity '{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:1/v1","status":"live","models":["m"],"max_concurrent":1.5}}}'
  out=$(run_sailor validate)
  status=$?
  expect_code 1 "$status" "a fractional capacity must be invalid"
  assert_equals "sailor tiller max_concurrent must be a positive whole number" "$out" "capacity diagnostic mismatch"

  make_case quoted-model "{\"sailors\":{\"tiller\":{\"endpoint\":\"http://127.0.0.1:1/v1\",\"status\":\"live\",\"models\":[\"it's\"]}}}"
  out=$(run_sailor validate)
  expect_code 1 "$?" "a quoted model id must be invalid"
  assert_equals "sailor tiller models must be non-empty strings without spaces or quotes" "$out" "model diagnostic mismatch"

  make_case check-invalid '{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:1/v1","status":"up","models":["m"]}}}'
  out=$(run_sailor check tiller m)
  status=$?
  expect_code 2 "$status" "check must refuse to run on an invalid map"
  assert_contains "$out" "invalid config/crew-dispatch.json - sailor tiller status must be live or placeholder" "check did not name the configuration error"
  pass "validate is silent without sailors, names the first problem otherwise, and check stops on an invalid map"
}

# --- the local HTTP stub ------------------------------------------------------
#
# A python3 server answers GET /v1/models and /metrics and POST
# /v1/chat/completions from control files in STUB_DIR and logs one line per
# request to STUB_DIR/requests.log, so a case can drive loaded versus listed
# models, a failed warm-up, and the queue gauges, and prove which requests the
# script made.

STUB_DIR="$TMP_ROOT/stub"
STUB_PID=
STUB=
STUB_MODELS='{"object":"list","data":[{"id":"qwen-coder","loaded":true},{"id":"qwen-next","loaded":true},{"id":"qwen-big","loaded":false}]}'

stop_stub() {
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; }
  STUB_PID=
}
trap 'stop_stub; fm_test_cleanup' EXIT

start_stub() {
  [ -z "$STUB_PID" ] || return 0
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the sailor stub"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/stub.py" <<'PY'
import http.server, json, os, sys, threading

root = sys.argv[1]
stop = threading.Timer(float(os.environ.get("FM_TEST_STUB_MAX_BLOCK_SECONDS", "120")), lambda: os._exit(0))
stop.daemon = True
stop.start()


def read(name):
    try:
        with open(os.path.join(root, name)) as f:
            return f.read()
    except OSError:
        return None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def note(self, line):
        with open(os.path.join(root, "requests.log"), "a") as f:
            f.write(line + "\n")

    def reply(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.note("GET " + self.path)
        body = {"/v1/models": read("models.json"), "/metrics": read("metrics.txt")}.get(self.path)
        if body is None:
            self.reply(404, '{"error":"not found"}')
        else:
            self.reply(200, body)

    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(size) or b"{}")
        except ValueError:
            req = {}
        self.note("POST %s model=%s max_tokens=%s" % (self.path, req.get("model"), req.get("max_tokens")))
        if self.path != "/v1/chat/completions":
            self.reply(404, '{"error":"not found"}')
            return
        code = int((read("chat.code") or "200").strip())
        body = read("chat.body") or '{"choices":[{"index":0,"message":{"role":"assistant","content":"OK"}}]}'
        self.reply(code, body)


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

# stub_reset [<models-body>]: serve <models-body> (default STUB_MODELS), no
# metrics, successful completions, and an empty request log.
stub_reset() {
  start_stub
  rm -f "$STUB_DIR/metrics.txt" "$STUB_DIR/chat.code" "$STUB_DIR/chat.body"
  printf '%s' "${1:-$STUB_MODELS}" > "$STUB_DIR/models.json"
  : > "$STUB_DIR/requests.log"
}

# stub_map: tiller is the stub; flint is a placeholder nothing answers for.
stub_map() {
  jq -n --arg e "$STUB/v1" '{
    sailors: {
      tiller: {title: "Tiller", endpoint: $e, status: "live", models: ["qwen-coder", "qwen-big"], max_concurrent: 1},
      flint: {endpoint: "http://127.0.0.1:1/v1", status: "placeholder", models: ["qwen-coder"]}},
    rules: [
      {when: "clear-path code", use: [{harness: "opencode", sailor: "flint", model: "qwen-coder"}, {harness: "opencode", sailor: "tiller", model: "qwen-coder"}]},
      {when: "big refactors", use: {harness: "opencode", sailor: "tiller", model: "qwen-big"}},
      {when: "flint only", use: [{harness: "opencode", sailor: "flint", model: "qwen-coder"}]}],
    default: [{harness: "opencode", sailor: "tiller", model: "qwen-coder"}],
    sailor_fallback: {harness: "claude", model: "claude-opus-5-5"}}'
}

# make_stub_case <name> <map-json>: an isolated home run with the real curl.
make_stub_case() {
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/config" "$CASE_DIR/state"
  printf '%s\n' "$2" > "$CASE_DIR/config/crew-dispatch.json"
  cp "$CASE_DIR/config/crew-dispatch.json" "$CASE_DIR/original.json"
}

run_real() {
  FM_HOME="$CASE_DIR" FM_CONFIG_OVERRIDE="$CASE_DIR/config" FM_STATE_OVERRIDE="$CASE_DIR/state" \
    FM_MLX_SERVE_SERVERS="$CASE_DIR/servers.json" "$SAILOR" "$@" 2>&1
}

dispatch() {  # <jq-filter>: read the case's dispatch file
  jq -c "$1" "$CASE_DIR/config/crew-dispatch.json"
}

backups() {  # the case's dated backups under config/, one per line
  local f
  for f in "$CASE_DIR"/config/*.bak-*; do
    [ -e "$f" ] && printf '%s\n' "$f"
  done
}

assert_unchanged() {  # <msg>
  cmp -s "$CASE_DIR/original.json" "$CASE_DIR/config/crew-dispatch.json" || fail "$1: config/crew-dispatch.json changed"
  [ -z "$(backups)" ] || fail "$1: a backup was written, so something was replaced"
}

test_check_says_loaded_or_listed_and_warms_on_request() {
  local out status
  stub_reset
  make_stub_case warm "$(stub_map)"
  out=$(run_real check tiller qwen-coder)
  status=$?
  expect_code 0 "$status" "a loaded model must pass"
  assert_contains "$out" "(0 of 1 tasks busy; model loaded)" "check must say a loaded model is loaded"
  out=$(run_real check tiller qwen-big)
  status=$?
  expect_code 0 "$status" "a listed but unloaded model still passes, because the server loads it on demand"
  assert_contains "$out" "model listed but not loaded, so the first request loads it" "check must say an unloaded model is only listed"
  assert_no_grep "POST" "$STUB_DIR/requests.log" "check without --warm must never ask the model for a completion"

  out=$(run_real check tiller qwen-big --warm)
  status=$?
  expect_code 0 "$status" "a warm-up the server answers must pass"
  assert_contains "$out" "; model warmed)" "check --warm must say the model was warmed"
  assert_grep "POST /v1/chat/completions model=qwen-big max_tokens=1" "$STUB_DIR/requests.log" "--warm must ask the model for exactly one token"

  printf '507' > "$STUB_DIR/chat.code"
  printf '{"error":{"message":"not enough free memory to load qwen-big"}}' > "$STUB_DIR/chat.body"
  out=$(run_real check tiller qwen-big --warm)
  status=$?
  expect_code 1 "$status" "a failed warm-up must be refused"
  assert_contains "$out" "refused: sailor tiller could not load qwen-big: HTTP 507: not enough free memory to load qwen-big" "the warm-up refusal must carry the server's reason"
  pass "check says whether the model is loaded or only listed, and --warm loads it now or refuses with the server's reason"
}

test_status_shows_answer_tasks_queue_and_models() {
  local out
  stub_reset
  make_stub_case status "$(stub_map | jq '.sailors.tiller.models += ["qwen-gone"]')"
  cat > "$STUB_DIR/metrics.txt" <<'EOF'
# HELP vllm:num_requests_running Number of requests currently being processed
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running{model_name="qwen-coder"} 1.0
vllm:num_requests_running{model_name="qwen-big"} 1.0
# TYPE vllm:num_requests_waiting gauge
vllm:num_requests_waiting 1
EOF
  fm_write_meta "$CASE_DIR/state/busy-a1.meta" harness=opencode sailor=tiller model=qwen-coder
  out=$(run_real status)
  expect_code 0 "$?" "status is a view and exits 0"
  assert_equals "tiller live answering endpoint=$STUB/v1 tasks=1/1 running=2 waiting=1 models=qwen-coder(loaded),qwen-big(unloaded),qwen-gone(missing)" "$out" "status must show one line per live sailor"

  out=$(run_real status --all)
  assert_contains "$out" "flint placeholder not-answering endpoint=http://127.0.0.1:1/v1 tasks=0/1" "status --all must include placeholders"

  stub_reset '{"data":[{"id":"qwen-coder"},{"id":"qwen-big"}]}'
  out=$(run_real status)
  assert_equals "tiller live answering endpoint=$STUB/v1 tasks=1/1 models=qwen-coder(listed),qwen-big(listed),qwen-gone(missing)" "$out" "a server with no loaded flag and no metrics must show listed models and no queue"
  pass "status shows each sailor's answer, tasks, server queue, and every model as loaded, unloaded, listed, or missing"
}

test_set_model_replace_moves_every_profile_of_that_sailor() {
  local out status baks
  stub_reset
  make_stub_case replace "$(stub_map | jq '.rules += [{when: "mixed", use: [{harness: "opencode", sailor: "tiller", model: "qwen-coder"}, {harness: "opencode", sailor: "tiller", model: "qwen-next"}]}] | .sailors.tiller.models += ["qwen-next"]')"
  out=$(run_real set-model tiller qwen-next --replace qwen-coder)
  status=$?
  expect_code 0 "$status" "a replace onto a model the sailor serves must succeed: $out"
  assert_contains "$out" "replaced tiller/qwen-coder with tiller/qwen-next in 3 profile(s)" "set-model must count the profiles it moved"
  assert_contains "$out" "workers: the change applies from each worker's next spawn" "set-model must say when the change applies"
  assert_equals '["qwen-next","qwen-big"]' "$(dispatch '.sailors.tiller.models')" "the old model must leave the list, the new one taking its place"
  assert_equals '["qwen-next","qwen-big","qwen-next"]' "$(dispatch '[.rules[].use | if type == "array" then .[] else . end | select(.sailor == "tiller") | .model]')" "every rule profile on tiller must name the new model, and a repeat in one list must go"
  assert_equals '["qwen-coder"]' "$(dispatch '[.rules[].use | if type == "array" then .[] else . end | select(.sailor == "flint") | .model] | unique')" "another sailor's profiles must keep their model"
  assert_equals '[{"harness":"opencode","sailor":"tiller","model":"qwen-next"}]' "$(dispatch '.default')" "the default profile must move too"
  run_real validate >/dev/null || fail "the rewritten map must validate"
  baks=$(backups)
  assert_equals 1 "$(printf '%s\n' "$baks" | awk 'END { print NR }')" "exactly one backup must be kept"
  case "$baks" in
    "$CASE_DIR/config/crew-dispatch.json.bak-"[0-9]*) ;;
    *) fail "the backup must be a dated copy beside the file (got '$baks')" ;;
  esac
  cmp -s "$CASE_DIR/original.json" "$baks" || fail "the backup must hold the file as it was"
  pass "set-model --replace moves every rule and default profile of that sailor, leaves other sailors alone, and keeps a dated backup"
}

test_set_model_refusals_write_nothing() {
  local out status
  stub_reset
  make_stub_case refusals "$(stub_map)"
  out=$(run_real set-model tiller qwen-absent)
  status=$?
  expect_code 1 "$status" "a model the live sailor does not serve must be refused"
  assert_contains "$out" "refused: sailor tiller at $STUB/v1 does not serve qwen-absent" "unserved-model refusal missing"

  printf '507' > "$STUB_DIR/chat.code"
  printf '{"error":{"message":"not enough free memory"}}' > "$STUB_DIR/chat.body"
  out=$(run_real set-model tiller qwen-next --warm)
  status=$?
  expect_code 1 "$status" "a failed warm-up must refuse the swap"
  assert_contains "$out" "refused: sailor tiller could not load qwen-next: HTTP 507: not enough free memory" "warm-up refusal missing"

  fm_write_meta "$CASE_DIR/state/busy-a1.meta" harness=opencode sailor=tiller model=qwen-coder
  out=$(run_real set-model tiller qwen-next --replace qwen-coder)
  status=$?
  expect_code 1 "$status" "a replace while a task runs the old model must be refused"
  assert_contains "$out" "refused: task(s) busy-a1 run tiller/qwen-coder" "in-flight refusal missing"
  rm -f "$CASE_DIR/state/busy-a1.meta"

  out=$(run_real set-model tiller qwen-next --replace qwen-unlisted)
  expect_code 1 "$?" "a replace naming an unlisted model must be refused"
  assert_contains "$out" "refused: model qwen-unlisted is not listed for sailor tiller" "unlisted-old refusal missing"
  out=$(run_real set-model tiller qwen-next --first-mate)
  expect_code 1 "$?" "--first-mate outside a Privateer home must be refused"
  assert_contains "$out" "refused: --first-mate needs a Privateer home" "non-Privateer refusal missing"
  out=$(run_real set-model flint qwen-next --warm)
  expect_code 1 "$?" "--warm on a placeholder must be refused"
  assert_contains "$out" "refused: sailor flint is a placeholder" "placeholder warm refusal missing"
  out=$(run_real set-model nobody qwen-next)
  expect_code 1 "$?" "an unknown sailor must be refused"
  assert_unchanged "every refusal"

  rm -f "$STUB_DIR/chat.code" "$STUB_DIR/chat.body"
  out=$(run_real set-model tiller qwen-next --dry-run)
  expect_code 0 "$?" "a dry run of a valid swap succeeds"
  assert_contains "$out" '+        "qwen-next"' "a dry run must print the change"
  assert_contains "$out" "dry run: nothing written" "a dry run must say it wrote nothing"
  assert_unchanged "a dry run"
  pass "set-model refuses an unserved model, a failed warm-up, a replace under a running task, and misplaced flags, writing nothing, and --dry-run only prints"
}

test_set_model_says_when_the_model_is_only_listed() {
  local out status
  stub_reset
  make_stub_case cold "$(stub_map | jq '.sailors.tiller.models = ["qwen-coder"] | .rules |= map(select(.when != "big refactors"))')"
  out=$(run_real set-model tiller qwen-big)
  status=$?
  expect_code 0 "$status" "a listed but unloaded model may be added: $out"
  assert_contains "$out" "note: tiller lists qwen-big but has not loaded it, so the first request loads it; rerun with --warm to load it now" "set-model must say the model is only listed"
  assert_no_grep "POST" "$STUB_DIR/requests.log" "set-model without --warm must not load anything"
  out=$(run_real set-model tiller qwen-big --warm)
  expect_code 0 "$?" "warming a model already listed succeeds"
  assert_contains "$out" "sailor tiller already lists qwen-big; nothing written" "a second set-model must not rewrite the file"
  assert_contains "$out" "tiller has loaded qwen-big" "set-model --warm must say the model is loaded"
  assert_grep "POST /v1/chat/completions model=qwen-big max_tokens=1" "$STUB_DIR/requests.log" "set-model --warm must ask for one token"
  pass "set-model tells a loaded model from one the server only lists, and --warm loads it"
}

# make_privateer_case <name>: a Privateer home whose first mate runs on tiller.
make_privateer_case() {
  make_stub_case "$1" "$(stub_map | jq 'del(.sailor_fallback)')"
  printf '# first mate\ntiller/qwen-coder\n' > "$CASE_DIR/config/privateer"
  printf 'opencode\n' > "$CASE_DIR/config/crew-harness"
  : > "$CASE_DIR/config/sailor-sandbox"
  FM_HOME="$CASE_DIR" "$ROOT/bin/fm-privateer.sh" check >/dev/null 2>&1 ||
    fail "the Privateer fixture must pass the quarantine: $(FM_HOME="$CASE_DIR" "$ROOT/bin/fm-privateer.sh" check 2>&1)"
}

test_privateer_home_moves_the_first_mate_and_guards_the_quarantine() {
  local out status
  stub_reset
  make_privateer_case privateer
  out=$(run_real set-model tiller qwen-next --replace qwen-coder)
  status=$?
  expect_code 1 "$status" "replacing the first mate's own model without --first-mate must be refused"
  assert_contains "$out" "refused: the first mate runs on tiller/qwen-coder; add --first-mate to move it too" "first-mate refusal missing"
  assert_unchanged "the first-mate refusal"

  out=$(run_real set-model tiller qwen-next --replace qwen-coder --first-mate)
  status=$?
  expect_code 0 "$status" "a first-mate swap in a Privateer home must succeed: $out"
  assert_equals "# first mate
tiller/qwen-next" "$(cat "$CASE_DIR/config/privateer")" "the first mate line must change in place, keeping the comment"
  assert_contains "$out" "first mate: restart the Privateer session to switch" "set-model --first-mate must say the first mate switches at restart"
  FM_HOME="$CASE_DIR" "$ROOT/bin/fm-privateer.sh" check >/dev/null 2>&1 || fail "the home must still pass the quarantine after the swap"

  cp "$CASE_DIR/config/crew-dispatch.json" "$CASE_DIR/original.json"
  rm -f "$CASE_DIR/config/"*.bak-*
  out=$(run_real add hosted --endpoint https://api.example.com/v1 --models coder)
  status=$?
  expect_code 1 "$status" "a public endpoint must be refused in a Privateer home"
  assert_contains "$out" "refused: the change would break this home's Privateer quarantine:" "quarantine refusal missing"
  assert_contains "$out" "sailor hosted has endpoint 'https://api.example.com/v1', which is not on this machine or the local network" "the refusal must carry the quarantine's own reason"
  out=$(run_real retire tiller)
  expect_code 1 "$?" "retiring the first mate's sailor must be refused"
  assert_contains "$out" "config/privateer names tiller/qwen-next, but config/crew-dispatch.json lists no such sailor and model" "retire refusal must carry the quarantine's reason"
  assert_unchanged "the quarantine refusals"
  pass "in a Privateer home set-model --first-mate moves the first mate's line, and any change the quarantine would report is refused"
}

test_retire_refuses_busy_sailors_and_removes_emptied_rules() {
  local out status
  make_stub_case retire "$(stub_map | jq '.sailors.tiller.endpoint = "http://127.0.0.1:1/v1"')"
  fm_write_meta "$CASE_DIR/state/busy-f1.meta" harness=opencode sailor=flint model=qwen-coder
  out=$(run_real retire flint)
  status=$?
  expect_code 1 "$status" "retiring a sailor a task runs on must be refused"
  assert_contains "$out" "refused: task(s) busy-f1 run on flint" "busy retire refusal missing"
  assert_unchanged "the busy refusal"
  rm -f "$CASE_DIR/state/busy-f1.meta"

  out=$(run_real retire flint)
  status=$?
  expect_code 0 "$status" "retiring an idle sailor must succeed: $out"
  assert_contains "$out" "retired sailor flint and the 2 profile(s) naming it" "retire must count the profiles it removed"
  assert_contains "$out" 'removed rule "flint only", which offered only flint' "retire must report a rule it emptied"
  assert_equals '["tiller"]' "$(dispatch '.sailors | keys')" "the sailor must leave the map"
  assert_equals '["clear-path code","big refactors"]' "$(dispatch '[.rules[].when]')" "only the emptied rule may go"
  assert_equals '[{"harness":"opencode","sailor":"tiller","model":"qwen-coder"}]' "$(dispatch '.rules[0].use')" "a shared rule must keep its other profiles"
  run_real validate >/dev/null || fail "the map must validate after retire"

  out=$(run_real retire tiller)
  expect_code 0 "$?" "retiring the last sailor of an ordinary home succeeds: $out"
  assert_contains "$out" "removed the default, which offered only tiller" "retire must report an emptied default"
  assert_equals 'false' "$(dispatch 'has("default")')" "an emptied default must be removed, not left empty"
  assert_equals '[]' "$(dispatch '.rules')" "every rule offering only tiller must go"
  run_real validate >/dev/null || fail "the map must validate after the last retire"
  pass "retire refuses a sailor with a task on it, and otherwise removes it, its profiles, and every rule or default left empty"
}

test_add_and_set_edit_one_sailor() {
  local out status
  make_stub_case add "$(stub_map)"
  out=$(run_real add stoker --endpoint http://stoker.local:8000/v1 --models a,b,a --title Stoker --host "RTX box" --max-concurrent 2)
  status=$?
  expect_code 0 "$status" "adding a well-formed sailor must succeed: $out"
  assert_equals '{"title":"Stoker","host":"RTX box","endpoint":"http://stoker.local:8000/v1","status":"placeholder","models":["a","b"],"max_concurrent":2}' "$(dispatch '.sailors.stoker')" "add must register a placeholder with exactly the given fields"
  cp "$CASE_DIR/config/crew-dispatch.json" "$CASE_DIR/original.json"
  rm -f "$CASE_DIR/config/"*.bak-*
  out=$(run_real add stoker --endpoint http://stoker.local:8000/v1 --models a)
  expect_code 1 "$?" "a name already in the map must be refused"
  assert_contains "$out" "refused: sailor stoker already exists" "duplicate refusal missing"
  out=$(run_real add Bad --endpoint http://bad.local/v1 --models a)
  expect_code 1 "$?" "a malformed name must be refused"
  assert_contains "$out" "refused: sailor name Bad must be lowercase letters, digits and single dashes" "name refusal must carry validate's reason"
  out=$(run_real add remote --endpoint ftp://remote.local/v1 --models a)
  expect_code 1 "$?" "a non-http endpoint must be refused"
  assert_contains "$out" "refused: sailor remote needs an http(s) endpoint" "endpoint refusal must carry validate's reason"
  out=$(run_real set nobody --live)
  expect_code 1 "$?" "set on an unknown sailor must be refused"
  assert_contains "$out" "refused: unknown sailor nobody" "unknown-sailor refusal missing"
  assert_unchanged "the add and set refusals"

  out=$(run_real set stoker --live --max-concurrent 3 --endpoint http://stoker.local:9000/v1)
  expect_code 0 "$?" "set on an existing sailor must succeed: $out"
  assert_equals '{"title":"Stoker","host":"RTX box","endpoint":"http://stoker.local:9000/v1","status":"live","models":["a","b"],"max_concurrent":3}' "$(dispatch '.sailors.stoker')" "set must change exactly the given fields"
  out=$(run_real set stoker --live)
  assert_contains "$out" "sailor stoker already reads that way; nothing written" "a no-op set must not rewrite the file"
  run_real set stoker >/dev/null
  expect_code 2 "$?" "set with no field is a usage error"
  pass "add registers a placeholder with the given fields and refuses a taken or malformed one; set changes only the given fields"
}

test_add_from_mlx_serve_reads_the_registry_and_nothing_more() {
  local out status
  stub_reset
  make_stub_case mlx "$(stub_map)"
  jq -n --arg b "$STUB" '{servers: [
      {id: "mlx-serve", name: "MLX Serve", kind: "mlx-serve", baseURL: $b, modelsPath: "/v1/models", enabled: true, capabilities: ["models", "loadUnload"]},
      {id: "mlx-vlm", name: "MLX-VLM", kind: "openai", baseURL: "http://127.0.0.1:1", enabled: false}]}' > "$CASE_DIR/servers.json"
  cp "$CASE_DIR/servers.json" "$CASE_DIR/servers.orig"
  out=$(run_real add stoker --from-mlx-serve mlx-serve)
  status=$?
  expect_code 0 "$status" "registering a sailor from a running mlx-serve server must succeed: $out"
  assert_equals "{\"endpoint\":\"$STUB/v1\",\"status\":\"placeholder\",\"models\":[\"qwen-coder\",\"qwen-next\",\"qwen-big\"]}" "$(dispatch '.sailors.stoker')" "the endpoint must be baseURL plus /v1 and the models the live list"
  assert_equals "GET /v1/models" "$(cat "$STUB_DIR/requests.log")" "registration may read the model list and nothing else"

  out=$(run_real add narrow --from-mlx-serve mlx-serve --models qwen-big)
  expect_code 0 "$?" "--models may narrow the live list: $out"
  assert_equals '["qwen-big"]' "$(dispatch '.sailors.narrow.models')" "--models must narrow the list"
  out=$(run_real add wrong --from-mlx-serve mlx-serve --models nope)
  expect_code 1 "$?" "a model the server does not list must be refused"
  assert_contains "$out" "refused: mlx-serve server mlx-serve does not list nope" "unlisted-model refusal missing"
  out=$(run_real add vlm --from-mlx-serve mlx-vlm)
  expect_code 1 "$?" "a server that does not answer must be refused"
  assert_contains "$out" "refused: mlx-serve server mlx-vlm is not answering at http://127.0.0.1:1/v1/models (servers.json marks it disabled); fm-sailor.sh never starts a server" "silent-server refusal missing"
  out=$(run_real add ghost --from-mlx-serve ghost)
  expect_code 1 "$?" "an unknown server id must be refused"
  assert_contains "$out" "has no server ghost (it lists: mlx-serve, mlx-vlm)" "unknown-server refusal missing"
  run_real add both --from-mlx-serve mlx-serve --endpoint http://both.local/v1 >/dev/null
  expect_code 2 "$?" "--from-mlx-serve with --endpoint is a usage error"
  cmp -s "$CASE_DIR/servers.orig" "$CASE_DIR/servers.json" || fail "the mlx-serve registry must never be written"
  assert_no_grep "POST" "$STUB_DIR/requests.log" "registration must never load, unload, or ask the server for anything"
  pass "add --from-mlx-serve takes the endpoint and live models from servers.json and the server, never writing the registry or touching the server"
}

test_live_sailor_serving_the_model_passes_check
test_endpoint_trailing_slash_is_not_doubled
test_placeholder_is_refused_without_a_probe
test_silent_endpoint_is_refused
test_endpoint_without_the_model_is_refused
test_unlisted_model_and_unknown_sailor_are_refused
test_capacity_counts_live_task_records
test_provider_json_is_the_opencode_provider_entry
test_validate_is_silent_without_sailors_and_names_the_first_problem
test_check_says_loaded_or_listed_and_warms_on_request
test_status_shows_answer_tasks_queue_and_models
test_set_model_replace_moves_every_profile_of_that_sailor
test_set_model_refusals_write_nothing
test_set_model_says_when_the_model_is_only_listed
test_privateer_home_moves_the_first_mate_and_guards_the_quarantine
test_retire_refuses_busy_sailors_and_removes_emptied_rules
test_add_and_set_edit_one_sailor
test_add_from_mlx_serve_reads_the_registry_and_nothing_more

echo "# all fm-sailor tests passed"
