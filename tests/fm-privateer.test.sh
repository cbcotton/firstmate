#!/usr/bin/env bash
# tests/fm-privateer.test.sh - the Privateer quarantine through its three
# entry points: bin/fm-privateer.sh check names every forbidden file, key,
# profile, and endpoint; bin/fm-spawn.sh refuses each forbidden spawn in a
# Privateer home and clears the environment of the one it allows; and the
# launcher, run with a stub first mate that prints its environment, passes no
# ANTHROPIC_*, CLAUDE_*, or CLAUDECODE variable, refuses without the flag or
# with a forbidden file, starts the real egress proxy (bin/fm-privateer-proxy.py)
# with exactly the sailors and the forge allowed and a sandbox that reaches only
# that proxy, refuses when the proxy cannot bind, and refuses to stop while work
# is in flight. A fake tmux runs each new window's command in the background
# and records every call, and a fake sandbox-exec records the profile it was
# given and runs the command, so the launch shape is pinned on every platform;
# the live egress audit (tests/fm-privateer-egress-live-e2e.test.sh) runs the
# real ones.
# docs/configuration.md ("Privateer quarantine") owns the contract.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

PRIVATEER="$ROOT/bin/fm-privateer.sh"
TMP_ROOT=$(fm_test_tmproot fm-privateer)
DISPATCH='{"sailors":{"tiller":{"title":"Tiller","endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["coder"]}},"default":{"harness":"opencode","sailor":"tiller","model":"coder"}}'

# make_home <name>: a clean Privateer home under TMP_ROOT/<name>; prints its path.
make_home() {
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"
  printf 'tiller/coder\n' > "$home/config/privateer"
  printf 'opencode\n' > "$home/config/crew-harness"
  : > "$home/config/sailor-sandbox"
  printf '%s\n' "$DISPATCH" > "$home/config/crew-dispatch.json"
  printf '%s\n' "$home"
}

# wait_for_file <path>: up to five seconds for <path> to exist.
wait_for_file() {
  local _
  for _ in $(seq 50); do
    [ -e "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

run_check() {  # <home>
  FM_HOME="$1" "$PRIVATEER" check 2>&1
}

# fake_sailor_curl <fakebin>: the sailor's model server answering the probe.
fake_sailor_curl() {
  cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"data":[{"id":"coder"}]}'
SH
  chmod +x "$1/curl"
}

# make_launcher_fakebin <case-dir>: a tmux that runs each new session's or
# window's command in the background and logs every call to <case-dir>/tmux.log,
# keeping "running" as the file <case-dir>/tmux-running while the session's
# first window lives and the background pids in <case-dir>/tmux-pids; a
# sandbox-exec that writes its profile to <case-dir>/profile.sb and runs the
# command; and the sailor's curl. The launcher clears the environment, so the
# paths are baked in. Prints the dir.
make_launcher_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$dir/tmux.log'
running='$dir/tmux-running'
pids='$dir/tmux-pids'
printf '%s\\n' "\$*" >> "\$log"
sock=
if [ "\${1:-}" = -L ]; then sock=\$2; shift 2; fi
case "\${1:-}" in
  has-session)
    [ -e "\$running" ] || exit 1
    [ ! -s "\$pids" ] || kill -0 "\$(head -1 "\$pids")" 2>/dev/null
    ;;
  new-session | new-window)
    [ "\$1" = new-window ] || : > "\$running"
    shift
    wd=
    cmd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        -c) wd=\$2; shift 2 ;;
        -d) shift ;;
        -s | -n | -t) shift 2 ;;
        --) shift; cmd=\$1; break ;;
        *) shift ;;
      esac
    done
    pane=\$(wc -l < "\$pids" 2>/dev/null || echo 0)
    ( cd "\$wd" && exec env TMUX="/tmp/tmux-fake/\$sock,1,0" TMUX_PANE="%\$((pane))" /bin/sh -c "\$cmd" ) >/dev/null 2>&1 &
    echo \$! >> "\$pids"
    ;;
  kill-server)
    [ ! -s "\$pids" ] || kill \$(cat "\$pids") 2>/dev/null
    rm -f "\$running" "\$pids"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  cat > "$fakebin/sandbox-exec" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -p ]; then
  printf '%s\\n' "\$2" > '$dir/profile.sb'
  shift 2
fi
exec "\$@"
SH
  chmod +x "$fakebin/tmux" "$fakebin/sandbox-exec"
  fake_sailor_curl "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_stub_primary <case-dir>: a first mate that records its environment and
# working directory in <case-dir>/primary.env; prints the stub's path.
make_stub_primary() {
  local dir=$1
  cat > "$dir/stub-primary" <<SH
#!/usr/bin/env bash
env > '$dir/primary.env.tmp'
printf 'CWD=%s\\n' "\$PWD" >> '$dir/primary.env.tmp'
mv '$dir/primary.env.tmp' '$dir/primary.env'
SH
  chmod +x "$dir/stub-primary"
  printf '%s\n' "$dir/stub-primary"
}

