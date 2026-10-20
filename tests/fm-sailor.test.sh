#!/usr/bin/env bash
# tests/fm-sailor.test.sh - named local sailors through bin/fm-sailor.sh:
# map validation, grades, the choice by grade or name, the placeholder lock,
# the capacity count, the endpoint probe, and the OpenCode provider fragment,
# then the warm-up, the status view, and the registry commands, a sailor's
# bearer token and unlisted model ids, and login sailors on fake worker apps. The first cases use a fake curl that
# logs every URL it is asked for, so a test can prove a probe did or did not
# happen; the later
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
case "$url" in
  */chat/completions)
    printf '%s\n200' '{"choices":[{"index":0,"message":{"role":"assistant","content":"OK"}}]}'
    ;;
  *)
    body=${FM_FAKE_MODELS_BODY:-}
    [ -n "$body" ] || body='{"object":"list","data":[{"id":"qwen-coder"},{"id":"qwen-coder-large"}]}'
    printf '%s' "$body"
    ;;
esac
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
  assert_equals "http://127.0.0.1:11234/v1/models
http://127.0.0.1:11234/v1/chat/completions" "$(cat "$CURL_LOG")" "check must probe the model list, then send one tiny completion in OpenCode's shape"
  pass "a live sailor serving the model passes check after a model-list probe and one message-shape probe"
}

