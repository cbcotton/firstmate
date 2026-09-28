#!/usr/bin/env bash
# tests/fm-sailor.test.sh - named local sailors through bin/fm-sailor.sh:
# map validation, the placeholder lock, the capacity count, the endpoint probe,
# and the OpenCode provider fragment. A fake curl stands in for the sailor's
# model server and logs every URL it is asked for, so a test can prove a probe
# did or did not happen. docs/configuration.md ("Named sailors") owns the contract.
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

test_live_sailor_serving_the_model_passes_check
test_endpoint_trailing_slash_is_not_doubled
test_placeholder_is_refused_without_a_probe
test_silent_endpoint_is_refused
test_endpoint_without_the_model_is_refused
test_unlisted_model_and_unknown_sailor_are_refused
test_capacity_counts_live_task_records
test_provider_json_is_the_opencode_provider_entry
test_validate_is_silent_without_sailors_and_names_the_first_problem

echo "# all fm-sailor tests passed"