# run_launcher <case-dir> <home> <root> <args...>: the launcher with the fakes on
# PATH, the stub as the first mate, and a captain's shell full of forbidden
# variables, so anything that leaks is visible.
run_launcher() {
  local dir=$1 home=$2 root=$3
  shift 3
  ANTHROPIC_API_KEY=sk-secret ANTHROPIC_BASE_URL=https://api.anthropic.com CLAUDE_CODE_OAUTH_TOKEN=tok \
    CLAUDECODE=1 CLAUDE_CONFIG_DIR=/captain/.claude OPENAI_API_KEY=oai FMX_PAIRING_TOKEN=relay \
    TMUX=outer,1,0 TMUX_PANE=%9 SSH_AUTH_SOCK=/captain/agent \
    PATH="$dir/fakebin:$PATH" FM_TEST_SEAM=1 FM_PRIVATEER_PRIMARY="$dir/stub-primary" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$PRIVATEER" "$@" 2>&1
}

# --- check ------------------------------------------------------------------

test_check_is_silent_without_the_flag() {
  local home out status
  home=$(make_home no-flag)
  rm "$home/config/privateer"
  out=$(run_check "$home")
  status=$?
  expect_code 0 "$status" "check must pass a home without config/privateer"
  assert_equals "" "$out" "check must print nothing without config/privateer"
  pass "check is silent and passes when config/privateer is absent"
}

test_check_passes_a_clean_home() {
  local home out status
  home=$(make_home clean)
  out=$(run_check "$home")
  status=$?
  expect_code 0 "$status" "a clean Privateer home must pass: $out"
  assert_equals "" "$out" "a clean home must print nothing"
  pass "check passes a Privateer home with only opencode, a sandbox, and private sailors"
}

test_check_names_every_violation() {
  local home out status
  home=$(make_home dirty)
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'claude claude-opus-5-5 high\n' > "$home/config/secondmate-harness"
  : > "$home/config/supervision-host"
  printf 'ordinary\n' > "$home/config/claude-account"
  printf '/captain/.pi\nanthropic\n' > "$home/config/pi-account"
  for f in inbox-ask-model inbox-stt-model inbox-region inbox-profile voice-model voice-region voice-profile; do
    printf 'bedrock\n' > "$home/config/$f"
  done
  rm "$home/config/sailor-sandbox"
  printf 'FMX_PAIRING_TOKEN=relay\nTYPESAFE_API_KEY=typed\nFM_INBOX_ASK_MODEL=anthropic.claude-opus\nexport FM_VOICE_MODEL=nova\nexport ANTHROPIC_API_KEY=sk\nCLAUDE_CODE_OAUTH_TOKEN=tok\nCLAUDECODE=1\nOPENAI_API_KEY=fine\n' > "$home/.env"
  printf '# proxy\nANTHROPIC_BASE_URL\nSSH_AUTH_SOCK\n' > "$home/config/launch-env-allowlist"
  printf '%s\n' '{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["coder"]},"stoker":{"endpoint":"http://stoker.example.com:8000/v1","status":"placeholder","models":["coder"]}},"rules":[{"when":"anything","use":[{"harness":"claude","model":"claude-opus-5-5"},{"harness":"opencode","model":"anthropic/claude-sonnet-5"}]}],"default":{"harness":"opencode","sailor":"tiller","model":"coder"},"sailor_fallback":{"harness":"claude","model":"claude-opus-5-5"}}' \
    > "$home/config/crew-dispatch.json"
  printf 'tiller/other\n' > "$home/config/privateer"
  out=$(run_check "$home")
  status=$?
  expect_code 1 "$status" "a home full of violations must fail check"
  assert_contains "$out" "config/crew-harness must hold opencode" "the crew harness violation is missing"
  assert_contains "$out" "config/secondmate-harness names claude, a harness other than opencode" "the secondmate harness violation is missing"
  assert_contains "$out" "config/supervision-host exists, and the supervision host runs on Claude" "the supervision host violation is missing"
  assert_contains "$out" "config/claude-account exists, and it pins a Claude login" "the Claude account violation is missing"
  assert_contains "$out" "config/pi-account exists, and it pins a Pi login" "the Pi account violation is missing"
  for f in inbox-ask-model inbox-stt-model inbox-region inbox-profile voice-model voice-region voice-profile; do
    assert_contains "$out" "config/$f exists, and the inbox and voice side channels send the captain's words to Bedrock" "the $f violation is missing"
  done
  assert_contains "$out" ".env sets FM_INBOX_ASK_MODEL, and the inbox and voice side channels send the captain's words to Bedrock" "the inbox override violation is missing"
  assert_contains "$out" ".env sets FM_VOICE_MODEL, and the inbox and voice side channels send the captain's words to Bedrock" "the voice override violation is missing"
  assert_contains "$out" "config/sailor-sandbox is absent" "the missing sandbox violation is missing"
  assert_contains "$out" ".env sets FMX_PAIRING_TOKEN" "the Relay token violation is missing"
  assert_contains "$out" ".env sets TYPESAFE_API_KEY" "the typed resolution key violation is missing"
  assert_contains "$out" ".env sets ANTHROPIC_API_KEY, an Anthropic or Claude variable" "the exported Anthropic key violation is missing"
  assert_contains "$out" ".env sets CLAUDE_CODE_OAUTH_TOKEN" "the Claude token violation is missing"
  assert_contains "$out" ".env sets CLAUDECODE" "the CLAUDECODE marker violation is missing"
  assert_not_contains "$out" "OPENAI_API_KEY" "a non-Anthropic key in .env is not a quarantine violation"
  assert_contains "$out" "config/launch-env-allowlist lists ANTHROPIC_BASE_URL" "the allowlist violation is missing"
  assert_not_contains "$out" "SSH_AUTH_SOCK" "a harmless allowlist name is not a violation"
  assert_contains "$out" "config/crew-dispatch.json declares sailor_fallback" "the fallback violation is missing"
  assert_contains "$out" "profile claude/claude-opus-5-5 uses a harness other than opencode" "the Claude profile violation is missing"
  assert_contains "$out" "profile opencode/anthropic/claude-sonnet-5 names no sailor" "the sailor-less profile violation is missing"
  assert_contains "$out" "sailor stoker has endpoint 'http://stoker.example.com:8000/v1', which is not on this machine or the local network" "the public endpoint violation is missing"
  assert_contains "$out" "config/privateer names tiller/other, but config/crew-dispatch.json lists no such sailor and model" "the first mate line violation is missing"
  pass "check names every forbidden file, key, Bedrock side channel, harness, profile, fallback, endpoint, and first mate line"
}