test_endpoint_trailing_slash_is_not_doubled() {
  make_case slash "$MAP"
  run_sailor check flint qwen-coder-large >/dev/null
  assert_equals "http://flint.local:8000/v1/models" "$(head -1 "$CURL_LOG")" "a trailing slash on the endpoint must not double in the probe URL"
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

test_model_settings_travel_with_the_model() {
  local out status settings
  settings='{"qwen-coder":{"limit":{"context":131072,"output":16384},"options":{"reasoningEffort":"medium","enable_thinking":true,"temperature":0.6,"top_k":20}}}'
  make_case settings "$(jq -c --argjson s "$settings" '.sailors.tiller.model_settings = $s' <<<"$MAP")"
  out=$(run_sailor validate)
  expect_code 0 "$?" "a well-formed model_settings must validate: $out"
  out=$(run_sailor provider-json tiller qwen-coder)
  assert_equals '{"name":"qwen-coder","limit":{"context":131072,"output":16384},"options":{"reasoningEffort":"medium","enable_thinking":true,"temperature":0.6,"top_k":20}}' "$(jq -c '.tiller.models["qwen-coder"]' <<<"$out")" "provider-json must emit the model's limit and options under that model"
  out=$(run_sailor provider-json flint qwen-coder-large)
  assert_equals '{"name":"qwen-coder-large"}' "$(jq -c '.flint.models["qwen-coder-large"]' <<<"$out")" "a model without settings must emit only its name"
  local bad
  for bad in \
    '.sailors.tiller.model_settings = []|sailor tiller model_settings must be an object' \
    '.sailors.tiller.model_settings = {"other":{}}|sailor tiller model_settings names other, which its models do not list' \
    '.sailors.tiller.model_settings = {"qwen-coder":{"temp":1}}|sailor tiller model_settings for qwen-coder may hold only limit and options' \
    '.sailors.tiller.model_settings = {"qwen-coder":{"limit":{"context":0,"output":8}}}|sailor tiller model_settings for qwen-coder limit must hold both context and output and nothing else, each a positive whole number' \
    '.sailors.tiller.model_settings = {"qwen-coder":{"limit":{"context":131072}}}|sailor tiller model_settings for qwen-coder limit must hold both context and output and nothing else, each a positive whole number' \
    '.sailors.tiller.model_settings = {"qwen-coder":{"limit":{}}}|sailor tiller model_settings for qwen-coder limit must hold both context and output and nothing else, each a positive whole number' \
    '.sailors.tiller.model_settings = {"qwen-coder":{"limit":{"window":8}}}|sailor tiller model_settings for qwen-coder limit must hold both context and output and nothing else, each a positive whole number' \
    '.sailors.tiller.model_settings = {"qwen-coder":{"limit":{"context":"big","output":8}}}|sailor tiller model_settings for qwen-coder limit must hold both context and output and nothing else, each a positive whole number' \
    '.sailors.tiller.model_settings = {"qwen-coder":{"options":{"stop":["a"]}}}|sailor tiller model_settings for qwen-coder options must be an object of strings, numbers and booleans' \
    '.sailors.tiller.model_settings = {"qwen-coder":{"options":3}}|sailor tiller model_settings for qwen-coder options must be an object of strings, numbers and booleans'; do
    make_case settings-bad "$(jq -c "${bad%%|*}" <<<"$MAP")"
    out=$(run_sailor validate)
    status=$?
    expect_code 1 "$status" "a malformed model_settings must be refused: ${bad%%|*}"
    assert_contains "$out" "${bad#*|}" "validate must name the model_settings problem"
  done
  pass "model_settings rides provider-json under its model, an entry without it is unchanged, and validate refuses every malformed shape"
}

test_set_model_carries_settings_and_replace_swaps_them() {
  local out status
  stub_reset
  make_stub_case settings "$(stub_map | jq '.sailors.tiller.models += ["qwen-next"]')"
  out=$(run_real set-model tiller qwen-next --model-limit 65536:8192 --model-options '{"temperature":0.6,"enable_thinking":true}')
  expect_code 0 "$?" "set-model must record settings: $out"
  assert_equals '{"qwen-next":{"limit":{"context":65536,"output":8192},"options":{"temperature":0.6,"enable_thinking":true}}}' "$(dispatch '.sailors.tiller.model_settings')" "settings must be recorded under the model"
  out=$(run_real set-model tiller qwen-next --model-options '{"top_k":20}')
  expect_code 0 "$?" "a later set-model may replace one field: $out"
  assert_equals '{"context":65536,"output":8192}' "$(dispatch '.sailors.tiller.model_settings["qwen-next"].limit')" "a field not given must be kept"
  assert_equals '{"top_k":20}' "$(dispatch '.sailors.tiller.model_settings["qwen-next"].options')" "a field given must replace the recorded one"
  out=$(run_real set-model tiller qwen-big --replace qwen-next)
  expect_code 0 "$?" "replace must succeed: $out"
  assert_equals 'null' "$(dispatch '.sailors.tiller.model_settings')" "replacing a model must drop its settings and leave no empty map"
  out=$(run_real set-model tiller qwen-big --model-limit big)
  expect_code 1 "$?" "a malformed limit must be refused"
  assert_contains "$out" "refused: --model-limit takes <context>:<output> and --model-options takes a JSON object" "limit refusal missing"
  out=$(run_real set-model tiller qwen-big --model-options '{"a":[1]}')
  expect_code 1 "$?" "a non-scalar option must be refused by validation"
  assert_contains "$out" "options must be an object of strings, numbers and booleans" "options refusal must carry validate's reason"
  out=$(run_real set-model tiller qwen-big --model-options nope)
  expect_code 1 "$?" "a non-JSON options value must be refused"
  pass "set-model records limit and options, merges per field, drops them on --replace, and refuses malformed values"
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

test_validate_checks_grades_facets_paid_and_spend() {
  local e='"endpoint":"http://127.0.0.1:1/v1","status":"live"' grades out case json want
  grades='the grades, lowest first, are deckhand, sailor, specialist, expert'
  make_case graded "{\"sailors\":{\"t\":{$e,\"models\":[\"m\"],\"grade\":\"expert\",\"facets\":[\"helm\",\"long-context\"],\"paid\":false},\"u\":{$e,\"models\":[\"m\",\"n\"]}},\"rules\":[{\"when\":\"x\",\"spend\":\"allowed\",\"use\":[{\"harness\":\"opencode\",\"grade\":\"sailor\"},{\"harness\":\"opencode\",\"sailor\":\"t\"}]}]}"
  out=$(run_sailor validate)
  expect_code 0 "$?" "a graded sailor, a grade profile, a model-less profile on a one-model sailor, and an allowed spend must validate"$'\n'"$out"
  while IFS='|' read -r case json want; do
    make_case "bad-$case" "$json"
    out=$(run_sailor validate)
    expect_code 1 "$?" "$case must be invalid"
    assert_equals "$want" "$out" "$case diagnostic mismatch"
  done <<EOF
scout-grade|{"sailors":{"t":{$e,"models":["m"],"grade":"scout"}}}|sailor t grade "scout" is not a grade; $grades
array-grade|{"sailors":{"t":{$e,"models":["m"],"grade":["sailor"]}}}|sailor t grade ["sailor"] is not a grade; $grades
graded-two-models|{"sailors":{"t":{$e,"models":["m","n"],"grade":"sailor"}}}|sailor t has a grade, which describes one bound model, so it must list exactly one model
repeated-facet|{"sailors":{"t":{$e,"models":["m"],"facets":["helm","helm"]}}}|sailor t facets must be a list of distinct lowercase words joined by single dashes
upper-facet|{"sailors":{"t":{$e,"models":["m"],"facets":["Helm"]}}}|sailor t facets must be a list of distinct lowercase words joined by single dashes
text-paid|{"sailors":{"t":{$e,"models":["m"],"paid":"yes"}}}|sailor t paid must be true or false
profile-grade|{"default":{"harness":"opencode","grade":"captain"}}|profile grade "captain" is not a grade; $grades
grade-harness|{"default":{"harness":"claude","grade":"sailor"}}|grade sailor profile must use harness opencode
grade-model|{"default":{"harness":"opencode","grade":"sailor","model":"m"}}|grade sailor profile names a model; the sailor bin/fm-sailor.sh pick chooses brings its own
grade-and-sailor|{"sailors":{"t":{$e,"models":["m"]}},"default":{"harness":"opencode","grade":"sailor","sailor":"t"}}|sailor t profile names a grade too; a profile names a sailor or a grade, not both
modelless-several|{"sailors":{"t":{$e,"models":["m","n"]}},"default":{"harness":"opencode","sailor":"t"}}|sailor t profile names no model, and t lists several; name one
spend-yes|{"rules":[{"when":"x","spend":"yes","use":{"harness":"opencode","grade":"sailor"}}]}|rule "x" spend must be "allowed" when present
fallback-grade|{"sailor_fallback":{"harness":"claude","grade":"sailor"}}|sailor_fallback must not name a grade
EOF
  make_case set-model-graded '{"sailors":{"t":{"endpoint":"http://127.0.0.1:1/v1","status":"placeholder","models":["qwen-coder"],"grade":"sailor"}}}'
  out=$(run_sailor set-model t qwen-coder-large)
  expect_code 1 "$?" "adding a second model to a graded sailor must be refused"
  assert_contains "$out" "refused: sailor t has a grade, which describes one bound model, so it must list exactly one model" "the graded sailor's second model refusal is missing"
  assert_equals $'deckhand\nsailor\nspecialist\nexpert' "$(run_sailor grades)" "grades must print the four grades, lowest first, one per line"
  pass "validate checks each grade, facet list, paid flag, grade profile, model-less profile, rule spend, and fallback, and grades lists the vocabulary"
}

# GRADED: a deckhand, a paid sailor-grade router listed before a free one, an
# unanswering specialist, and an ungraded sailor serving two models.
GRADED='{"sailors":{
  "bonsai":{"endpoint":"http://127.0.0.1:11235/v1","status":"live","models":["qwen-coder"],"grade":"deckhand","max_concurrent":2},
  "lookout":{"endpoint":"https://router.example/v1","status":"live","models":["qwen-coder-large"],"grade":"sailor","paid":true},
  "tiller":{"endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["qwen-coder"],"grade":"sailor","facets":["helm"]},
  "flint":{"endpoint":"http://flint.local:8000/v1","status":"live","models":["qwen-big"],"grade":"specialist"},
  "stoker":{"endpoint":"http://stoker.invalid:8000/v1","status":"placeholder","models":["qwen-big"],"grade":"expert"},
  "old":{"endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["qwen-coder","qwen-coder-large"]}}}'

test_pick_by_grade_takes_the_lowest_sufficient_free_sailor() {
  local out status
  make_case pick-grade "$GRADED"
  out=$(run_sailor pick --grade deckhand)
  expect_code 0 "$?" "a deckhand floor must pick the deckhand"$'\n'"$out"
  assert_equals "bonsai qwen-coder" "$out" "the lowest sufficient grade must come first"
  out=$(run_sailor pick --grade sailor)
  expect_code 0 "$?" "a sailor floor must pick a sailor-grade sailor"$'\n'"$out"
  assert_equals "tiller qwen-coder" "$out" "a free sailor must come before a paid one listed earlier"
  assert_not_contains "$(cat "$CURL_LOG")" "router.example" "a paid sailor must never be probed without --spend"
  out=$(run_sailor pick --grade deckhand --grade sailor)
  assert_equals "tiller qwen-coder" "$out" "a repeated --grade must take the highest floor"
  out=$(run_sailor pick --grade sailor --facet helm)
  assert_equals "tiller qwen-coder" "$out" "--facet must keep only sailors that list it"

  printf 'harness=opencode\nsailor=tiller\n' > "$CASE_DIR/state/busy-a1.meta"
  : > "$CURL_LOG"
  out=$(run_sailor pick --grade sailor)
  status=$?
  expect_code 1 "$status" "with the free sailor busy and no spend, the sailor floor must be refused"
  assert_contains "$out" "refused: no sailor of grade sailor or above can take it now:" "the refusal must name the floor"
  assert_contains "$out" "  lookout/qwen-coder-large: sailor lookout is paid, and spend is not allowed for this task" "the paid sailor must be named as skipped for spend"
  assert_contains "$out" "  tiller/qwen-coder: sailor tiller is at capacity (1 of 1 tasks)" "the busy sailor's refusal must be listed"
  assert_contains "$out" "  flint/qwen-big: sailor flint at http://flint.local:8000/v1 does not serve qwen-big" "a higher grade must be tried after the lower ones"
  assert_not_contains "$out" "stoker" "a placeholder is never a candidate"
  assert_not_contains "$(cat "$CURL_LOG")" "router.example" "a paid sailor must never be probed without --spend"
  out=$(run_sailor pick --grade sailor --spend)
  expect_code 0 "$?" "--spend must let the paid sailor take the task"$'\n'"$out"
  assert_equals "lookout qwen-coder-large" "$out" "with spend allowed, the paid sailor of the lowest sufficient grade must be picked"
  out=$(run_sailor pick --grade sailor --task busy-a1)
  assert_equals "tiller qwen-coder" "$out" "--task must not count the task being relaunched against its own sailor"

  out=$(run_sailor pick --grade expert)
  status=$?
  expect_code 1 "$status" "no live expert must be refused"
  assert_equals "refused: no live sailor has grade expert or above" "$out" "the empty floor refusal mismatch"
  out=$(run_sailor pick --grade scout)
  expect_code 2 "$?" "an unknown grade is a usage error"
  assert_contains "$out" "unknown grade 'scout'; the grades, lowest first, are deckhand, sailor, specialist, expert" "the unknown grade must name the grades"
  run_sailor pick >/dev/null
  expect_code 2 "$?" "pick needs a grade or a sailor"
  run_sailor pick --grade sailor --model qwen-coder >/dev/null
  expect_code 2 "$?" "--model needs --sailor"
  pass "pick by grade takes the lowest sufficient grade, free before paid, a paid sailor only with --spend, and lists every refusal"
}

test_pick_weighs_one_named_sailor_through_the_same_gates() {
  local out
  make_case pick-named "$GRADED"
  out=$(run_sailor pick --sailor bonsai)
  expect_code 0 "$?" "a named sailor with one model must be picked on it"$'\n'"$out"
  assert_equals "bonsai qwen-coder" "$out" "a sailor without --model must use its one model"
  out=$(run_sailor pick --sailor old --model qwen-coder-large)
  assert_equals "old qwen-coder-large" "$out" "--model must name the model to weigh"
  out=$(run_sailor pick --sailor old)
  expect_code 1 "$?" "a sailor with several models needs --model"
  assert_equals "refused: sailor old lists several models (qwen-coder, qwen-coder-large); name one with --model" "$out" "the several-models refusal mismatch"
  out=$(run_sailor pick --sailor bonsai --grade sailor)
  expect_code 1 "$?" "a sailor below the floor must be refused"
  assert_equals "refused: sailor bonsai is grade deckhand, below sailor" "$out" "the below-floor refusal mismatch"
  out=$(run_sailor pick --sailor old --model qwen-coder --grade deckhand)
  assert_equals "refused: sailor old has no grade, so it cannot meet grade deckhand" "$out" "an ungraded sailor must not meet a floor"
  out=$(run_sailor pick --sailor tiller --facet vision)
  assert_equals "refused: sailor tiller has no facet vision" "$out" "a missing facet must be refused"
  : > "$CURL_LOG"
  out=$(run_sailor pick --sailor lookout)
  expect_code 1 "$?" "a paid sailor without --spend must be refused"
  assert_equals "refused: sailor lookout is paid, and spend is not allowed for this task" "$out" "the paid refusal mismatch"
  [ ! -s "$CURL_LOG" ] || fail "a paid sailor must be refused before any probe, but curl was called: $(cat "$CURL_LOG")"
  out=$(run_sailor pick --sailor lookout --spend)
  assert_equals "lookout qwen-coder-large" "$out" "--spend must let a named paid sailor through"
  out=$(run_sailor pick --sailor stoker)
  assert_contains "$out" "refused: sailor stoker is a placeholder" "a named placeholder must be refused by check"
  out=$(run_sailor pick --sailor nosuch)
  assert_equals "refused: unknown sailor nosuch" "$out" "an unknown sailor must be refused"
  pass "pick --sailor weighs one sailor on its one model or --model, through the grade, facet, spend, and check gates"
}

# --- the local HTTP stub ------------------------------------------------------
#
# A python3 server answers GET /v1/models, /metrics, and /health and POST
# /v1/chat/completions from control files in STUB_DIR and logs one line per
# request, with a completion's message roles, to STUB_DIR/requests.log, so a
# case can drive loaded versus listed models, a failed warm-up, a slow load, a
# refused completion, and the queue gauges, and prove which
# requests the script made; STUB_DIR/auth.log gets the same request with the
# Authorization header it carried, or - for none.

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
import http.server, json, os, sys, threading, time

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
        with open(os.path.join(root, "auth.log"), "a") as f:
            f.write("%s %s\n" % (line.split(" model=")[0], self.headers.get("Authorization") or "-"))

    def reply(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.note("GET " + self.path)
        body = {"/v1/models": read("models.json"), "/metrics": read("metrics.txt"), "/health": read("health.json")}.get(self.path)
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
        messages = req.get("messages") if isinstance(req.get("messages"), list) else []
        roles = [m.get("role") for m in messages if isinstance(m, dict)]
        self.note("POST %s model=%s max_tokens=%s roles=%s"
                  % (self.path, req.get("model"), req.get("max_tokens"), ",".join(roles)))
        if self.path != "/v1/chat/completions":
            self.reply(404, '{"error":"not found"}')
            return
        time.sleep(float((read("chat.delay") or "0").strip()))
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
# metrics, no /health (a 404), successful completions in any message shape,
# and an empty request log.
stub_reset() {
  start_stub
  rm -f "$STUB_DIR/metrics.txt" "$STUB_DIR/health.json" "$STUB_DIR/chat.code" "$STUB_DIR/chat.body" "$STUB_DIR/chat.delay"
  printf '%s' "${1:-$STUB_MODELS}" > "$STUB_DIR/models.json"
  : > "$STUB_DIR/requests.log"
  : > "$STUB_DIR/auth.log"
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

test_check_says_loaded_or_listed() {
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
  assert_contains "$out" "model was listed but not loaded, so the probe loaded it" "check must say its probe loaded an unloaded model"
  assert_equals "GET /v1/models
POST /v1/chat/completions model=qwen-big max_tokens=1 roles=system,user" \
    "$(tail -2 "$STUB_DIR/requests.log")" "check must send one tiny completion in a sailor worker's shape"
  : > "$STUB_DIR/requests.log"
  run_real status >/dev/null
  assert_no_grep "POST" "$STUB_DIR/requests.log" "status must never ask the model for a completion"
  run_real check tiller qwen-big --warm >/dev/null
  expect_code 2 "$?" "check takes no --warm; set-model owns the warm-up"
  pass "check says whether the model is loaded or only listed and sends one tiny completion, while status never does"
}

test_check_bounds_an_unloaded_models_probe_by_the_warm_timeout() {
  local out status
  stub_reset
  make_stub_case unloaded-bound "$(stub_map)"
  printf '2' > "$STUB_DIR/chat.delay"
  out=$(FM_SAILOR_SMOKE_TIMEOUT=1 FM_SAILOR_WARM_TIMEOUT=10 run_real check tiller qwen-big)
  status=$?
  expect_code 0 "$status" "an unloaded model's probe must wait the warm-up bound while the server loads it: $out"
  assert_contains "$out" "model was listed but not loaded, so the probe loaded it" "the ok line must say the probe loaded the model"
  out=$(FM_SAILOR_SMOKE_TIMEOUT=1 FM_SAILOR_WARM_TIMEOUT=10 run_real check tiller qwen-coder)
  status=$?
  expect_code 1 "$status" "a loaded model's probe must keep the short bound"
  assert_contains "$out" "no completion from $STUB/v1 within 1 seconds" "a loaded model's refusal must name the short bound"
  out=$(FM_SAILOR_SMOKE_TIMEOUT=1 FM_SAILOR_WARM_TIMEOUT=1 run_real check tiller qwen-big)
  status=$?
  expect_code 1 "$status" "an unloaded model that does not load within the warm-up bound must be refused"
  assert_contains "$out" "no completion from $STUB/v1 within 1 seconds (the model was listed but not loaded, so the probe also had to load it)" \
    "the refusal must say the probe had to load the model"
  rm -f "$STUB_DIR/chat.delay"
  pass "check bounds an unloaded model's probe by FM_SAILOR_WARM_TIMEOUT and a loaded one's by FM_SAILOR_SMOKE_TIMEOUT"
}

test_check_sends_opencodes_message_shape() {
  local out status
  stub_reset
  make_stub_case shape "$(stub_map)"
  out=$(run_real check tiller qwen-coder)
  status=$?
  expect_code 0 "$status" "an endpoint that accepts a sailor worker's message shape must pass: $out"
  assert_equals "GET /v1/models
POST /v1/chat/completions model=qwen-coder max_tokens=1 roles=system,user" "$(cat "$STUB_DIR/requests.log")" \
    "check must send one one-token completion with one system message and the user message"
  pass "check passes an endpoint that accepts one tiny completion in a sailor worker's folded message shape"
}

test_check_refuses_an_endpoint_that_rejects_the_shape() {
  local out status
  stub_reset
  make_stub_case shape-refused "$(stub_map)"
  printf '400' > "$STUB_DIR/chat.code"
  printf '%s' '{"error":{"message":"System message must be at the beginning."}}' > "$STUB_DIR/chat.body"
  out=$(run_real check tiller qwen-coder)
  status=$?
  expect_code 1 "$status" "an endpoint that refuses the completion must be refused"
  assert_equals "refused: sailor tiller at $STUB/v1 did not answer a one-token request in a sailor worker's message shape (one system message, then the user message): HTTP 400: System message must be at the beginning." "$out" \
    "the refusal must name the endpoint's error"
  pass "check refuses an endpoint that answers an error to a sailor worker's message shape, naming its error"
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
  printf '{"error":{"message":"not enough free memory to load qwen-next"}}' > "$STUB_DIR/chat.body"
  out=$(run_real set-model tiller qwen-next --warm)
  status=$?
  expect_code 1 "$status" "a failed warm-up must refuse the swap"
  assert_contains "$out" "refused: sailor tiller could not load qwen-next: HTTP 507: not enough free memory to load qwen-next" "the warm-up refusal must carry the server's reason"

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
  : > "$STUB_DIR/requests.log"
  out=$(run_real set-model tiller qwen-next --warm --dry-run)
  expect_code 1 "$?" "a dry run must refuse --warm"
  assert_contains "$out" "refused: --dry-run loads nothing" "dry-run warm refusal missing"
  assert_no_grep "POST" "$STUB_DIR/requests.log" "a dry run must not ask the server to load a model"
  assert_unchanged "a dry run with --warm"
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
  out=$(run_real add hosted --endpoint http://api.example.com/v1 --models coder)
  status=$?
  expect_code 1 "$status" "a plaintext public endpoint must be refused in a Privateer home"
  assert_contains "$out" "refused: the change would break this home's Privateer quarantine:" "quarantine refusal missing"
  assert_contains "$out" "sailor hosted has endpoint 'http://api.example.com/v1', which is not on this machine or the local network and is not https" "the refusal must carry the quarantine's own reason"
  out=$(run_real add hosted --endpoint https://api.anthropic.com/v1 --models coder)
  expect_code 1 "$?" "an Anthropic endpoint must be refused in a Privateer home"
  assert_contains "$out" "sailor hosted has endpoint 'https://api.anthropic.com/v1', on an Anthropic or Claude host" "the refusal must name the Anthropic host"
  out=$(run_real retire tiller)
  expect_code 1 "$?" "retiring the first mate's sailor must be refused"
  assert_contains "$out" "config/privateer names tiller/qwen-next, but config/crew-dispatch.json lists no such sailor and model" "retire refusal must carry the quarantine's reason"
  assert_unchanged "the quarantine refusals"
  pass "in a Privateer home set-model --first-mate moves the first mate's line, and any change the quarantine would report is refused"
}

test_privateer_first_mate_sailor_stays_live_and_restarts_only_when_it_changes() {
  local out status
  stub_reset
  make_privateer_case fmlive
  out=$(run_real set tiller --placeholder)
  status=$?
  expect_code 1 "$status" "parking the first mate's sailor must be refused"
  assert_contains "$out" "refused: the first mate runs on tiller/qwen-coder, and the first mate runs only on a live sailor" "placeholder refusal missing"
  assert_unchanged "the placeholder refusal"

  out=$(run_real set-model tiller qwen-next)
  status=$?
  expect_code 0 "$status" "adding a model to the first mate's sailor must succeed: $out"
  assert_contains "$out" "workers: the change applies from each worker's next spawn" "set-model must say when workers switch"
  assert_not_contains "$out" "first mate:" "only adding a model must not ask for a first-mate restart"
  out=$(run_real set tiller --host "this Mac")
  expect_code 0 "$?" "a host change must succeed: $out"
  assert_not_contains "$out" "first mate:" "a host change must not ask for a first-mate restart"
  out=$(run_real set tiller --endpoint "http://localhost:${STUB##*:}/v1")
  expect_code 0 "$?" "an endpoint change to this machine must succeed: $out"
  assert_contains "$out" "first mate: restart the Privateer session to switch" "an endpoint change must ask for a first-mate restart"
  out=$(run_real set-model tiller qwen-coder --model-options '{"temperature":0.6}')
  expect_code 0 "$?" "a settings change must succeed: $out"
  assert_contains "$out" "first mate: restart the Privateer session to switch" "a settings change on the first mate's model must ask for a restart"
  pass "in a Privateer home the first mate's sailor cannot be parked, and only changes to what the first mate uses ask for a restart"
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
  run_real set stoker --live --dry-run >/dev/null
  expect_code 2 "$?" "only set-model takes --dry-run"
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

test_health_probes_the_mlx_serve_health_path() {
  local out status
  stub_reset
  make_stub_case health "$(stub_map | jq '.sailors.stoker = {endpoint: "http://127.0.0.1:1/v1", status: "live", models: ["qwen-coder"]}')"
  jq -n --arg b "$STUB/" '{servers: [
      {id: "near-miss", baseURL: ($b + "v"), healthPath: "/never"},
      {id: "mlx-serve", kind: "mlx-serve", baseURL: $b, modelsPath: "/v1/models", healthPath: "/health", enabled: true}]}' > "$CASE_DIR/servers.json"
  printf '{"status":"ok"}' > "$STUB_DIR/health.json"
  out=$(run_real health)
  status=$?
  expect_code 0 "$status" "health must exit 0 whatever the sailors answer: $out"
  assert_equals "tiller up $STUB/health
stoker down http://127.0.0.1:1/v1/models" "$out" "an mlx-serve sailor must be probed at its server's healthPath, any other at <endpoint>/models, and a placeholder not at all"
  assert_equals "GET /health" "$(cat "$STUB_DIR/requests.log")" "the health probe of an mlx-serve sailor must read only the healthPath"

  rm -f "$STUB_DIR/health.json"
  out=$(run_real health)
  assert_contains "$out" "tiller down $STUB/health" "a healthPath that fails must read down even while the model list answers"

  jq '.servers |= map(del(.healthPath))' "$CASE_DIR/servers.json" > "$CASE_DIR/servers.tmp" && mv "$CASE_DIR/servers.tmp" "$CASE_DIR/servers.json"
  out=$(run_real health)
  assert_contains "$out" "tiller up $STUB/v1/models" "a server without a healthPath must keep the model-list probe"
  rm -f "$CASE_DIR/servers.json"
  out=$(run_real health)
  assert_contains "$out" "tiller up $STUB/v1/models" "without the registry a sailor must keep the model-list probe"

  make_stub_case health-none "$(stub_map | jq '.sailors.tiller.status = "placeholder"')"
  out=$(run_real health)
  expect_code 0 "$?" "a home with no live sailor must still exit 0"
  assert_equals "" "$out" "a home with no live sailor must print nothing"
  pass "health probes an mlx-serve sailor at its server's healthPath and any other sailor at its model list"
}

test_status_and_list_show_the_grade_of_a_graded_sailor_only() {
  local out
  stub_reset
  make_stub_case grade "$(stub_map | jq 'del(.rules) | .sailors.tiller.models = ["qwen-coder"] | .sailors.tiller.grade = "specialist"')"
  out=$(run_real status)
  assert_equals "tiller live answering endpoint=$STUB/v1 tasks=0/1 grade=specialist models=qwen-coder(loaded)" "$out" "a graded sailor's status line must carry its grade"
  out=$(run_real status --all)
  assert_contains "$out" "flint placeholder not-answering endpoint=http://127.0.0.1:1/v1 tasks=0/1" "an ungraded sailor's status line must omit grade"
  assert_not_contains "$out" "flint placeholder not-answering endpoint=http://127.0.0.1:1/v1 tasks=0/1 grade" "an ungraded sailor's status line must omit grade"
  out=$(run_real list)
  assert_contains "$out" "tiller status=live endpoint=$STUB/v1 max_concurrent=1 grade=specialist models=qwen-coder" "a graded sailor's list line must carry its grade"
  assert_contains "$out" "flint status=placeholder endpoint=http://127.0.0.1:1/v1 max_concurrent=1 models=qwen-coder" "an ungraded sailor's list line must omit grade"
  pass "status and list carry grade=<grade> for a graded sailor and omit it for an ungraded one"
}

test_status_answering_agrees_with_the_health_probe() {
  local out
  stub_reset
  make_stub_case status-health "$(stub_map)"
  jq -n --arg b "$STUB/" '{servers: [{id: "mlx-serve", kind: "mlx-serve", baseURL: $b, healthPath: "/health"}]}' > "$CASE_DIR/servers.json"

  out=$(run_real status)
  expect_code 0 "$?" "status is a view and exits 0"
  assert_equals "tiller live not-answering endpoint=$STUB/v1 tasks=0/1" "$out" "a sailor whose healthPath fails must read not-answering even while its model list answers"
  assert_contains "$(run_real health)" "tiller down" "health must agree that the sailor is down"

  printf '{"status":"ok"}' > "$STUB_DIR/health.json"
  rm -f "$STUB_DIR/models.json"
  out=$(run_real status)
  assert_equals "tiller live answering endpoint=$STUB/v1 tasks=0/1" "$out" "a sailor whose healthPath answers must read answering even while its model list fails"
  assert_contains "$(run_real health)" "tiller up" "health must agree that the sailor is up"
  pass "status reads a sailor as answering by the same probe health uses, its mlx-serve healthPath"
}

test_health_probes_every_sailor_at_once_within_the_bound() {
  local hole_dir="$TMP_ROOT/hole" hole_pid port start elapsed out
  mkdir -p "$hole_dir"
  # A listener that accepts connections and never answers, so every probe
  # runs to its timeout.
  python3 - "$hole_dir" <<'PY' &
import os, socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(16)
with open(os.path.join(sys.argv[1], "port.tmp"), "w") as f:
    f.write(str(s.getsockname()[1]))
os.rename(os.path.join(sys.argv[1], "port.tmp"), os.path.join(sys.argv[1], "port"))
time.sleep(30)
PY
  hole_pid=$!
  for _ in $(seq 100); do
    [ -s "$hole_dir/port" ] && break
    sleep 0.1
  done
  [ -s "$hole_dir/port" ] || fail "the silent listener did not start"
  port=$(cat "$hole_dir/port")
  make_stub_case health-bound "$(jq -n --arg e "http://127.0.0.1:$port/v1" '{sailors: {
      a: {endpoint: $e, status: "live", models: ["m"]},
      b: {endpoint: $e, status: "live", models: ["m"]},
      c: {endpoint: $e, status: "live", models: ["m"]}}}')"
  start=$(date +%s)
  out=$(FM_SAILOR_PROBE_TIMEOUT=2 run_real health)
  elapsed=$(( $(date +%s) - start ))
  kill "$hole_pid" 2>/dev/null
  wait "$hole_pid" 2>/dev/null
  assert_equals "a down http://127.0.0.1:$port/v1/models
b down http://127.0.0.1:$port/v1/models
c down http://127.0.0.1:$port/v1/models" "$out" "a sailor that never answers must read down"
  [ "$elapsed" -lt 5 ] || fail "three silent sailors took ${elapsed}s, so they were not probed at once within the 2s bound"
  pass "health probes every sailor at once, so the whole run stays within about one probe timeout"
}

test_status_probes_every_sailor_at_once_within_the_bound() {
  local start elapsed out i
  make_stub_case status-bound "$(jq -n '{sailors: {
      a: {endpoint: "http://127.0.0.1:1/v1", status: "live", models: ["m"]},
      b: {endpoint: "http://10.255.255.1/v1", status: "live", models: ["m"]},
      c: {endpoint: "http://10.255.255.2/v1", status: "live", models: ["m"]},
      d: {endpoint: "http://10.255.255.3/v1", status: "live", models: ["m"]}}}')"
  start=$(date +%s)
  out=$(FM_SAILOR_PROBE_TIMEOUT=2 run_real status)
  elapsed=$(( $(date +%s) - start ))
  for i in a b c d; do
    assert_contains "$out" "$i live not-answering endpoint=" "sailor $i must read not-answering"
  done
  assert_equals "a b c d" "$(printf '%s\n' "$out" | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')" "status must keep the registry order"
  [ "$elapsed" -lt 5 ] || fail "four down sailors took ${elapsed}s, so status did not probe them at once within the 2s bound"
  pass "status probes every sailor at once, so a down sailor adds no time"
}

# --- sailor tokens -------------------------------------------------------------
#
# A sailor's token lives in its home's .env (or the environment) under the
# variable its auth_env names. The sentinel stands in for a real token, so any
# copy of it outside .env, the request headers, or a command the test itself
# hands the value to is a leak.

TOKEN_VAR=FM_TEST_SAILOR_TOKEN
SENTINEL=fm-sentinel-token-7c1d0e5b
unset "$TOKEN_VAR"

# token_map: stub_map with tiller taking its token from TOKEN_VAR, and router,
# a second sailor on the stub that serves model ids its list leaves out.
token_map() {
  stub_map | jq --arg v "$TOKEN_VAR" '.sailors.tiller.auth_env = $v
    | .sailors.router = {endpoint: .sailors.tiller.endpoint, status: "live", models: ["org/routed-model:cheapest"], auth_env: $v, unlisted_models: true}'
}

set_token() {  # <value>: the case home's .env line for TOKEN_VAR
  printf '%s=%s\n' "$TOKEN_VAR" "$1" > "$CASE_DIR/.env"
}

# assert_no_leak <output> <msg>: the sentinel is in neither <output> nor any
# file of the case home but its .env.
assert_no_leak() {
  local leaks
  assert_not_contains "$1" "$SENTINEL" "$2: the token was printed"
  leaks=$(grep -rl --exclude=.env -- "$SENTINEL" "$CASE_DIR" 2>/dev/null)
  [ -z "$leaks" ] || fail "$2: the token was written to $leaks"
}

test_token_rides_every_request_and_is_never_printed() {
  local out status lines bearer
  stub_reset
  make_stub_case token-plain "$(stub_map)"
  run_real check tiller qwen-coder >/dev/null
  expect_code 0 "$?" "a sailor without auth_env must pass as before"
  assert_equals "GET /v1/models -
POST /v1/chat/completions -" "$(cat "$STUB_DIR/auth.log")" "a sailor without auth_env must send no Authorization header"

  stub_reset
  make_stub_case token "$(token_map)"
  set_token "$SENTINEL"
  out=$(run_real check tiller qwen-coder)
  status=$?
  expect_code 0 "$status" "a sailor with its token must pass check: $out"
  out="$out"$'\n'$(run_real status --all)$'\n'$(run_real health)$'\n'$(run_real set-model tiller qwen-next)$'\n'$(run_real list)
  assert_contains "$out" "sailor tiller lists qwen-next" "set-model must reach a token sailor's model list: $out"
  assert_contains "$out" "auth_env=$TOKEN_VAR" "list must name the variable"
  lines=$(wc -l < "$STUB_DIR/auth.log" | tr -d ' ')
  bearer=$(grep -c " Bearer $SENTINEL\$" "$STUB_DIR/auth.log")
  [ "$lines" -gt 3 ] || fail "check, status, health, and set-model must each have probed the stub: $(cat "$STUB_DIR/auth.log")"
  assert_equals "$lines" "$bearer" "every request to a token sailor must carry Authorization: Bearer <token>: $(cat "$STUB_DIR/auth.log")"
  assert_equals 1 "$(grep -c '^POST' "$STUB_DIR/requests.log")" "check's one completion must be the only completion probe"
  assert_no_leak "$out" "check, status, health, set-model, and list"

  : > "$STUB_DIR/auth.log"
  out=$(env "$TOKEN_VAR=from-the-environment" FM_HOME="$CASE_DIR" FM_CONFIG_OVERRIDE="$CASE_DIR/config" FM_STATE_OVERRIDE="$CASE_DIR/state" \
    FM_MLX_SERVE_SERVERS="$CASE_DIR/servers.json" "$SAILOR" check tiller qwen-coder 2>&1)
  expect_code 0 "$?" "a token set in the environment must pass: $out"
  assert_equals "GET /v1/models Bearer from-the-environment
POST /v1/chat/completions Bearer from-the-environment" "$(cat "$STUB_DIR/auth.log")" "the environment's token must win over .env"

  out=$(run_real provider-json tiller qwen-coder)
  assert_equals "{\"baseURL\":\"$STUB/v1\",\"apiKey\":\"{env:$TOKEN_VAR}\"}" "$(jq -c '.tiller.options' <<<"$out")" \
    "the provider entry must point OpenCode at the variable, never carry its value"
  assert_no_leak "$out" "provider-json"
  pass "a token sailor's every probe carries its bearer token, the environment's over .env's, while output and files never hold it and local sailors send none"
}

test_missing_token_refuses_naming_only_the_variable() {
  local out status
  stub_reset
  make_stub_case token-missing "$(token_map)"
  out=$(run_real check tiller qwen-coder)
  status=$?
  expect_code 1 "$status" "a token sailor without its token must be refused"
  assert_equals "refused: sailor tiller has no token: $TOKEN_VAR is set in neither the environment nor $CASE_DIR/.env" "$out" \
    "the refusal must name the variable and where it was looked for"
  [ ! -s "$STUB_DIR/requests.log" ] || fail "a sailor without its token must not be probed: $(cat "$STUB_DIR/requests.log")"
  out=$(run_real health)
  assert_contains "$out" "tiller down $STUB/v1/models" "a sailor without its token must read down"
  out=$(run_real status --all)
  assert_contains "$out" "tiller live no-token endpoint=$STUB/v1 tasks=0/1 auth_env=$TOKEN_VAR" "status must say the token is missing and name its variable"
  [ ! -s "$STUB_DIR/requests.log" ] || fail "health and status must not probe a sailor without its token: $(cat "$STUB_DIR/requests.log")"
  out=$(run_real set-model tiller qwen-next)
  expect_code 1 "$?" "set-model must refuse a live sailor without its token"
  assert_contains "$out" "refused: sailor tiller has no token: $TOKEN_VAR is set in neither" "the set-model refusal must name the variable"
  assert_unchanged "the missing-token refusal"

  printf '%s="%s with space"\n' "$TOKEN_VAR" "$SENTINEL" > "$CASE_DIR/.env"
  out=$(run_real check tiller qwen-coder)
  expect_code 1 "$?" "a token holding whitespace must be refused"
  assert_equals "refused: sailor tiller has no token: $TOKEN_VAR holds whitespace or a control character" "$out" "the refusal must say why without the value"
  [ ! -s "$STUB_DIR/requests.log" ] || fail "a malformed token must never be sent"
  assert_not_contains "$out" "$SENTINEL" "a malformed token must not be printed"
  pass "a token sailor without a usable token is refused, down, and no-token, naming its variable and never a value, and is never probed"
}

test_with_token_hands_the_value_to_the_command_alone() {
  local out status
  make_stub_case with-token "$(token_map)"
  out=$(run_real with-token "$TOKEN_VAR" "$CASE_DIR/.env" -- printenv "$TOKEN_VAR")
  status=$?
  expect_code 1 "$status" "with-token must refuse when neither the environment nor the file sets the variable"
  assert_equals "refused: $TOKEN_VAR is set in neither the environment nor $CASE_DIR/.env, so the sailor's token is missing" "$out" "the refusal must name the variable"
  set_token "$SENTINEL"
  out=$(run_real with-token "$TOKEN_VAR" "$CASE_DIR/.env" -- printenv "$TOKEN_VAR")
  expect_code 0 "$?" "with-token must exec the command"
  assert_equals "$SENTINEL" "$out" "the command must find the token in its environment"
  out=$(env "$TOKEN_VAR=from-the-environment" "$SAILOR" with-token "$TOKEN_VAR" "$CASE_DIR/.env" -- printenv "$TOKEN_VAR" 2>&1)
  assert_equals "from-the-environment" "$out" "the environment's value must win over the file's"
  run_real with-token 'BAD-NAME' "$CASE_DIR/.env" -- true >/dev/null
  expect_code 2 "$?" "with-token takes only a variable name"
  run_real with-token "$TOKEN_VAR" "$CASE_DIR/.env" true >/dev/null
  expect_code 2 "$?" "with-token needs -- before the command"
  pass "with-token puts the token in the command's environment, the environment's over the file's, and refuses naming the variable"
}

test_unlisted_models_lets_a_router_serve_ids_it_does_not_list() {
  local out status
  stub_reset
  make_stub_case unlisted "$(token_map)"
  set_token "$SENTINEL"
  out=$(run_real check router org/routed-model:cheapest)
  status=$?
  expect_code 0 "$status" "a sailor with unlisted_models must pass for a listed id its endpoint leaves out: $out"
  assert_contains "$out" "model not in the endpoint's list, which this sailor's unlisted_models allows" "check must say the model was not in the endpoint's list"
  out=$(run_real status --all)
  assert_contains "$out" "models=org/routed-model:cheapest(unlisted)" "status must show the unlisted model as unlisted, not missing"
  : > "$STUB_DIR/requests.log"
  out=$(run_real set-model router org/other-model:fastest)
  expect_code 0 "$?" "set-model must accept an unlisted id on a sailor with unlisted_models: $out"
  cp "$CASE_DIR/config/crew-dispatch.json" "$CASE_DIR/original.json"
  rm -f "$CASE_DIR/config/"*.bak-*
  out=$(run_real set-model tiller org/other-model:fastest)
  expect_code 1 "$?" "set-model must still refuse an unlisted id on a sailor without unlisted_models"
  assert_contains "$out" "does not serve org/other-model:fastest" "the refusal must say the endpoint does not serve it"
  assert_unchanged "the unlisted-model refusal"
  assert_no_grep "POST" "$STUB_DIR/requests.log" "set-model must never ask for a completion"
  pass "unlisted_models lets a router serve ids its model list leaves out, with no completion from set-model, and only on the sailor that sets it"
}

test_registry_records_auth_env_and_unlisted_models() {
  local out status
  stub_reset
  make_stub_case registry-token "$(stub_map)"
  out=$(run_real add hf --endpoint https://router.example.test/v1 --models 'org/model:cheapest' --auth-env "$TOKEN_VAR" --unlisted-models --live)
  status=$?
  expect_code 0 "$status" "adding an external token sailor must succeed: $out"
  assert_equals "{\"endpoint\":\"https://router.example.test/v1\",\"status\":\"live\",\"models\":[\"org/model:cheapest\"],\"auth_env\":\"$TOKEN_VAR\",\"unlisted_models\":true}" \
    "$(dispatch '.sailors.hf')" "add must record auth_env and unlisted_models"
  out=$(run_real list)
  assert_contains "$out" "hf status=live endpoint=https://router.example.test/v1 max_concurrent=1 models=org/model:cheapest auth_env=$TOKEN_VAR unlisted_models=true" "list must show both fields"
  out=$(run_real set hf --no-auth-env --no-unlisted-models)
  expect_code 0 "$?" "set must remove both fields: $out"
  assert_equals '{"endpoint":"https://router.example.test/v1","status":"live","models":["org/model:cheapest"]}' "$(dispatch '.sailors.hf')" "set --no-* must remove exactly those fields"
  run_real set hf --auth-env OTHER_TOKEN >/dev/null
  assert_equals '"OTHER_TOKEN"' "$(dispatch '.sailors.hf.auth_env')" "set --auth-env must record the variable"
  out=$(run_real set hf --auth-env 'not-a-name')
  expect_code 1 "$?" "a malformed variable name must be refused"
  assert_contains "$out" "refused: sailor hf auth_env must name an environment variable" "the refusal must carry validate's reason"

  make_stub_case registry-validate "$(stub_map | jq '.sailors.tiller.unlisted_models = "yes"')"
  out=$(run_real validate)
  expect_code 1 "$?" "a non-boolean unlisted_models must be invalid"
  assert_equals "sailor tiller unlisted_models must be true or false" "$out" "validate must name the unlisted_models problem"

  make_stub_case registry-mlx "$(stub_map)"
  jq -n --arg b "$STUB" '{servers: [{id: "router", kind: "openai", baseURL: $b, modelsPath: "/v1/models", healthPath: "/v1/models", enabled: true}]}' > "$CASE_DIR/servers.json"
  out=$(run_real add hf --from-mlx-serve router --models 'org/routed-model:cheapest' --auth-env "$TOKEN_VAR" --unlisted-models)
  expect_code 1 "$?" "registering a token sailor without its token must be refused"
  assert_contains "$out" "refused: sailor hf has no token: $TOKEN_VAR is set in neither" "the refusal must name the variable"
  [ ! -s "$STUB_DIR/requests.log" ] || fail "a registration without its token must not reach the server"
  set_token "$SENTINEL"
  out=$(run_real add hf --from-mlx-serve router --models 'org/routed-model:cheapest' --auth-env "$TOKEN_VAR")
  expect_code 1 "$?" "an id the server does not list must still be refused without --unlisted-models"
  out=$(run_real add hf --from-mlx-serve router --models 'org/routed-model:cheapest' --auth-env "$TOKEN_VAR" --unlisted-models --live)
  expect_code 0 "$?" "--unlisted-models must let --models name an id the server does not list: $out"
  assert_equals "{\"endpoint\":\"$STUB/v1\",\"status\":\"live\",\"models\":[\"org/routed-model:cheapest\"],\"auth_env\":\"$TOKEN_VAR\",\"unlisted_models\":true}" \
    "$(dispatch '.sailors.hf')" "the registered sailor must carry the router's endpoint, the routed id, and both fields"
  assert_equals "GET /v1/models Bearer $SENTINEL" "$(tail -1 "$STUB_DIR/auth.log")" "the registry's model list must be read with the token"
  out=$(run_real health)
  assert_contains "$out" "hf up $STUB/v1/models" "the router's health path must answer with the token"
  assert_no_leak "$out" "registration and health"
  assert_no_grep "POST" "$STUB_DIR/requests.log" "registration must never ask for a completion"
  pass "add and set record auth_env and unlisted_models, and add --from-mlx-serve reads a token router's list with the token and takes its routed ids"
}

# --- the slot registry --------------------------------------------------------
#
# sync probes nothing, so these cases run with the fake curl, whose empty log
# proves it, against a scratch slot registry and mlx-serve registry.

HAND_MAP='{"sailors":{
  "tiller":{"endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["qwen-coder"]},
  "bonsai-1":{"endpoint":"http://127.0.0.1:11310/v1","status":"live","models":["bonsai-2bit"],"max_concurrent":3}},
 "rules":[
  {"when":"small clear work","use":[{"harness":"opencode","sailor":"bonsai-1","model":"bonsai-2bit"}]},
  {"when":"tiller only","use":{"harness":"opencode","sailor":"tiller","model":"qwen-coder"}},
  {"when":"mixed","use":[{"harness":"opencode","sailor":"tiller","model":"qwen-coder"},{"harness":"claude","model":"claude-sonnet-5-5"}]}],
 "default":[{"harness":"claude","model":"claude-sonnet-5-5"}],
 "sailor_fallback":{"harness":"claude","model":"claude-opus-5-5"}}'

# make_sync_case <name> <map-json>: a home holding <map-json> whose
# config/sailor-registry names REGISTRY, beside three mlx-serve servers.
make_sync_case() {
  make_case "$1" "$2"
  cp "$CASE_DIR/config/crew-dispatch.json" "$CASE_DIR/original.json"
  REGISTRY="$CASE_DIR/sailors.json"
  printf '# slot registry\n%s\n' "$REGISTRY" > "$CASE_DIR/config/sailor-registry"
  jq -n '{servers: [
      {id: "mlx-serve", name: "MLX Serve", kind: "mlx-serve", baseURL: "http://127.0.0.1:11234", enabled: true},
      {id: "bonsai-1", name: "Bonsai", baseURL: "http://127.0.0.1:11310/"},
      {id: "hf-inference", name: "Hugging Face", kind: "openai", baseURL: "https://router.huggingface.co"}]}' > "$CASE_DIR/servers.json"
}

# slot_registry [<jq-filter>]: write REGISTRY, edited by <jq-filter>: tiller is
# the Privateer first mate's slot, bonsai-1 is shared by both homes, lookout is
# a paid routed placeholder with a token, and stoker is blank.
slot_registry() {
  jq -n --arg h "$CASE_DIR" '{schema: 1,
    homes: {firstmate: $h, privateer: "/nonexistent/privateer"},
    privateer_first_mate: "tiller",
    slots: {
      tiller: {title: "Tiller", server: "mlx-serve", model: "qwen-coder", grade: "sailor", facets: ["helm"], capacity: 1,
               homes: {privateer: 1}, status: "live", model_settings: {"qwen-coder": {limit: {context: 131072, output: 16384}}}},
      "bonsai-1": {title: "Bonsai 1", server: "bonsai-1", model: "bonsai-2bit", grade: "deckhand", capacity: 3,
                   homes: {firstmate: 2, privateer: 1}, status: "live"},
      lookout: {title: "Lookout", server: "hf-inference", model: "org/model:cheapest", grade: "sailor", paid: true,
                auth_env: "HF_TOKEN", unlisted_models: true, capacity: 2, homes: {firstmate: 1, privateer: 1}, status: "placeholder"},
      stoker: {title: "Stoker"}}}' | jq "${1:-.}" > "$REGISTRY"
}

