#!/usr/bin/env bash
# Opt-in live guard for login sailors (bin/fm-sailor.sh, docs/configuration.md
# "Named sailors") against every installed worker app they run on: codex,
# kimi, and grok.
#
# A login sailor's verdict comes from vendor behavior - the exit status of
# `codex login status`, the presence of grok's auth.json and the exit status of
# `grok models`, and the presence of kimi's credentials file plus the exit
# status of one `kimi -p` test prompt - so a fake can only restate the
# assumption written into it. This guard runs the REAL installed apps on the
# operator's own logins through a scratch home: it registers the three sailors
# by hand, projects them from a scratch slot registry with sync, and reads
# health, status, check, and pick, which is exactly what firstmate's spawn gate
# asks before a launch. It spawns nothing and edits no real registry, config,
# or account: the one request it sends is the kimi test prompt that `check`
# owns, so it stays opt-in.
#
# Run it after every codex, kimi, or grok upgrade and before trusting the
# "Login sailors" entry in docs/verification/runtime-backends.md and
# docs/verification/login-sailors.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_LOGIN_SAILORS_E2E jq

SAILOR="$ROOT/bin/fm-sailor.sh"
TMP_ROOT=$(fm_test_tmproot fm-login-sailors-live)
CASE_DIR="$TMP_ROOT/home"
REGISTRY="$TMP_ROOT/sailors.json"
mkdir -p "$CASE_DIR/config" "$CASE_DIR/state"
printf '%s\n' '{"default": {"harness": "claude"}}' > "$CASE_DIR/config/crew-dispatch.json"
unset OPENAI_API_KEY XAI_API_KEY MOONSHOT_API_KEY KIMI_API_KEY
CHECKED=
ABSENT=

run_sailor() {
  FM_HOME="$CASE_DIR" FM_CONFIG_OVERRIDE="$CASE_DIR/config" FM_STATE_OVERRIDE="$CASE_DIR/state" \
    FM_MLX_SERVE_SERVERS="$TMP_ROOT/servers.json" "$SAILOR" "$@" 2>&1
}

app_version() {  # <app>
  "$1" --version 2>/dev/null | head -1
}

# sailor_cases <sailor> <app> <model>: health, status, check, and pick on one
# installed app, requiring every reading to agree on whether it is signed in.
sailor_cases() {
  local name=$1 app=$2 model=$3 version health status check pick rc
  version=$(app_version "$app")
  health=$(run_sailor health | awk -v n="$name" '$1 == n')
  status=$(run_sailor status | awk -v n="$name" '$1 == n')
  check=$(run_sailor check "$name" "$model")
  rc=$?
  case "$health" in
    "$name up login:$app")
      assert_contains "$status" "$name live answering harness=$app tasks=0/1 grade=" "$app $version: status must read a signed-in app as answering"
      assert_contains "$status" "models=$model(signed-in)" "$app $version: status must read the model as signed-in"
      expect_code 0 "$rc" "$app $version: check must pass on a signed-in app: $check"
      assert_equals "ok: sailor $name runs $model on its $app login (0 of 1 tasks busy; signed in)" "$check" "$app $version: check must report the login"
      pick=$(run_sailor pick --sailor "$name")
      expect_code 0 "$?" "$app $version: pick must take a signed-in login sailor: $pick"
      assert_equals "$name $model" "$pick" "$app $version: pick must print the sailor and its model"
      pass "$app $version: health, status, check, and pick read the $name login as signed in, and check says so without printing a value"
      ;;
    "$name down login:$app")
      assert_contains "$status" "$name live not-answering harness=$app" "$app $version: status must read a signed-out app as not answering"
      assert_contains "$status" "models=$model(signed-out)" "$app $version: status must read the model as signed-out"
      expect_code 1 "$rc" "$app $version: check must refuse a signed-out app: $check"
      assert_contains "$check" "refused: sailor $name is signed out of $app: " "$app $version: check must name the app and the reason"
      pass "$app $version: health, status, and check agree the $name login is signed out, naming the app and never a value"
      ;;
    *) fail "$app $version: health printed an unexpected line for $name: '$health'" ;;
  esac
  CHECKED="$CHECKED $app"
}

for app in codex kimi grok; do
  if ! command -v "$app" >/dev/null 2>&1; then
    echo "skip-app: $app is not installed, so its login sailor was not exercised"
    ABSENT="$ABSENT $app"
  fi
done
if [ "$(printf '%s' "$ABSENT" | wc -w | tr -d ' ')" = 3 ]; then
  fail "the login sailors live guard was requested but none of codex, kimi, or grok is installed"
fi

# The three sailors, registered by hand, then replaced by the same three
# projected from a scratch slot registry, which must change nothing.
out=$(run_sailor add teach --harness codex --models gpt-6-sol --login chatgpt --live) || fail "add teach failed: $out"
out=$(run_sailor add bonny --harness kimi --models kimi-for-coding --live) || fail "add bonny failed: $out"
out=$(run_sailor add mary --harness grok --models grok-4.7 --login grok.com --live) || fail "add mary failed: $out"
run_sailor validate >/dev/null || fail "the hand-registered map must validate"
jq -n --arg h "$CASE_DIR" '{schema: 1, homes: {firstmate: $h}, slots: {
    teach: {harness: "codex", login: "chatgpt", model: "gpt-6-sol", grade: "specialist", capacity: 1, homes: {firstmate: 1}, status: "live"},
    bonny: {harness: "kimi", model: "kimi-for-coding", grade: "sailor", capacity: 1, homes: {firstmate: 1}, status: "live"},
    mary: {harness: "grok", login: "grok.com", model: "grok-4.7", grade: "sailor", capacity: 1, homes: {firstmate: 1}, status: "live"},
    kidd: {}}}' > "$REGISTRY"
printf '%s\n' '{"servers": []}' > "$TMP_ROOT/servers.json"
printf '%s\n' "$REGISTRY" > "$CASE_DIR/config/sailor-registry"
out=$(run_sailor sync "$REGISTRY" --home firstmate) || fail "sync from the scratch registry failed: $out"
assert_equals '["teach","bonny","mary"]' "$(jq -c '.sailors | keys_unsorted' "$CASE_DIR/config/crew-dispatch.json")" "sync must project exactly the three login slots"
assert_equals '{"harness":"codex","login":"chatgpt","status":"live","models":["gpt-6-sol"],"max_concurrent":1,"grade":"specialist"}' \
  "$(jq -c '.sailors.teach' "$CASE_DIR/config/crew-dispatch.json")" "a login slot must project into a login sailor"
pass "sync projects the three login slots from a scratch registry into login sailors"

command -v codex >/dev/null 2>&1 && sailor_cases teach codex gpt-6-sol
command -v kimi >/dev/null 2>&1 && sailor_cases bonny kimi kimi-for-coding
command -v grok >/dev/null 2>&1 && sailor_cases mary grok grok-4.7

out=$(run_sailor provider-json teach gpt-6-sol)
expect_code 1 "$?" "provider-json must refuse a login sailor"
pass "a login sailor takes no OpenCode provider"
echo "# login sailors live guard checked:$CHECKED${ABSENT:+ (absent:$ABSENT)}"