test_check_requires_the_dispatch_file() {
  local home out
  home=$(make_home no-dispatch)
  rm "$home/config/crew-dispatch.json"
  out=$(run_check "$home")
  assert_contains "$out" "config/crew-dispatch.json is absent; a Privateer home dispatches only to the sailors it names" "the missing dispatch file must be a violation"
  pass "check requires config/crew-dispatch.json so nothing can dispatch off a sailor"
}

# check_endpoints <home> <url...>: check with one sailor per URL, named s<n>.
check_endpoints() {
  local home=$1 n=0 url sailors='{}'
  shift
  for url in "$@"; do
    n=$((n + 1))
    sailors=$(jq -c --arg n "s$n" --arg e "$url" '. + {($n): {endpoint: $e, status: "live", models: ["coder"]}}' <<< "$sailors")
  done
  jq -n --argjson s "$sailors" '{sailors: ($s + {tiller: {endpoint: "http://127.0.0.1:11234/v1", status: "live", models: ["coder"]}}), default: {harness: "opencode", sailor: "tiller", model: "coder"}}' \
    > "$home/config/crew-dispatch.json"
  run_check "$home"
}

test_endpoint_rule() {
  local home out status url
  local -a good bad
  home=$(make_home endpoints)
  good=(http://localhost:11234/v1 http://127.0.0.1:11234/v1 http://10.1.2.3:8000/v1 http://172.31.0.9:8000/v1
    http://192.168.1.9:8000/v1 http://100.100.1.1:8000/v1 http://flint.local:8000/v1 http://stoker.tail.ts.net:8000/v1
    'http://[::1]:11234/v1' 'http://[fd7a:115c::1]:8000/v1' 'http://127.0.0.1:11234?x=1' 'http://Flint.LOCAL:8000#top')
  out=$(check_endpoints "$home" "${good[@]}")
  status=$?
  expect_code 0 "$status" "check must accept every private endpoint: $out"
  bad=(https://api.anthropic.com/v1 http://8.8.8.8/v1 http://172.32.0.1/v1 http://100.128.0.1/v1 http://stoker:8000/v1
    http://example.local.com/v1 'http://[2001:db8::1]/v1' 'not a url' ''
    'http://api.anthropic.com#@127.0.0.1/v1' 'http://api.anthropic.com?@10.0.0.1/v1' 'http://api.anthropic.com\@127.0.0.1/'
    'http://user@127.0.0.1:11234/v1' 'http://127.0.0.1:port/v1' 'http://[::1/v1')
  out=$(check_endpoints "$home" "${bad[@]}")
  status=$?
  expect_code 1 "$status" "check must refuse every public or ambiguous endpoint"
  for url in "${bad[@]}"; do
    assert_contains "$out" "has endpoint '$url', which is not on this machine or the local network" "check must refuse '$url'"
  done
  pass "check accepts loopback, private, tailnet, .local, and .ts.net endpoints and refuses the rest, including an authority hidden behind ?, #, a backslash, or userinfo"
}

test_launch_env_lives_inside_the_home() {
  local home out status
  home=$(make_home launch-env)
  out=$(FM_HOME="$home" "$PRIVATEER" launch-env 2>&1)
  status=$?
  expect_code 1 "$status" "launch-env must refuse while no egress proxy runs"
  assert_contains "$out" "the Privateer egress proxy is not running" "the refusal must name the proxy"
  mkdir -p "$home/state/privateer/egress"
  printf '18080\n' > "$home/state/privateer/egress/port"
  out=$(FM_HOME="$home" "$PRIVATEER" launch-env)
  assert_equals "XDG_CONFIG_HOME=$home/state/privateer/opencode/config
XDG_DATA_HOME=$home/state/privateer/opencode/data
XDG_STATE_HOME=$home/state/privateer/opencode/state
XDG_CACHE_HOME=$home/state/privateer/opencode/cache
OPENCODE_DISABLE_AUTOUPDATE=1
HTTP_PROXY=http://127.0.0.1:18080
HTTPS_PROXY=http://127.0.0.1:18080
http_proxy=http://127.0.0.1:18080
https_proxy=http://127.0.0.1:18080
GIT_SSH_COMMAND=ssh -o ProxyCommand='/usr/bin/nc -X connect -x 127.0.0.1:18080 %h %p'" "$out" "launch-env must isolate OpenCode under the home's state directory and route every client through the egress proxy"
  pass "launch-env points every OpenCode directory inside the home, turns auto-update off, names the egress proxy, and refuses without one"
}

# --- launcher ---------------------------------------------------------------