run_sync() {
  PATH="$FAKEBIN:$PATH" FM_FAKE_CURL_LOG="$CURL_LOG" FM_HOME="$CASE_DIR" \
    FM_CONFIG_OVERRIDE="$CASE_DIR/config" FM_STATE_OVERRIDE="$CASE_DIR/state" \
    FM_MLX_SERVE_SERVERS="$CASE_DIR/servers.json" "$SAILOR" "$@" 2>&1
}

test_sync_projects_this_homes_share_of_each_bound_slot() {
  local out status
  make_sync_case sync "$HAND_MAP"
  slot_registry
  cp "$REGISTRY" "$CASE_DIR/registry.orig"
  cp "$CASE_DIR/servers.json" "$CASE_DIR/servers.orig"
  out=$(run_sync sync "$REGISTRY" --home firstmate --dry-run)
  expect_code 0 "$?" "a dry run must succeed: $out"
  assert_contains "$out" '+    "lookout": {' "a dry run must show the change"
  assert_contains "$out" "dry run: nothing written" "a dry run must say it wrote nothing"
  assert_unchanged "the dry run"

  out=$(run_sync sync "$REGISTRY" --home firstmate)
  status=$?
  expect_code 0 "$status" "a sync from a well-formed registry must succeed: $out"
  assert_equals '["bonsai-1","lookout"]' "$(dispatch '.sailors | keys_unsorted')" "the home must get exactly its shared bound slots, in registry order"
  assert_equals '{"title":"Bonsai 1","host":"Bonsai","endpoint":"http://127.0.0.1:11310/v1","status":"live","models":["bonsai-2bit"],"max_concurrent":2,"grade":"deckhand"}' \
    "$(dispatch '.sailors["bonsai-1"]')" "a bound slot must become a sailor on its server's baseURL plus /v1, with the home's share as its capacity"
  assert_equals '{"title":"Lookout","host":"Hugging Face","endpoint":"https://router.huggingface.co/v1","status":"placeholder","models":["org/model:cheapest"],"max_concurrent":1,"grade":"sailor","paid":true,"auth_env":"HF_TOKEN","unlisted_models":true}' \
    "$(dispatch '.sailors.lookout')" "a keyed, routed, paid placeholder must keep every field the registry gives it"
  assert_equals '["small clear work","mixed"]' "$(dispatch '[.rules[].when]')" "a rule left without a profile must go, as retire removes it"
  assert_equals '[{"harness":"claude","model":"claude-sonnet-5-5"}]' "$(dispatch '.rules[1].use')" "a shared rule must keep its other profiles"
  assert_equals "$(jq -c '[.default, .sailor_fallback]' "$CASE_DIR/original.json")" "$(dispatch '[.default, .sailor_fallback]')" "sync must leave the rest of the file alone"
  assert_contains "$out" "synced home firstmate from $REGISTRY: bonsai-1, lookout" "sync must name the sailors it gave the home"
  assert_contains "$out" "removed sailor tiller, which $REGISTRY no longer gives this home" "sync must report a sailor it removed"
  assert_contains "$out" 'removed rule "tiller only", which offered only tiller' "sync must report a rule it emptied"
  assert_contains "$out" "workers: the change applies from each worker's next spawn" "sync must say when workers switch"
  assert_equals 1 "$(backups | awk 'END { print NR }')" "sync must keep one dated copy of the file it replaced"
  run_sync validate >/dev/null || fail "the projected map must validate"
  [ ! -s "$CURL_LOG" ] || fail "sync must probe nothing, but curl was called: $(cat "$CURL_LOG")"
  cmp -s "$CASE_DIR/registry.orig" "$REGISTRY" || fail "sync must never write the slot registry"
  cmp -s "$CASE_DIR/servers.orig" "$CASE_DIR/servers.json" || fail "sync must never write the mlx-serve registry"

  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 0 "$?" "a second sync must succeed: $out"
  assert_contains "$out" "this home's sailors already match $REGISTRY; nothing written" "a second sync must change nothing"
  assert_equals 1 "$(backups | awk 'END { print NR }')" "a sync that changes nothing must not write"

  out=$(run_sync set bonsai-1 --host "this Mac")
  expect_code 0 "$?" "a hand edit must still work in a registry-managed home: $out"
  assert_contains "$out" "note: this home's sailors follow $REGISTRY (config/sailor-registry), so the next sync rewrites them from it" "a hand edit must warn that sync rewrites it"
  run_sync sync "$REGISTRY" --home firstmate >/dev/null
  assert_equals '"Bonsai"' "$(dispatch '.sailors["bonsai-1"].host')" "the next sync must rewrite the hand edit"
  pass "sync gives a home its share of each bound slot, drops the rest as retire does, probes nothing, and changes nothing when already in step"
}

