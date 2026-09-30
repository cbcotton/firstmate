#!/usr/bin/env bash
# tests/fm-sandbox-exec.test.sh - bin/fm-sandbox-exec.sh: the Seatbelt profile
# it renders, and, where macOS sandbox-exec is available, that a command run
# inside it can write only where it was allowed and connect only where it was
# allowed. docs/configuration.md ("Sailor sandbox") owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sandbox-exec)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
SBX="$ROOT/bin/fm-sandbox-exec.sh"
SERVER_PID=
OUTSIDE=

cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  [ -z "$OUTSIDE" ] || rm -rf "$OUTSIDE"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

test_profile_denies_by_default_and_allows_back_exactly() {
  local out
  mkdir -p "$TMP_ROOT/render/wt"
  out=$("$SBX" profile --write "$TMP_ROOT/render/wt" --write-prefix "$TMP_ROOT/render/state/t1." \
    --deny-write "$TMP_ROOT/render/wt/.git/hooks" --connect http://127.0.0.1:11234/v1 \
    --connect http://stoker.example:8000/v1 --connect https://flint.local/v1 --unix-socket /tmp/fm-test.sock)
  assert_contains "$out" $'(allow default)\n(deny file-write*)' "writes must be denied before anything is allowed back"
  assert_contains "$out" "(subpath \"$TMP_ROOT/render/wt\")" "the copy must be writable"
  assert_contains "$out" $'(deny file-write*\n'"  (subpath \"$TMP_ROOT/render/wt/.git/hooks\")"$'\n)\n(allow file-write*\n'"  (regex #\"^$(printf '%s' "$TMP_ROOT/render/state/t1." | sed 's/[][\.^$*+?(){}|]/\\&/g')\")" \
    "a denied path must follow the directory allows, and an exact prefix, anchored and escaped, must follow the denies"
  assert_contains "$out" '(deny network-outbound)' "outbound network must be denied by default"
  assert_contains "$out" '(allow network-outbound (remote ip "localhost:11234"))' "a loopback endpoint must allow exactly its port"
  assert_contains "$out" '(allow network-outbound (remote ip "*:8000"))' "a remote endpoint can only be pinned to its port"
  assert_contains "$out" '(allow network-outbound (remote ip "*:443"))' "an https URL without a port means 443"
  assert_contains "$out" '(remote unix-socket (path-literal "/private/var/run/mDNSResponder"))' "DNS must stay reachable"
  assert_not_contains "$out" '(allow network-outbound (remote unix-socket))' "no blanket Unix-socket allow may appear"
  assert_equals '(allow process-exec (literal "/bin/ps") (with no-sandbox))' "$(printf '%s\n' "$out" | grep 'no-sandbox')" \
    "/bin/ps must be the only program that runs outside the sandbox"
  pass "the profile denies writes and network by default and allows back exactly what was asked"
}

test_unsafe_paths_and_endpoints_are_refused() {
  local out status
  out=$("$SBX" profile --write relative/dir 2>&1)
  status=$?
  expect_code 2 "$status" "a relative path must be refused"
  out=$("$SBX" profile --write '/tmp/a"b' 2>&1)
  status=$?
  expect_code 2 "$status" "a path with a quote must be refused"
  assert_contains "$out" "must not contain quotes" "quote refusal missing"
  out=$("$SBX" profile --connect stoker.example 2>&1)
  status=$?
  expect_code 2 "$status" "an endpoint without a port or scheme must be refused"
  pass "relative or quoted paths and portless endpoints are refused"
}

test_confinement_holds_where_sandbox_exec_runs() {
  local wt port out
  if ! "$SBX" available; then
    pass "confinement checks not run: sandbox-exec is not available on this machine"
    return 0
  fi
  wt="$TMP_ROOT/run/wt"
  mkdir -p "$wt/.git/hooks"
  # Outside every allowed directory, including this process's own $TMPDIR.
  OUTSIDE=$(mktemp -d /private/tmp/fm-sandbox-outside.XXXXXX)
  python3 -c '
import http.server, socketserver, sys
srv = socketserver.TCPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()' "$TMP_ROOT/port" >/dev/null 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 100); do
    [ -s "$TMP_ROOT/port" ] && break
    sleep 0.05
  done
  port=$(cat "$TMP_ROOT/port")
  out=$("$SBX" run --write "$wt" --deny-write "$wt/.git/hooks" --write-prefix "$wt/.git/hooks/exposed." -- /bin/sh -c "
    (echo in > '$wt/in.txt') 2>/dev/null && echo inside-allowed || echo inside-denied
    (echo x > '$wt/.git/hooks/pre-commit') 2>/dev/null && echo hook-allowed || echo hook-denied
    (echo s > '$wt/.git/hooks/exposed.status') 2>/dev/null && echo exposed-allowed || echo exposed-denied
    (echo out > '$OUTSIDE/escaped.txt') 2>/dev/null && echo outside-allowed || echo outside-denied
    curl -s -m 3 -o /dev/null 'http://127.0.0.1:$port/' && echo net-allowed || echo net-denied")
  assert_contains "$out" inside-allowed "a write inside an allowed directory must succeed"
  assert_contains "$out" hook-denied "a write under a denied path must fail even inside an allowed directory"
  assert_contains "$out" exposed-allowed "an exact prefix must stay writable even inside a denied path"
  assert_contains "$out" outside-denied "a write outside every allowed directory must fail"
  assert_contains "$out" net-denied "a connection to an endpoint not allowed must fail"
  [ ! -e "$OUTSIDE/escaped.txt" ] || fail "the outside write must leave no file behind"
  out=$("$SBX" run --connect "http://127.0.0.1:$port/" -- /bin/sh -c "curl -s -m 3 -o /dev/null 'http://127.0.0.1:$port/' && echo net-allowed || echo net-denied")
  assert_contains "$out" net-allowed "a connection to the allowed loopback port must succeed"
  pass "inside the sandbox a command writes only where allowed and connects only to the allowed port"
}

# Harness detection and the session lock walk the process ancestry with ps and
# parse it through here-documents, from inside the Privateer session's sandbox.
test_process_info_and_here_documents_work_where_sandbox_exec_runs() {
  local out
  if ! "$SBX" available; then
    pass "process-info checks not run: sandbox-exec is not available on this machine"
    return 0
  fi
  # Stock macOS Bash puts a here-document in /var/tmp whatever $TMPDIR says,
  # and falls back to the current directory, so run from one it cannot write.
  # shellcheck disable=SC2016 # expanded by the sandboxed shell
  out=$(cd / && "$SBX" run --write "$TMP_ROOT" -- /bin/bash -c '
    [ -n "$(ps -o comm= -p $$ 2>/dev/null)" ] && echo ps-allowed || echo ps-denied
    [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d " ")" = "$PPID" ] && echo ppid-read || echo ppid-unread
    x=$(cat 2>/dev/null <<EOF
here
EOF
)
    [ "$x" = here ] && echo heredoc-allowed || echo heredoc-denied
    (: > "/var/tmp/fm-sandbox-probe.$$") 2>/dev/null && echo vartmp-allowed || echo vartmp-denied
    rm -f "/var/tmp/fm-sandbox-probe.$$" 2>/dev/null
    /usr/bin/top -l 1 -n 0 >/dev/null 2>&1 && echo top-allowed || echo top-denied' 2>/dev/null)
  assert_contains "$out" ps-allowed "ps must read a process's name inside the sandbox"
  assert_contains "$out" ppid-read "ps must read a process's parent inside the sandbox"
  assert_contains "$out" heredoc-allowed "a stock macOS Bash here-document must work inside the sandbox"
  assert_contains "$out" vartmp-denied "only here-document files may be written in /var/tmp"
  assert_contains "$out" top-denied "no setuid program but ps may run outside the sandbox"
  pass "inside the sandbox ps reads process information and stock Bash here-documents work, while the rest of /var/tmp and every other setuid program stay out of reach"
}

test_profile_denies_by_default_and_allows_back_exactly
test_unsafe_paths_and_endpoints_are_refused
test_confinement_holds_where_sandbox_exec_runs
test_process_info_and_here_documents_work_where_sandbox_exec_runs

echo "# all fm-sandbox-exec tests passed"