test_start_refuses_without_the_flag() {
  local dir home root out status
  dir="$TMP_ROOT/start-no-flag"
  home=$(make_home start-no-flag)
  rm "$home/config/privateer"
  root="$dir/root"
  fm_git_init_commit "$root"
  make_launcher_fakebin "$dir" >/dev/null
  make_stub_primary "$dir" >/dev/null
  out=$(run_launcher "$dir" "$home" "$root" start)
  status=$?
  expect_code 1 "$status" "start must refuse without config/privateer"
  assert_contains "$out" "config/privateer is absent" "the refusal must name the flag"
  [ ! -e "$dir/tmux.log" ] || fail "start must not touch tmux without the flag"
  pass "start refuses a home without config/privateer"
}

test_start_refuses_with_a_forbidden_file() {
  local dir home root out status
  dir="$TMP_ROOT/start-forbidden"
  home=$(make_home start-forbidden)
  : > "$home/config/supervision-host"
  root="$dir/root"
  fm_git_init_commit "$root"
  make_launcher_fakebin "$dir" >/dev/null
  make_stub_primary "$dir" >/dev/null
  out=$(run_launcher "$dir" "$home" "$root" start)
  status=$?
  expect_code 1 "$status" "start must refuse with a forbidden file present"
  assert_contains "$out" "the quarantine is not satisfied" "the refusal must say the quarantine failed"
  assert_contains "$out" "config/supervision-host exists" "the refusal must name the forbidden file"
  [ ! -e "$dir/tmux.log" ] || fail "start must not touch tmux with a forbidden file present"
  pass "start refuses while a forbidden file is present"
}

test_start_refuses_without_a_first_mate_line() {
  local dir home root out status
  dir="$TMP_ROOT/start-no-line"
  home=$(make_home start-no-line)
  : > "$home/config/privateer"
  root="$dir/root"
  fm_git_init_commit "$root"
  make_launcher_fakebin "$dir" >/dev/null
  make_stub_primary "$dir" >/dev/null
  out=$(run_launcher "$dir" "$home" "$root" start)
  status=$?
  expect_code 1 "$status" "start must refuse without a first mate line"
  assert_contains "$out" "config/privateer names no first mate; write one line <sailor>/<model>" "the refusal must say what to write"
  pass "start refuses until config/privateer names the first mate's sailor and model"
}