test_sync_runs_only_where_the_home_hands_its_sailors_to_that_registry() {
  local out
  make_sync_case syncgate "$HAND_MAP"
  slot_registry
  rm "$CASE_DIR/config/sailor-registry"
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "a home without config/sailor-registry must be refused"
  assert_contains "$out" "refused: this home's sailors are managed by hand, since config/sailor-registry is absent" "hand-managed refusal missing"
  cp "$REGISTRY" "$CASE_DIR/other.json"
  printf '%s\n' "$CASE_DIR/other.json" > "$CASE_DIR/config/sailor-registry"
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "another registry must be refused"
  assert_contains "$out" "refused: this home follows the slot registry $CASE_DIR/other.json (config/sailor-registry), not $REGISTRY" "other-registry refusal missing"
  printf 'sailors.json\n' > "$CASE_DIR/config/sailor-registry"
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "a relative registry path must be refused"
  assert_contains "$out" "config/sailor-registry must name the slot registry by an absolute path or one starting ~/" "relative-path refusal missing"
  # shellcheck disable=SC2088 # the literal ~/ is what the file holds.
  printf '~/sailors.json\n' > "$CASE_DIR/config/sailor-registry"
  out=$(HOME="$CASE_DIR" run_sync sync "$REGISTRY" --home firstmate --dry-run)
  expect_code 0 "$?" "a registry path under ~/ must be read from HOME: $out"
  printf '%s\n' "$REGISTRY" > "$CASE_DIR/config/sailor-registry"
  out=$(run_sync sync "$REGISTRY" --home ghost)
  expect_code 1 "$?" "a home key the registry does not name must be refused"
  assert_contains "$out" "refused: the slot registry names no home ghost" "unknown-home refusal missing"
  slot_registry ".homes.firstmate = \"$TMP_ROOT\""
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "a home key naming another directory must be refused"
  assert_contains "$out" "refused: the slot registry's home firstmate is $TMP_ROOT, not this home ($CASE_DIR)" "wrong-home refusal missing"
  assert_unchanged "the gate refusals"
  run_sync sync "$REGISTRY" >/dev/null
  expect_code 2 "$?" "sync without --home is a usage error"

  rm "$CASE_DIR/config/sailor-registry"
  out=$(run_sync set bonsai-1 --host "this Mac")
  expect_code 0 "$?" "a hand edit must succeed in a hand-managed home: $out"
  assert_not_contains "$out" "config/sailor-registry" "a hand-managed home must not mention a registry"
  pass "sync runs only in a home whose config/sailor-registry names that registry and whose registry home key is this home"
}

test_sync_refuses_a_malformed_registry_naming_the_slot() {
  local out filter want
  make_sync_case syncbad "$HAND_MAP"
  while IFS='~' read -r filter want; do
    slot_registry "$filter"
    out=$(run_sync sync "$REGISTRY" --home firstmate)
    expect_code 1 "$?" "registry edit $filter must be refused: $out"
    assert_contains "$out" "refused: $want" "registry edit $filter must be refused with its reason"
  done <<EOF
.schema = 2~the slot registry must be an object with schema 1
.slots.stoker.server = "mlx-serve"~slot stoker needs a server or a harness with a model, or neither
.slots.stoker.harness = "codex"~slot stoker needs a server or a harness with a model, or neither
.slots.tiller.harness = "codex"~slot tiller names both a server and a harness; a slot is bound to one server or one login harness
.slots.stoker += {harness: "claude", model: "m"}~slot stoker harness claude is not one of codex, kimi, grok
.slots.stoker += {harness: "codex", model: "m", auth_env: "X"}~slot stoker is a login slot, which takes no auth_env, unlisted_models, or model_settings
.slots.stoker.login = "chatgpt"~slot stoker login names a sign-in label, which only a login slot carries
.slots.stoker += {harness: "codex", model: "m", login: 1}~slot stoker login must be a non-empty string without spaces or quotes
.slots.stoker += {harness: "codex", model: "m", login: "ChatGPT Plus"}~slot stoker login must be a non-empty string without spaces or quotes
.slots.stoker += {harness: "codex", model: "m", login: "x\nsailor=other"}~slot stoker login must be a non-empty string without spaces or quotes
.slots.stoker += {harness: "codex", model: "m", capacity: 0}~slot stoker capacity must be a positive whole number
.slots.lookout.server = "ghost"~slot lookout names server ghost, which $CASE_DIR/servers.json does not list
.slots["bonsai-1"].homes.firstmate = 3~slot bonsai-1 shares 4 tasks among its homes, above its capacity of 3
.slots["bonsai-1"].homes.firstmate = 1.5~slot bonsai-1 shares must be whole numbers
.slots.tiller.capacity = 0~slot tiller capacity must be a positive whole number
.slots.tiller.homes.dock = 0~slot tiller gives a share to home dock, which the registry homes do not name
.slots.lookout.grade = "scout"~slot lookout grade scout is not one of deckhand, sailor, specialist, expert
.slots.tiller.facets = "helm"~slot tiller facets must be a list of names
.slots.stoker.grade = "scout"~slot stoker grade scout is not one of deckhand, sailor, specialist, expert
.slots.stoker.facets = "helm"~slot stoker facets must be a list of names
.slots.lookout.model = "two words"~sailor lookout models must be non-empty strings without spaces or quotes
EOF
  slot_registry
  jq '.servers[0].baseURL = "ftp://127.0.0.1"' "$CASE_DIR/servers.json" > "$CASE_DIR/servers.tmp" && mv "$CASE_DIR/servers.tmp" "$CASE_DIR/servers.json"
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "a server with a non-http baseURL must be refused"
  assert_contains "$out" "refused: slot tiller is on server mlx-serve, whose baseURL ftp://127.0.0.1 is not an http(s) URL" "baseURL refusal missing"
  printf '{"schema": 1,' > "$REGISTRY"
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "a registry that does not parse must be refused"
  assert_contains "$out" "refused: the slot registry $REGISTRY is not valid JSON" "parse refusal missing"
  assert_unchanged "the registry refusals"
  [ ! -s "$CURL_LOG" ] || fail "a refused sync must probe nothing"
  pass "sync refuses a malformed registry as a whole, naming the slot, even one this home has no share of"
}