test_start_passes_only_the_allowlist() {
  local dir home root out status envlog profile home_real root_real port
  dir="$TMP_ROOT/start"
  home=$(make_home start)
  root="$dir/root"
  fm_git_init_commit "$root"
  git -C "$root" remote add origin https://token@Forge.example.test:3000/captain/firstmate.git
  make_launcher_fakebin "$dir" >/dev/null
  make_stub_primary "$dir" >/dev/null
  out=$(run_launcher "$dir" "$home" "$root" start)
  status=$?
  expect_code 0 "$status" "start must succeed in a clean home: $out"
  home_real=$(cd "$home" && pwd -P)
  root_real=$(cd "$root" && pwd -P)
  port=$(cat "$home/state/privateer/egress/port" 2>/dev/null)
  [ -n "$port" ] || fail "start must record the egress proxy's port: $out"
  assert_contains "$out" "privateer: started session privateer on tmux socket fm-privateer-" "start must report the session and its socket"
  assert_contains "$out" "(first mate tiller/coder, egress proxy 127.0.0.1:$port)" "start must report the first mate's sailor and model and the proxy"
  envlog="$dir/primary.env"
  wait_for_file "$envlog" || fail "the stub first mate never ran; tmux log: $(cat "$dir/tmux.log" 2>/dev/null)"
  ! grep -E '^(ANTHROPIC_|CLAUDE_|CLAUDECODE=|OPENAI_|FMX_|SSH_AUTH_SOCK=|FM_TEST_SEAM=|FM_PRIVATEER_PRIMARY=)' "$envlog" \
    || fail "a forbidden or unlisted variable reached the first mate:"$'\n'"$(grep -E '^(ANTHROPIC_|CLAUDE_|CLAUDECODE=|OPENAI_|FMX_|SSH_AUTH_SOCK=|FM_TEST_SEAM=|FM_PRIVATEER_PRIMARY=)' "$envlog")"
  assert_grep "FM_HOME=$home_real" "$envlog" "the first mate must receive FM_HOME"
  assert_grep "XDG_CONFIG_HOME=$home_real/state/privateer/opencode/config" "$envlog" "OpenCode's config directory must sit inside the home"
  assert_grep "XDG_DATA_HOME=$home_real/state/privateer/opencode/data" "$envlog" "OpenCode's data directory must sit inside the home"
  assert_grep "XDG_STATE_HOME=$home_real/state/privateer/opencode/state" "$envlog" "OpenCode's state directory must sit inside the home"
  assert_grep "XDG_CACHE_HOME=$home_real/state/privateer/opencode/cache" "$envlog" "OpenCode's cache directory must sit inside the home"
  assert_grep "OPENCODE_DISABLE_AUTOUPDATE=1" "$envlog" "auto-update must be off"
  assert_grep 'OPENCODE_CONFIG_CONTENT={"autoupdate":false,"share":"disabled","model":"tiller/coder","permission":{"*":"allow"},"provider":{"tiller":{"npm":"@ai-sdk/openai-compatible","name":"Tiller","options":{"baseURL":"http://127.0.0.1:11234/v1"},"models":{"coder":{"name":"coder"}}}}}' "$envlog" \
    "the first mate's OpenCode config must pin the model to its sailor as the only provider, with auto-update off and sharing disabled"
  assert_equals "HTTPS_PROXY=http://127.0.0.1:$port" "$(grep '^HTTPS_PROXY=' "$envlog")" "the egress proxy must reach the first mate as HTTPS_PROXY"
  assert_equals "HTTP_PROXY=http://127.0.0.1:$port" "$(grep '^HTTP_PROXY=' "$envlog")" "the egress proxy must reach the first mate as HTTP_PROXY"
  assert_equals "GIT_SSH_COMMAND=ssh -o ProxyCommand='/usr/bin/nc -X connect -x 127.0.0.1:$port %h %p'" "$(grep '^GIT_SSH_COMMAND=' "$envlog")" "Git over SSH must tunnel through the egress proxy"
  assert_grep "TMUX=/tmp/tmux-fake/fm-privateer-" "$envlog" "the first mate must keep the TMUX its own server set"
  assert_grep "TMUX_PANE=%1" "$envlog" "the first mate must keep the TMUX_PANE its own server set"
  assert_grep "HOME=" "$envlog" "HOME must be passed"
  assert_grep "PATH=" "$envlog" "PATH must be passed"
  assert_grep "CWD=$root_real" "$envlog" "the first mate must run in the checkout"
  for d in config data state cache; do
    [ -d "$home/state/privateer/opencode/$d" ] || fail "start must create OpenCode's $d directory"
  done
  profile="$dir/profile.sb"
  [ -f "$profile" ] || fail "the first mate never ran inside the sandbox"
  assert_grep '(deny network-outbound)' "$profile" "the sandbox must deny every connection first"
  assert_equals "(allow network-outbound (remote ip \"localhost:$port\"))" "$(grep 'remote ip' "$profile")" \
    "the egress proxy must be the sandbox's only allowed address"
  assert_grep "(subpath \"$home_real\")" "$profile" "the sandbox must allow writes to the home"
  assert_grep "(subpath \"$home_real/state/privateer/egress\")" "$profile" "the sandbox must deny writes to the egress record"
  assert_grep "(subpath \"$root_real/.opencode\")" "$profile" "the sandbox must allow OpenCode's scratch in the checkout"
  assert_grep '(regex #"^/private/tmp/fm-")' "$profile" "the sandbox must allow firstmate's per-task temp roots"
  assert_grep '(allow network-outbound (remote unix-socket (path-literal "/private/tmp/tmux-' "$profile" "the sandbox must allow the session's own tmux socket"
  assert_grep 'new-session -d -s privateer -n egress ' "$dir/tmux.log" "tmux must start the session with the egress proxy"
  assert_grep 'new-window -t privateer -n firstmate -c '"$root_real" "$dir/tmux.log" "tmux must start the first mate in the checkout"
  assert_grep "set-option -g update-environment " "$dir/tmux.log" "the server must copy no variable from an attaching client"
  # The proxy start launched allows exactly the sailor and the forge.
  assert_not_contains "$(proxy_request "$port" 'CONNECT forge.example.test:3000 HTTP/1.1')" "403" "the forge must be allowed through the proxy"
  assert_not_contains "$(proxy_request "$port" 'CONNECT 127.0.0.1:11234 HTTP/1.1')" "403" "the sailor must be allowed through the proxy"
  assert_contains "$(proxy_request "$port" 'CONNECT api.anthropic.com:443 HTTP/1.1')" "HTTP/1.1 403" "Anthropic must be refused by the proxy"
  assert_contains "$(proxy_request "$port" 'CONNECT forge.example.test:443 HTTP/1.1')" "HTTP/1.1 403" "the forge's host on another port must be refused"
  assert_equals 'allowed CONNECT forge.example.test:3000
allowed CONNECT 127.0.0.1:11234
refused CONNECT api.anthropic.com:443
refused CONNECT forge.example.test:443' "$(jq -r '"\(.verdict) \(.method) \(.dest)"' "$home/state/privateer/egress/log")" \
    "the proxy log must record every allowed and refused destination"
  out=$(run_launcher "$dir" "$home" "$root" stop)
  expect_code 0 "$?" "stop must end the session: $out"
  [ ! -e "$home/state/privateer/egress/port" ] || fail "stop must retire the proxy's port"
  ! proxy_request "$port" 'CONNECT 127.0.0.1:11234 HTTP/1.1' | grep -q HTTP || fail "stop must stop the egress proxy"
  pass "start runs the egress proxy with the sailor and forge allowed, and the first mate with only the allowlist, isolated OpenCode directories, and a sandbox that reaches only that proxy"
}

test_start_refuses_when_the_proxy_cannot_bind() {
  local dir home root out status fakebin
  dir="$TMP_ROOT/start-no-bind"
  home=$(make_home start-no-bind)
  root="$dir/root"
  fm_git_init_commit "$root"
  fakebin=$(make_launcher_fakebin "$dir")
  printf '#!/bin/sh\necho "cannot bind" >&2\nexit 1\n' > "$fakebin/python3"
  chmod +x "$fakebin/python3"
  make_stub_primary "$dir" >/dev/null
  out=$(run_launcher "$dir" "$home" "$root" start)
  status=$?
  expect_code 1 "$status" "start must refuse when the proxy cannot bind"
  assert_contains "$out" "the Privateer egress proxy could not bind a loopback port; nothing was started" "the refusal must name the proxy"
  assert_grep "kill-server" "$dir/tmux.log" "a refused start must stop the server it began"
  assert_no_grep "new-window" "$dir/tmux.log" "no first mate may start without the proxy"
  [ ! -e "$dir/primary.env" ] || fail "no first mate may start without the proxy"
  pass "start refuses, and leaves nothing running, when the egress proxy cannot bind"
}

# proxy_request <port> <request-line>: the proxy's status line for one request.
proxy_request() {
  printf '%s\r\nHost: x\r\n\r\n' "$2" | nc -w 5 127.0.0.1 "$1" 2>/dev/null | head -1 | tr -d '\r'
}

test_proxy_forwards_only_allowed_destinations() {
  local dir port sailor_port pid spid out
  dir="$TMP_ROOT/proxy"
  mkdir -p "$dir/www/v1"
  printf 'sailor reply\n' > "$dir/www/v1/models"
  ( cd "$dir/www" && exec python3 -u -m http.server 0 --bind 127.0.0.1 ) > "$dir/www.log" 2>&1 &
  spid=$!
  for _ in $(seq 100); do
    sailor_port=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$dir/www.log" | head -1)
    [ -n "$sailor_port" ] && break
    sleep 0.1
  done
  [ -n "$sailor_port" ] || fail "the stand-in sailor did not start"
  python3 "$ROOT/bin/fm-privateer-proxy.py" "$dir/port" "$dir/log" "127.0.0.1:$sailor_port" &
  pid=$!
  wait_for_file "$dir/port" || fail "the proxy did not record its port"
  port=$(cat "$dir/port")
  out=$(curl -sS -m 5 -x "http://127.0.0.1:$port" "http://127.0.0.1:$sailor_port/v1/models" 2>&1)
  assert_equals "sailor reply" "$out" "an allowed request must reach the sailor through the proxy"
  for target in "http://api.anthropic.com/v1/messages" "http://api.anthropic.com#@127.0.0.1:$sailor_port/v1" \
    "http://api.anthropic.com?@127.0.0.1:$sailor_port/v1" "http://api.anthropic.com\\@127.0.0.1:$sailor_port/" \
    "http://user@127.0.0.1:$sailor_port/v1" "https://127.0.0.1:$sailor_port/v1"; do
    assert_equals "HTTP/1.1 403 Forbidden" "$(proxy_request "$port" "GET $target HTTP/1.1")" "the proxy must refuse $target"
  done
  assert_equals "HTTP/1.1 403 Forbidden" "$(proxy_request "$port" "CONNECT api.anthropic.com:443 HTTP/1.1")" "the proxy must refuse a tunnel to Anthropic"
  kill "$pid" "$spid" 2>/dev/null
  wait "$pid" "$spid" 2>/dev/null
  assert_equals "allowed GET 127.0.0.1:$sailor_port
refused GET api.anthropic.com:80
refused GET api.anthropic.com:80
refused GET api.anthropic.com:80
refused GET http://api.anthropic.com\\@127.0.0.1:$sailor_port/
refused GET http://user@127.0.0.1:$sailor_port/v1
refused GET https://127.0.0.1:$sailor_port/v1
refused CONNECT api.anthropic.com:443" "$(jq -r '"\(.verdict) \(.method) \(.dest)"' "$dir/log")" "the proxy must log every allowed and refused destination"
  pass "the egress proxy forwards to an allowed sailor and refuses and logs every other destination, including an authority hidden behind ?, #, a backslash, or userinfo"
}

test_start_refuses_while_running() {
  local dir home root out status
  dir="$TMP_ROOT/start-running"
  home=$(make_home start-running)
  root="$dir/root"
  fm_git_init_commit "$root"
  make_launcher_fakebin "$dir" >/dev/null
  make_stub_primary "$dir" >/dev/null
  : > "$dir/tmux-running"
  out=$(run_launcher "$dir" "$home" "$root" start)
  status=$?
  expect_code 1 "$status" "start must refuse while the session runs"
  assert_contains "$out" "already running" "the refusal must say the session runs"
  [ ! -e "$dir/primary.env" ] || fail "a second start must not launch a second first mate"
  pass "start refuses while the Privateer session is already running"
}

test_stop_refuses_with_work_in_flight_and_stops_an_idle_session() {
  local dir home root out status
  dir="$TMP_ROOT/stop"
  home=$(make_home stop)
  root="$dir/root"
  fm_git_init_commit "$root"
  make_launcher_fakebin "$dir" >/dev/null
  make_stub_primary "$dir" >/dev/null
  out=$(run_launcher "$dir" "$home" "$root" stop)
  status=$?
  expect_code 1 "$status" "stop must refuse when nothing runs"
  assert_contains "$out" "the Privateer session is not running" "the refusal must say nothing runs"
  : > "$dir/tmux-running"
  printf 'harness=opencode\nkind=ship\n' > "$home/state/task-a1.meta"
  printf 'harness=opencode\nkind=scout\n' > "$home/state/scout-b2.meta"
  out=$(run_launcher "$dir" "$home" "$root" stop)
  status=$?
  expect_code 1 "$status" "stop must refuse with work in flight"
  assert_contains "$out" "work is in flight (scout-b2 task-a1)" "the refusal must name every task in flight"
  [ -e "$dir/tmux-running" ] || fail "a refused stop must leave the session running"
  assert_no_grep "kill-server" "$dir/tmux.log" "a refused stop must not touch the server"
  rm "$home/state/task-a1.meta" "$home/state/scout-b2.meta"
  out=$(run_launcher "$dir" "$home" "$root" stop)
  status=$?
  expect_code 0 "$status" "stop must succeed with nothing in flight: $out"
  assert_contains "$out" "privateer: stopped session privateer" "stop must report the stopped session"
  [ ! -e "$dir/tmux-running" ] || fail "stop must end the session"
  assert_grep "kill-server" "$dir/tmux.log" "stop must stop the whole server"
  pass "stop refuses while task records exist and stops the idle session otherwise"
}