test_sync_refuses_to_strand_a_running_task_or_a_rule() {
  local out
  make_sync_case syncbusy "$HAND_MAP"
  slot_registry
  fm_write_meta "$CASE_DIR/state/busy-t1.meta" harness=opencode sailor=tiller model=qwen-coder
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "removing a sailor a task runs on must be refused"
  assert_contains "$out" "refused: task(s) busy-t1 run on tiller, which $REGISTRY no longer gives this home; sync once they land" "busy-removal refusal missing"
  rm "$CASE_DIR/state/busy-t1.meta"

  slot_registry '.slots["bonsai-1"].model = "bonsai-3bit"'
  fm_write_meta "$CASE_DIR/state/busy-b1.meta" harness=opencode sailor=bonsai-1 model=bonsai-2bit
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "rebinding a slot under a running task's model must be refused"
  assert_contains "$out" "refused: task(s) busy-b1 run bonsai-1/bonsai-2bit, which $REGISTRY no longer lists" "busy-model refusal missing"
  rm "$CASE_DIR/state/busy-b1.meta"
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "a rule naming the old model must be refused"
  assert_contains "$out" 'refused: rule "small clear work" names bonsai-1/bonsai-2bit, which the slot registry no longer gives this home; change it by hand first' "stale-rule refusal missing"
  jq '.rules |= map(select(.when != "small clear work")) | .default = [{harness: "opencode", sailor: "bonsai-1", model: "bonsai-2bit"}]' \
    "$CASE_DIR/original.json" > "$CASE_DIR/config/crew-dispatch.json"
  cp "$CASE_DIR/config/crew-dispatch.json" "$CASE_DIR/original.json"
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 1 "$?" "a default naming the old model must be refused"
  assert_contains "$out" "refused: the default names bonsai-1/bonsai-2bit, which the slot registry no longer gives this home" "stale-default refusal missing"
  assert_unchanged "the stranding refusals"

  slot_registry
  fm_write_meta "$CASE_DIR/state/busy-b1.meta" harness=opencode sailor=bonsai-1 model=bonsai-2bit
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 0 "$?" "a task on a sailor and model the registry keeps must not block sync: $out"
  pass "sync refuses to remove a sailor or model a task runs on, and to leave a rule or default on a model the slot no longer serves"
}

# make_privateer_sync_case <name>: a Privateer home on the main home's two
# local sailors, whose first mate runs on tiller, keyed privateer in REGISTRY.
make_privateer_sync_case() {
  make_sync_case "$1" "$(jq -c '.rules = [{when: "Any Privateer worker task", use: [{harness: "opencode", sailor: "bonsai-1", model: "bonsai-2bit"}]}]
    | .default = .rules[0].use | del(.sailor_fallback)' <<<"$HAND_MAP")"
  printf '# first mate\ntiller/qwen-coder\n' > "$CASE_DIR/config/privateer"
  printf 'opencode\n' > "$CASE_DIR/config/crew-harness"
  : > "$CASE_DIR/config/sailor-sandbox"
  FM_HOME="$CASE_DIR" "$ROOT/bin/fm-privateer.sh" check >/dev/null 2>&1 ||
    fail "the Privateer fixture must pass the quarantine: $(FM_HOME="$CASE_DIR" "$ROOT/bin/fm-privateer.sh" check 2>&1)"
}

PRIVATEER_KEY='.homes.privateer = .homes.firstmate | .homes.firstmate = "/nonexistent/firstmate"'

test_sync_in_a_privateer_home_moves_the_first_mate_and_keeps_the_quarantine() {
  local out filter want
  make_privateer_sync_case syncpv
  slot_registry "$PRIVATEER_KEY"
  out=$(run_sync sync "$REGISTRY" --home privateer)
  expect_code 0 "$?" "a sync into a Privateer home must succeed: $out"
  assert_equals '["tiller","bonsai-1","lookout"]' "$(dispatch '.sailors | keys_unsorted')" "the Privateer home must get every slot shared with it"
  assert_equals '[1,1,1]' "$(dispatch '[.sailors[].max_concurrent]')" "each sailor must carry this home's share"
  assert_equals '# first mate
tiller/qwen-coder' "$(cat "$CASE_DIR/config/privateer")" "an unchanged first mate must leave config/privateer alone"
  assert_contains "$out" "egress: a running Privateer session allows a new endpoint only after fm-privateer.sh reload" "a new endpoint must ask for a reload"
  FM_HOME="$CASE_DIR" "$ROOT/bin/fm-privateer.sh" check >/dev/null 2>&1 || fail "the home must pass the quarantine after sync"

  slot_registry "$PRIVATEER_KEY"' | .slots.tiller.model = "qwen-next" | .slots.tiller.model_settings = {"qwen-next": {limit: {context: 65536, output: 8192}}}'
  out=$(run_sync sync "$REGISTRY" --home privateer)
  expect_code 0 "$?" "rebinding the first mate's slot must succeed: $out"
  assert_equals '# first mate
tiller/qwen-next' "$(cat "$CASE_DIR/config/privateer")" "the first mate line must follow its slot, keeping the comment"
  assert_contains "$out" "wrote config/privateer" "sync must say it wrote config/privateer"
  assert_contains "$out" "first mate: restart the Privateer session to switch" "a first-mate rebind must ask for a restart"
  assert_not_contains "$out" "egress:" "a rebind on the same endpoint must not ask for a reload"
  FM_HOME="$CASE_DIR" "$ROOT/bin/fm-privateer.sh" check >/dev/null 2>&1 || fail "the home must pass the quarantine after the rebind"

  cp "$CASE_DIR/config/crew-dispatch.json" "$CASE_DIR/original.json"
  cp "$CASE_DIR/config/privateer" "$CASE_DIR/privateer.orig"
  rm -f "$CASE_DIR/config/"*.bak-*
  while IFS='~' read -r filter want; do
    slot_registry "$PRIVATEER_KEY | .slots.tiller.model = \"qwen-next\" | .slots.tiller.model_settings = {} | $filter"
    out=$(run_sync sync "$REGISTRY" --home privateer)
    expect_code 1 "$?" "registry edit $filter must be refused in a Privateer home: $out"
    assert_contains "$out" "refused: $want" "registry edit $filter must be refused with its reason"
  done <<'EOF'
.privateer_first_mate = "bonsai-1"~slot bonsai-1 lacks the helm facet the first mate needs
.privateer_first_mate = "stoker"~slot stoker is blank, and the first mate runs only on a bound slot
.privateer_first_mate = "ghost"~privateer_first_mate names ghost, which is not a slot
.slots.tiller.homes = {}~slot tiller gives home privateer no share, so the first mate cannot run on it
.slots.tiller.status = "placeholder"~slot tiller is a placeholder, and the first mate runs only on a live sailor
del(.privateer_first_mate) | .slots.tiller.status = "placeholder"~the first mate runs on tiller/qwen-next, and the first mate runs only on a live sailor
.slots.lookout.auth_env = "ANTHROPIC_API_KEY"~the change would break this home's Privateer quarantine:
EOF
  slot_registry "$PRIVATEER_KEY"' | .slots.tiller.model = "qwen-next" | .slots.tiller.model_settings = {}'
  jq '.servers[2].baseURL = "https://api.anthropic.com"' "$CASE_DIR/servers.json" > "$CASE_DIR/servers.tmp" && mv "$CASE_DIR/servers.tmp" "$CASE_DIR/servers.json"
  out=$(run_sync sync "$REGISTRY" --home privateer)
  expect_code 1 "$?" "a slot on an Anthropic host must be refused in a Privateer home"
  assert_contains "$out" "sailor lookout has endpoint 'https://api.anthropic.com/v1', on an Anthropic or Claude host" "the refusal must carry the quarantine's own reason"
  assert_unchanged "the Privateer refusals"
  cmp -s "$CASE_DIR/privateer.orig" "$CASE_DIR/config/privateer" || fail "a refused sync must leave config/privateer alone"
  pass "in a Privateer home sync moves the first mate with its helm slot, refuses a first mate it cannot run, and keeps the quarantine"
}

# Login sailors: worker apps on their own subscription logins. The fake codex,
# kimi, and grok below log every call to $HOME/login.log, because the sign-in
# check runs them under env -i, so a toggle or log named by the test's own
# environment would never reach them; each reads its down and sleep toggles
# from files under that HOME for the same reason.
LOGIN_MAP='{"sailors":{
  "teach":{"title":"Teach","harness":"codex","login":"chatgpt","status":"live","models":["gpt-6-sol"],"grade":"specialist"},
  "bonny":{"harness":"kimi","status":"live","models":["kimi-for-coding"],"grade":"sailor"},
  "mary":{"harness":"grok","login":"grok.com","status":"live","models":["grok-4.7"],"grade":"sailor","max_concurrent":2},
  "tiller":{"endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["qwen-coder"],"grade":"deckhand"}},
 "rules":[{"when":"planning","use":[{"harness":"codex","sailor":"teach","model":"gpt-6-sol"},{"harness":"opencode","sailor":"tiller","model":"qwen-coder"}]}],
 "default":{"harness":"opencode","grade":"sailor"},
 "sailor_fallback":{"harness":"claude","model":"claude-opus-5-5"}}'

# make_login_case <name> <map-json>: make_case plus LOGIN_HOME, a HOME holding
# a grok auth.json and a kimi credentials file, and the three fake worker apps
# in FAKEBIN. LOGIN_LOG is their call log.
make_login_case() {
  local app
  make_case "$1" "$2"
  LOGIN_HOME="$CASE_DIR/home"
  mkdir -p "$LOGIN_HOME/.grok" "$LOGIN_HOME/.kimi-code/credentials"
  : > "$LOGIN_HOME/.grok/auth.json"
  : > "$LOGIN_HOME/.kimi-code/credentials/kimi-code-env-0123abcd.json"
  LOGIN_LOG="$LOGIN_HOME/login.log"
  : > "$LOGIN_LOG"
  for app in codex kimi grok; do
    cat > "$FAKEBIN/$app" <<SH
#!/usr/bin/env bash
printf '%s %s key=%s grok_home=%s cwd=%s\\n' "$app" "\$*" "\${OPENAI_API_KEY:-unset}" "\${GROK_HOME:-unset}" "\$PWD" >> "\$HOME/login.log"
[ ! -e "\$HOME/$app.sleep" ] || sleep 5
[ ! -e "\$HOME/$app.down" ] || exit 1
exit 0
SH
    chmod +x "$FAKEBIN/$app"
  done
}

# run_login <args...>: run_sailor from LOGIN_HOME with an API key in the
# environment that a sign-in check must not pass on.
run_login() {
  HOME="$LOGIN_HOME" OPENAI_API_KEY=leaked-key run_sailor "$@"
}