test_attach_refuses_without_a_session() {
  local dir home root out status
  dir="$TMP_ROOT/attach"
  home=$(make_home attach)
  root="$dir/root"
  fm_git_init_commit "$root"
  make_launcher_fakebin "$dir" >/dev/null
  make_stub_primary "$dir" >/dev/null
  out=$(run_launcher "$dir" "$home" "$root" attach)
  status=$?
  expect_code 1 "$status" "attach must refuse when nothing runs"
  assert_contains "$out" "not running; start it first" "the refusal must point at start"
  pass "attach refuses when the Privateer session is not running"
}

# --- spawn ------------------------------------------------------------------

# make_spawn_case <name> <id>: a Privateer home with a project and worktree for
# one spawn; sets CASE_DIR, HOME_DIR, PROJ_DIR, WT_DIR, FAKEBIN_DIR, LAUNCH_LOG.
make_spawn_case() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/spawn-$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" opencode
  printf 'tiller/coder\n' > "$HOME_DIR/config/privateer"
  : > "$HOME_DIR/config/sailor-sandbox"
  printf '%s\n' "$DISPATCH" > "$HOME_DIR/config/crew-dispatch.json"
  mkdir -p "$HOME_DIR/state/privateer/egress"
  printf '18080\n' > "$HOME_DIR/state/privateer/egress/port"
  fake_sailor_curl "$FAKEBIN_DIR"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN_DIR/sandbox-exec"
  chmod +x "$FAKEBIN_DIR/sandbox-exec"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$LAUNCH_LOG"
}

run_spawn() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# sq <text>: <text> single-quoted as it appears inside the launch's `sh -c` string.
sq() {
  printf "'\\\\''%s'\\\\''" "$1"
}

assert_refused_spawn() {  # <id> <status> <output> <needle> <label>
  expect_code 1 "$2" "$5"$'\n'"$3"
  assert_contains "$3" "$4" "$5: refusal text"
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "$5: a refused spawn must leave no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "$5: a refused spawn must launch nothing"
}

test_spawn_refuses_a_claude_harness() {
  local id=pv-claude out status
  make_spawn_case claude "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --mode local-only --yolo off --harness claude --model claude-opus-5-5)
  status=$?
  assert_refused_spawn "$id" "$status" "$out" "error: the Privateer quarantine refuses harness claude" "a Claude worker"
  pass "a Privateer home refuses a Claude worker before any record exists"
}

test_spawn_refuses_pipeline_and_pr_delivery() {
  local id=pv-mode out status
  make_spawn_case mode "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness opencode --model coder --sailor tiller)
  status=$?
  assert_refused_spawn "$id" "$status" "$out" "error: the Privateer quarantine refuses delivery mode no-mistakes" "a no-mistakes ship"
  out=$(run_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off --harness opencode --model coder --sailor tiller)
  status=$?
  assert_refused_spawn "$id" "$status" "$out" "error: the Privateer quarantine refuses delivery mode direct-PR" "a direct-PR ship"
  pass "a Privateer home ships local-only only"
}

test_spawn_refuses_a_worker_without_a_sailor() {
  local id=pv-nosailor out status
  make_spawn_case nosailor "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --mode local-only --yolo off --harness opencode --model anthropic/claude-sonnet-5)
  status=$?
  assert_refused_spawn "$id" "$status" "$out" "error: the Privateer quarantine requires --sailor <name>" "an OpenCode worker without a sailor"
  pass "a Privateer home refuses an OpenCode worker that names no sailor"
}

test_spawn_refuses_a_raw_launch_command() {
  local id=pv-raw out status
  make_spawn_case raw "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --mode local-only --yolo off 'claude --dangerously-skip-permissions')
  status=$?
  assert_refused_spawn "$id" "$status" "$out" "error: the Privateer quarantine refuses a raw launch command" "a raw launch command"
  pass "a Privateer home refuses a raw launch command it cannot check"
}

test_spawn_refuses_a_secondmate() {
  local id=pv-sm out status smhome
  make_spawn_case secondmate "$id"
  smhome="$CASE_DIR/secondmate-home"
  mkdir -p "$smhome/bin" "$smhome/data"
  printf '# Firstmate\n' > "$smhome/AGENTS.md"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$smhome/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$smhome/.gitignore"
  git -C "$smhome" init -q -b main
  out=$(run_spawn "$id" "$smhome" --secondmate)
  status=$?
  assert_refused_spawn "$id" "$status" "$out" "error: the Privateer quarantine refuses a secondmate spawn" "a secondmate"
  pass "a Privateer home refuses to spawn a secondmate"
}

test_spawn_refuses_while_a_forbidden_file_exists() {
  local id=pv-forbidden out status
  make_spawn_case forbidden "$id"
  : > "$HOME_DIR/config/supervision-host"
  printf 'TYPESAFE_API_KEY=typed\n' > "$HOME_DIR/.env"
  out=$(run_spawn "$id" "$PROJ_DIR" --mode local-only --yolo off --harness opencode --model coder --sailor tiller)
  status=$?
  assert_refused_spawn "$id" "$status" "$out" "error: the Privateer quarantine refuses every spawn until this home satisfies it:" "a home with a forbidden file"
  assert_contains "$out" "error:   config/supervision-host exists" "the refusal must name the forbidden file"
  assert_contains "$out" "error:   .env sets TYPESAFE_API_KEY" "the refusal must name the forbidden key"
  pass "a Privateer home refuses every spawn while a forbidden file or key exists"
}