test_validate_and_list_know_login_sailors() {
  local out map want
  make_login_case login-valid "$LOGIN_MAP"
  out=$(run_login validate)
  expect_code 0 "$?" "a map with login sailors must validate: $out"
  out=$(run_login list)
  assert_contains "$out" "teach status=live harness=codex max_concurrent=1 grade=specialist models=gpt-6-sol login=chatgpt" "list must show a login sailor's harness and label"
  assert_contains "$out" "bonny status=live harness=kimi max_concurrent=1 grade=sailor models=kimi-for-coding" "list must omit the label of a login sailor without one"
  assert_contains "$out" "tiller status=live endpoint=http://127.0.0.1:11234/v1 max_concurrent=1 grade=deckhand models=qwen-coder" "list must keep an endpoint sailor's endpoint"
  while IFS='~' read -r map want; do
    make_login_case "login-bad-$RANDOM" "$map"
    out=$(run_login validate)
    expect_code 1 "$?" "map $map must be invalid: $out"
    assert_equals "$want" "$out" "diagnostic mismatch for $map"
  done <<'EOF'
{"sailors":{"x":{"harness":"codex","endpoint":"http://127.0.0.1:1/v1","status":"live","models":["m"]}}}~sailor x needs an http(s) endpoint or a login harness, not both
{"sailors":{"x":{"status":"live","models":["m"]}}}~sailor x needs an http(s) endpoint or a login harness, not both
{"sailors":{"x":{"harness":"claude","status":"live","models":["m"]}}}~sailor x harness must be one of codex, kimi, grok
{"sailors":{"x":{"harness":"opencode","status":"live","models":["m"]}}}~sailor x harness must be one of codex, kimi, grok
{"sailors":{"x":{"harness":"codex","auth_env":"OPENAI_API_KEY","status":"live","models":["m"]}}}~sailor x is a login sailor, which takes no auth_env, unlisted_models, model_settings, or host
{"sailors":{"x":{"harness":"kimi","host":"this Mac","status":"live","models":["m"]}}}~sailor x is a login sailor, which takes no auth_env, unlisted_models, model_settings, or host
{"sailors":{"x":{"endpoint":"http://127.0.0.1:1/v1","login":"chatgpt","status":"live","models":["m"]}}}~sailor x login names a sign-in label, which only a login sailor carries
{"sailors":{"x":{"harness":"codex","login":1,"status":"live","models":["m"]}}}~sailor x login must be a non-empty string without spaces or quotes
{"sailors":{"x":{"harness":"codex","login":"","status":"live","models":["m"]}}}~sailor x login must be a non-empty string without spaces or quotes
{"sailors":{"x":{"harness":"codex","login":"ChatGPT Plus","status":"live","models":["m"]}}}~sailor x login must be a non-empty string without spaces or quotes
{"sailors":{"x":{"harness":"codex","login":"x\nsailor=other","status":"live","models":["m"]}}}~sailor x login must be a non-empty string without spaces or quotes
{"sailors":{"x":{"harness":"codex","status":"live","models":["m"]}},"default":{"harness":"opencode","sailor":"x","model":"m"}}~sailor x profile must use harness codex
{"sailors":{"x":{"harness":"grok","status":"live","models":["m"]}},"default":{"harness":"kimi","sailor":"x","model":"m"}}~sailor x profile must use harness grok
{"sailors":{"x":{"endpoint":"http://127.0.0.1:1/v1","status":"live","models":["m"]}},"default":{"harness":"codex","sailor":"x","model":"m"}}~sailor x profile must use harness opencode
EOF
  pass "validate takes a login sailor on codex, kimi, or grok with its own profile harness and refuses a mixed, mislabelled, or mis-profiled one; list shows its harness and label"
}

test_check_runs_a_login_sailors_sign_in_check_and_nothing_else() {
  local out
  make_login_case login-check "$LOGIN_MAP"
  out=$(run_login check teach gpt-6-sol)
  expect_code 0 "$?" "a signed-in codex sailor must pass check: $out"
  assert_equals "ok: sailor teach runs gpt-6-sol on its codex login (0 of 1 tasks busy; signed in)" "$out" "the codex ok line must name the login"
  assert_equals "codex login status key=unset grok_home=unset cwd=$PWD" "$(cat "$LOGIN_LOG")" "codex must see login status alone, under an environment without the ambient API key"
  [ ! -s "$CURL_LOG" ] || fail "a login sailor must never be probed over HTTP, but curl was called: $(cat "$CURL_LOG")"

  : > "$LOGIN_LOG"
  out=$(run_login check bonny kimi-for-coding)
  expect_code 0 "$?" "a signed-in kimi sailor must pass check: $out"
  assert_equals "ok: sailor bonny runs kimi-for-coding on its kimi login (0 of 1 tasks busy; signed in)" "$out" "the kimi ok line must name the login"
  assert_contains "$(cat "$LOGIN_LOG")" "kimi -p Reply with the single word OK. --output-format text key=unset" "check must send kimi the one test prompt"
  assert_not_contains "$(cat "$LOGIN_LOG")" "cwd=$PWD" "the kimi test prompt must run from a scratch directory, not the caller's"
  assert_equals 1 "$(wc -l < "$LOGIN_LOG" | tr -d ' ')" "check must send kimi exactly one prompt"
  [ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'fm-sailor-smoke.*' 2>/dev/null)" ] || fail "the scratch directory of the kimi test prompt must be removed"

  : > "$LOGIN_LOG"
  out=$(GROK_HOME="$LOGIN_HOME/elsewhere" run_login check mary grok-4.7)
  expect_code 1 "$?" "grok without its auth.json must be refused: $out"
  assert_equals "refused: sailor mary is signed out of grok: no $LOGIN_HOME/elsewhere/auth.json, so grok holds no login" "$out" "the grok refusal must name the missing file under GROK_HOME"
  [ ! -s "$LOGIN_LOG" ] || fail "grok must not run without its auth.json: $(cat "$LOGIN_LOG")"
  mkdir -p "$LOGIN_HOME/elsewhere" && : > "$LOGIN_HOME/elsewhere/auth.json"
  out=$(GROK_HOME="$LOGIN_HOME/elsewhere" run_login check mary grok-4.7)
  expect_code 0 "$?" "a signed-in grok sailor must pass check: $out"
  assert_equals "ok: sailor mary runs grok-4.7 on its grok login (0 of 2 tasks busy; signed in)" "$out" "the grok ok line must name the login"
  assert_equals "grok models key=unset grok_home=$LOGIN_HOME/elsewhere cwd=$PWD" "$(cat "$LOGIN_LOG")" "grok must list models under GROK_HOME alone"

  : > "$LOGIN_HOME/codex.down"
  out=$(run_login check teach gpt-6-sol)
  expect_code 1 "$?" "a signed-out codex sailor must be refused: $out"
  assert_equals "refused: sailor teach is signed out of codex: codex login status reports no login (exit 1)" "$out" "the codex refusal must carry the exit status"
  rm "$LOGIN_HOME/codex.down"
  : > "$LOGIN_HOME/kimi.down"
  out=$(run_login check bonny kimi-for-coding)
  expect_code 1 "$?" "a kimi sailor refusing the test prompt must be refused: $out"
  assert_equals "refused: sailor bonny is signed out of kimi: kimi refused a test prompt (exit 1), so its login is not usable" "$out" "the kimi refusal must name the test prompt"
  rm "$LOGIN_HOME/kimi.down" "$LOGIN_HOME/.kimi-code/credentials/kimi-code-env-0123abcd.json"
  : > "$LOGIN_LOG"
  out=$(run_login check bonny kimi-for-coding)
  expect_code 1 "$?" "kimi without a credentials file must be refused: $out"
  assert_equals "refused: sailor bonny is signed out of kimi: no credentials file under $LOGIN_HOME/.kimi-code/credentials, so kimi holds no login" "$out" "the kimi refusal must name the credentials directory"
  [ ! -s "$LOGIN_LOG" ] || fail "kimi must not run without a credentials file: $(cat "$LOGIN_LOG")"
  : > "$LOGIN_HOME/.grok/auth.json"
  : > "$LOGIN_HOME/grok.down"
  out=$(run_login check mary grok-4.7)
  expect_code 1 "$?" "grok failing to list models must be refused: $out"
  assert_equals "refused: sailor mary is signed out of grok: grok models failed (exit 1), so its login is not usable" "$out" "the grok refusal must carry the exit status"
  rm "$LOGIN_HOME/grok.down"

  : > "$LOGIN_HOME/codex.sleep"
  out=$(FM_SAILOR_LOGIN_TIMEOUT=1 run_login check teach gpt-6-sol)
  expect_code 1 "$?" "a sign-in check past its bound must be refused: $out"
  assert_equals "refused: sailor teach is signed out of codex: codex login status did not answer within 1 seconds" "$out" "the timeout refusal must name the bound"
  rm "$LOGIN_HOME/codex.sleep"
  out=$(FM_SAILOR_LOGIN_TIMEOUT=x run_login check teach gpt-6-sol)
  expect_code 2 "$?" "a malformed bound is a usage error"
  rm "$FAKEBIN/codex"
  out=$(PATH="$FAKEBIN:$(dirname "$(command -v jq)"):/usr/bin:/bin" run_login check teach gpt-6-sol)
  expect_code 1 "$?" "an absent worker app must be refused: $out"
  assert_equals "refused: sailor teach is signed out of codex: codex is not installed" "$out" "the absent-app refusal must name the app"

  : > "$LOGIN_LOG"
  fm_write_meta "$CASE_DIR/state/busy-m1.meta" harness=grok sailor=mary model=grok-4.7
  fm_write_meta "$CASE_DIR/state/busy-m2.meta" harness=grok sailor=mary model=grok-4.7
  out=$(run_login check mary grok-4.7)
  expect_code 1 "$?" "a login sailor at capacity must be refused: $out"
  assert_equals "refused: sailor mary is at capacity (2 of 2 tasks)" "$out" "capacity must count a login sailor's tasks"
  out=$(run_login check mary grok-4.7 --task busy-m2)
  expect_code 0 "$?" "the task being relaunched must not count: $out"
  assert_contains "$out" "(1 of 2 tasks busy; signed in)" "the ok line must count the other task"
  rm "$CASE_DIR/state/busy-m1.meta" "$CASE_DIR/state/busy-m2.meta"
  out=$(run_login check mary nope)
  expect_code 1 "$?" "a model the login sailor does not list must be refused"
  assert_equals "refused: model nope is not listed for sailor mary" "$out" "unlisted-model refusal mismatch"
  assert_equals "grok models key=unset grok_home=$LOGIN_HOME/.grok cwd=$PWD" "$(cat "$LOGIN_LOG")" "a capacity or model refusal must run no sign-in check, and grok sees its default home"
  [ ! -s "$CURL_LOG" ] || fail "no login check may touch curl: $(cat "$CURL_LOG")"
  pass "check signs a login sailor in through its own worker app under a clean environment, sends kimi one test prompt from a scratch directory, and refuses a signed-out, absent, slow, busy, or mis-modelled one by name"
}

test_pick_takes_a_login_sailor_by_grade_through_its_sign_in_check() {
  local out
  make_login_case login-pick "$LOGIN_MAP"
  out=$(run_login pick --grade specialist)
  expect_code 0 "$?" "pick by grade must take a signed-in login sailor: $out"
  assert_equals "teach gpt-6-sol" "$out" "pick must print the login sailor and its model"
  out=$(run_login pick --grade sailor)
  assert_equals "bonny kimi-for-coding" "$out" "the lowest sufficient login sailor must come first"
  : > "$LOGIN_HOME/kimi.down"
  out=$(run_login pick --grade sailor)
  assert_equals "mary grok-4.7" "$out" "a signed-out login sailor must be passed over"
  : > "$LOGIN_HOME/grok.down"
  : > "$LOGIN_HOME/codex.down"
  out=$(run_login pick --grade sailor)
  expect_code 1 "$?" "pick must refuse when every candidate is signed out"
  assert_contains "$out" "bonny/kimi-for-coding: sailor bonny is signed out of kimi: kimi refused a test prompt (exit 1), so its login is not usable" "the refusal must carry each sign-in reason"
  assert_contains "$out" "mary/grok-4.7: sailor mary is signed out of grok: grok models failed (exit 1), so its login is not usable" "the refusal must carry the grok reason"
  assert_contains "$out" "teach/gpt-6-sol: sailor teach is signed out of codex: codex login status reports no login (exit 1)" "the refusal must carry the codex reason"
  out=$(run_login pick --sailor teach)
  expect_code 1 "$?" "a named signed-out login sailor must be refused"
  assert_equals "refused: sailor teach is signed out of codex: codex login status reports no login (exit 1)" "$out" "the named refusal must be the sign-in reason"
  [ ! -s "$CURL_LOG" ] || fail "no pick over login sailors may touch curl: $(cat "$CURL_LOG")"
  pass "pick weighs a login sailor by grade through its sign-in check and passes a signed-out one over, naming the reason"
}

test_health_and_status_read_a_login_sailor_without_a_prompt() {
  local out start
  make_login_case login-health "$LOGIN_MAP"
  out=$(run_login health)
  expect_code 0 "$?" "health must succeed: $out"
  assert_contains "$out" "teach up login:codex" "health must read a signed-in codex sailor as up"
  assert_contains "$out" "bonny up login:kimi" "health must read a kimi sailor with a credentials file as up"
  assert_contains "$out" "mary up login:grok" "health must read a signed-in grok sailor as up"
  assert_contains "$out" "tiller up http://127.0.0.1:11234/v1/models" "health must keep probing an endpoint sailor"
  assert_not_contains "$(cat "$LOGIN_LOG")" "kimi" "health must never send kimi a prompt"
  assert_equals "http://127.0.0.1:11234/v1/models" "$(cat "$CURL_LOG")" "health must probe only the endpoint sailor over HTTP"

  out=$(run_login status)
  expect_code 0 "$?" "status must succeed: $out"
  assert_contains "$out" "teach live answering harness=codex tasks=0/1 grade=specialist models=gpt-6-sol(signed-in) login=chatgpt" "status must show a signed-in login sailor"
  assert_contains "$out" "bonny live answering harness=kimi tasks=0/1 grade=sailor models=kimi-for-coding(signed-in)" "status must omit the label of a login sailor without one"
  assert_not_contains "$(cat "$LOGIN_LOG")" "kimi" "status must never send kimi a prompt"
  assert_not_contains "$(cat "$LOGIN_LOG")" "grok models" "health and status must never run grok, which reaches its vendor"

  : > "$LOGIN_HOME/codex.sleep"
  : > "$LOGIN_HOME/grok.sleep"
  start=$SECONDS
  out=$(FM_SAILOR_PROBE_TIMEOUT=1 FM_SAILOR_LOGIN_TIMEOUT=30 run_login health)
  [ $((SECONDS - start)) -lt 4 ] || fail "health must bound a slow sign-in check by the probe timeout, not the login timeout: took $((SECONDS - start))s"
  assert_contains "$out" "teach down login:codex" "health must read a codex that does not answer within the probe timeout as down"
  assert_contains "$out" "mary up login:grok" "health must read grok by its auth.json alone"
  start=$SECONDS
  out=$(FM_SAILOR_PROBE_TIMEOUT=1 FM_SAILOR_LOGIN_TIMEOUT=30 run_login status)
  [ $((SECONDS - start)) -lt 4 ] || fail "status must bound a slow sign-in check by the probe timeout, not the login timeout: took $((SECONDS - start))s"
  assert_contains "$out" "teach live not-answering harness=codex" "status must read a codex that does not answer within the probe timeout as not answering"
  rm "$LOGIN_HOME/codex.sleep" "$LOGIN_HOME/grok.sleep"

  : > "$LOGIN_HOME/codex.down"
  rm "$LOGIN_HOME/.kimi-code/credentials/kimi-code-env-0123abcd.json"
  fm_write_meta "$CASE_DIR/state/busy-t1.meta" harness=codex sailor=teach model=gpt-6-sol
  out=$(run_login health)
  assert_contains "$out" "teach down login:codex" "health must read a signed-out codex sailor as down"
  assert_contains "$out" "bonny down login:kimi" "health must read kimi without a credentials file as down"
  out=$(run_login status)
  assert_contains "$out" "teach live not-answering harness=codex tasks=1/1 grade=specialist models=gpt-6-sol(signed-out) login=chatgpt" "status must show a signed-out login sailor and its tasks"
  assert_contains "$out" "bonny live not-answering harness=kimi tasks=0/1 grade=sailor models=kimi-for-coding(signed-out)" "status must show kimi as signed out without its file"
  assert_not_contains "$out" "leaked-key" "status must never print a value from the environment"
  pass "health and status read a login sailor by its local sign-in evidence within the probe timeout, up or answering when signed in, and never run grok or send kimi a prompt"
}

test_login_sailors_take_no_provider_or_warm_up_and_add_registers_one() {
  local out
  make_login_case login-edit "$LOGIN_MAP"
  out=$(run_login provider-json teach gpt-6-sol)
  expect_code 1 "$?" "provider-json on a login sailor must be refused: $out"
  assert_equals "refused: sailor teach is a login sailor on codex, which runs as its own worker app and takes no OpenCode provider" "$out" "provider-json refusal mismatch"
  cp "$CASE_DIR/config/crew-dispatch.json" "$CASE_DIR/original.json"
  rm -f "$CASE_DIR/config/"*.bak-*
  out=$(run_login set-model teach gpt-6-pro --warm)
  expect_code 1 "$?" "warming a login sailor must be refused: $out"
  assert_equals "refused: sailor teach is a login sailor on codex, and a login sailor is never warmed" "$out" "warm refusal mismatch"
  out=$(run_login set-model teach gpt-6-pro --first-mate)
  expect_code 1 "$?" "a login sailor as first mate must be refused: $out"
  assert_equals "refused: sailor teach is a login sailor on codex, and the first mate runs only on an endpoint sailor" "$out" "first-mate refusal mismatch"
  out=$(run_login add x --harness claude --models m)
  expect_code 1 "$?" "add on an unknown harness must be refused: $out"
  assert_contains "$out" "refused: sailor x harness must be one of codex, kimi, grok" "add must carry validate's harness reason"
  out=$(run_login add x --harness codex --endpoint http://127.0.0.1:1/v1 --models m)
  expect_code 2 "$?" "add with both a harness and an endpoint is a usage error"
  out=$(run_login add x --login work --endpoint http://127.0.0.1:1/v1 --models m)
  expect_code 2 "$?" "add with a login label and no harness is a usage error"
  out=$(run_login add x --harness codex)
  expect_code 2 "$?" "add with a harness and no models is a usage error"
  assert_unchanged "the login refusals"
  [ ! -s "$LOGIN_LOG" ] || fail "no edit may run a sign-in check: $(cat "$LOGIN_LOG")"

  out=$(run_login set-model teach gpt-6-pro --replace gpt-6-sol)
  expect_code 0 "$?" "set-model on a login sailor must succeed without a probe: $out"
  assert_contains "$out" "note: teach is a login sailor on codex, so gpt-6-pro was not probed" "set-model must say it probed nothing"
  assert_equals '["gpt-6-pro"]' "$(dispatch '.sailors.teach.models')" "set-model must swap the model"
  assert_equals '[{"harness":"codex","sailor":"teach","model":"gpt-6-pro"},{"harness":"opencode","sailor":"tiller","model":"qwen-coder"}]' "$(dispatch '.rules[0].use')" "set-model --replace must move the login sailor's profile"
  out=$(run_login add anne --harness kimi --models kimi-k3 --login work --title Anne --max-concurrent 2)
  expect_code 0 "$?" "adding a login sailor must succeed: $out"
  assert_contains "$out" "added sailor anne (placeholder) on its kimi login serving kimi-k3" "add must report the login"
  assert_equals '{"title":"Anne","harness":"kimi","login":"work","status":"placeholder","models":["kimi-k3"],"max_concurrent":2}' "$(dispatch '.sailors.anne')" "add must register exactly the given fields"
  out=$(run_login set anne --live)
  expect_code 0 "$?" "set must find a login sailor: $out"
  out=$(run_login retire anne)
  expect_code 0 "$?" "retire must find a login sailor: $out"
  assert_equals 'false' "$(dispatch '.sailors | has("anne")')" "retire must remove the login sailor"
  [ ! -s "$LOGIN_LOG" ] || fail "no edit may run a sign-in check: $(cat "$LOGIN_LOG")"
  [ ! -s "$CURL_LOG" ] || fail "no edit of a login sailor may probe: $(cat "$CURL_LOG")"
  pass "a login sailor takes no OpenCode provider, warm-up, or first mate line; add, set, set-model, and retire edit one without a probe"
}

test_sync_projects_a_login_slot_and_keeps_it_off_the_first_mate() {
  local out
  make_sync_case synclogin "$HAND_MAP"
  slot_registry '.slots.teach = {title: "Teach", harness: "codex", login: "chatgpt", model: "gpt-6-sol", grade: "specialist", facets: ["plan"], capacity: 1, homes: {firstmate: 1}, status: "live"}
    | .slots.bonny = {harness: "kimi", model: "kimi-for-coding", grade: "sailor", capacity: 1, homes: {privateer: 1}, status: "live"}
    | .slots.mary = {harness: "grok", login: "grok.com", model: "grok-4.7", grade: "sailor", paid: false, capacity: 1, homes: {firstmate: 1}, status: "placeholder"}'
  out=$(run_sync sync "$REGISTRY" --home firstmate)
  expect_code 0 "$?" "a sync with login slots must succeed: $out"
  assert_equals '["bonsai-1","lookout","teach","mary"]' "$(dispatch '.sailors | keys_unsorted')" "the home must get its login slots in registry order and not another home's"
  assert_equals '{"title":"Teach","harness":"codex","login":"chatgpt","status":"live","models":["gpt-6-sol"],"max_concurrent":1,"grade":"specialist","facets":["plan"]}' \
    "$(dispatch '.sailors.teach')" "a login slot must become a login sailor with its harness, label, share, grade, and facets"
  assert_equals '{"harness":"grok","login":"grok.com","status":"placeholder","models":["grok-4.7"],"max_concurrent":1,"grade":"sailor","paid":false}' \
    "$(dispatch '.sailors.mary')" "a login placeholder must keep its status and paid flag"
  assert_contains "$out" "synced home firstmate from $REGISTRY: bonsai-1, lookout, teach, mary" "sync must name the login sailors it gave the home"
  run_sync validate >/dev/null || fail "the projected map must validate"
  [ ! -s "$CURL_LOG" ] || fail "sync must probe nothing, but curl was called: $(cat "$CURL_LOG")"

  make_privateer_sync_case synclogin-pv
  slot_registry "$PRIVATEER_KEY"' | .slots.teach = {harness: "codex", model: "gpt-6-sol", facets: ["helm"], capacity: 1, homes: {privateer: 1}, status: "live"} | .privateer_first_mate = "teach"'
  cp "$CASE_DIR/config/privateer" "$CASE_DIR/privateer.orig"
  out=$(run_sync sync "$REGISTRY" --home privateer)
  expect_code 1 "$?" "a login slot as the Privateer first mate must be refused: $out"
  assert_contains "$out" "refused: slot teach is a login slot, and the first mate runs only on an endpoint sailor" "the first-mate refusal must name the login slot"
  assert_unchanged "the login first-mate refusal"
  cmp -s "$CASE_DIR/privateer.orig" "$CASE_DIR/config/privateer" || fail "a refused sync must leave config/privateer alone"
  pass "sync projects a login slot into a login sailor with the home's share and refuses one as the Privateer first mate"
}

test_live_sailor_serving_the_model_passes_check
test_endpoint_trailing_slash_is_not_doubled
test_placeholder_is_refused_without_a_probe
test_silent_endpoint_is_refused
test_endpoint_without_the_model_is_refused
test_unlisted_model_and_unknown_sailor_are_refused
test_capacity_counts_live_task_records
test_provider_json_is_the_opencode_provider_entry
test_model_settings_travel_with_the_model
test_validate_is_silent_without_sailors_and_names_the_first_problem
test_validate_checks_grades_facets_paid_and_spend
test_pick_by_grade_takes_the_lowest_sufficient_free_sailor
test_pick_weighs_one_named_sailor_through_the_same_gates
test_check_says_loaded_or_listed
test_check_bounds_an_unloaded_models_probe_by_the_warm_timeout
test_check_sends_opencodes_message_shape
test_check_refuses_an_endpoint_that_rejects_the_shape
test_status_shows_answer_tasks_queue_and_models
test_set_model_replace_moves_every_profile_of_that_sailor
test_set_model_refusals_write_nothing
test_set_model_carries_settings_and_replace_swaps_them
test_set_model_says_when_the_model_is_only_listed
test_privateer_home_moves_the_first_mate_and_guards_the_quarantine
test_privateer_first_mate_sailor_stays_live_and_restarts_only_when_it_changes
test_retire_refuses_busy_sailors_and_removes_emptied_rules
test_add_and_set_edit_one_sailor
test_add_from_mlx_serve_reads_the_registry_and_nothing_more
test_health_probes_the_mlx_serve_health_path
test_status_and_list_show_the_grade_of_a_graded_sailor_only
test_status_answering_agrees_with_the_health_probe
test_health_probes_every_sailor_at_once_within_the_bound
test_status_probes_every_sailor_at_once_within_the_bound
test_token_rides_every_request_and_is_never_printed
test_missing_token_refuses_naming_only_the_variable
test_with_token_hands_the_value_to_the_command_alone
test_unlisted_models_lets_a_router_serve_ids_it_does_not_list
test_registry_records_auth_env_and_unlisted_models
test_sync_projects_this_homes_share_of_each_bound_slot
test_sync_runs_only_where_the_home_hands_its_sailors_to_that_registry
test_sync_refuses_a_malformed_registry_naming_the_slot
test_sync_refuses_to_strand_a_running_task_or_a_rule
test_sync_in_a_privateer_home_moves_the_first_mate_and_keeps_the_quarantine
test_validate_and_list_know_login_sailors
test_check_runs_a_login_sailors_sign_in_check_and_nothing_else
test_pick_takes_a_login_sailor_by_grade_through_its_sign_in_check
test_health_and_status_read_a_login_sailor_without_a_prompt
test_login_sailors_take_no_provider_or_warm_up_and_add_registers_one
test_sync_projects_a_login_slot_and_keeps_it_off_the_first_mate

echo "# all fm-sailor tests passed"