test_spawn_allows_a_local_only_sailor_with_a_cleared_environment() {
  local id=pv-ok out status launch
  make_spawn_case ok "$id"
  out=$(run_spawn "$id" "$PROJ_DIR" --mode local-only --yolo off --harness opencode --model coder --sailor tiller)
  status=$?
  expect_code 0 "$status" "a local-only sailor spawn must succeed in a Privateer home"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=opencode kind=ship mode=local-only yolo=off sailor=tiller sandbox=seatbelt" "the spawn must report the sailor and the sandbox"
  assert_grep "sailor=tiller" "$HOME_DIR/state/$id.meta" "the record must name the sailor"
  assert_grep "sandbox=seatbelt" "$HOME_DIR/state/$id.meta" "the record must name the sandbox"
  launch=$(cat "$LAUNCH_LOG")
  # The floor's expansions are the pane shell's to make, so the literal is meant.
  # shellcheck disable=SC2016
  assert_contains "$launch" '/usr/bin/env -i ${HOME+"HOME=$HOME"} ${PATH+"PATH=$PATH"}' "the launch must clear the environment down to the floor without config/launch-env-allowlist"
  assert_not_contains "$launch" 'ANTHROPIC' "no Anthropic name may appear in the launch"
  assert_not_contains "$launch" 'CLAUDE' "no Claude name may appear in the launch"
  # The worker command sits inside the floor's single-quoted `sh -c` string,
  # where every single quote reads as '\''.
  oc="$HOME_DIR/state/privateer/opencode"
  assert_contains "$launch" "export XDG_CONFIG_HOME=$(sq "$oc/config") XDG_DATA_HOME=$(sq "$oc/data") XDG_STATE_HOME=$(sq "$oc/state") XDG_CACHE_HOME=$(sq "$oc/cache") OPENCODE_DISABLE_AUTOUPDATE=$(sq 1) HTTP_PROXY=$(sq http://127.0.0.1:18080) HTTPS_PROXY=$(sq http://127.0.0.1:18080) http_proxy=$(sq http://127.0.0.1:18080) https_proxy=$(sq http://127.0.0.1:18080) GIT_SSH_COMMAND=" \
    "the launch must isolate the worker's OpenCode inside the home and route it through the egress proxy"
  assert_contains "$launch" ",\"autoupdate\":false,\"share\":\"disabled\"}'\\'' $(sq "$ROOT/bin/fm-sandbox-exec.sh") $(sq run)" \
    "the worker's OpenCode config must turn auto-update off and disable sharing, and the launch must run inside the sandbox"
  assert_contains "$launch" "$(sq --write) $(sq "$oc/data/opencode")" "the sandbox must allow the isolated OpenCode data directory"
  assert_contains "$launch" "$(sq --connect) $(sq http://127.0.0.1:18080) -- opencode" "the sandbox must allow only the egress proxy"
  assert_not_contains "$launch" "$(sq --connect) $(sq http://127.0.0.1:11234/v1)" "the sandbox must not reach the sailor except through the proxy"
  assert_not_contains "$launch" "no-mistakes/socket" "a local-only ship must not reach the shared pipeline socket"
  pass "a Privateer home launches a local-only sailor with a cleared environment, isolated OpenCode directories, and a sandbox that reaches only the egress proxy"
}

test_spawn_refuses_while_no_egress_proxy_runs() {
  local id=pv-noproxy out status
  make_spawn_case noproxy "$id"
  rm "$HOME_DIR/state/privateer/egress/port"
  out=$(run_spawn "$id" "$PROJ_DIR" --mode local-only --yolo off --harness opencode --model coder --sailor tiller)
  status=$?
  assert_refused_spawn "$id" "$status" "$out" "error: the Privateer quarantine refuses this spawn: the Privateer egress proxy is not running" "a spawn without the egress proxy"
  pass "a Privateer home refuses every spawn while its egress proxy is not running"
}

test_check_is_silent_without_the_flag
test_check_passes_a_clean_home
test_check_names_every_violation
test_check_requires_the_dispatch_file
test_endpoint_rule
test_launch_env_lives_inside_the_home
test_start_refuses_without_the_flag
test_start_refuses_with_a_forbidden_file
test_start_refuses_without_a_first_mate_line
test_start_passes_only_the_allowlist
test_start_refuses_when_the_proxy_cannot_bind
test_proxy_forwards_only_allowed_destinations
test_start_refuses_while_running
test_stop_refuses_with_work_in_flight_and_stops_an_idle_session
test_attach_refuses_without_a_session
test_spawn_refuses_a_claude_harness
test_spawn_refuses_pipeline_and_pr_delivery
test_spawn_refuses_a_worker_without_a_sailor
test_spawn_refuses_a_raw_launch_command
test_spawn_refuses_a_secondmate
test_spawn_refuses_while_a_forbidden_file_exists
test_spawn_allows_a_local_only_sailor_with_a_cleared_environment
test_spawn_refuses_while_no_egress_proxy_runs

echo "# all fm-privateer tests passed"
