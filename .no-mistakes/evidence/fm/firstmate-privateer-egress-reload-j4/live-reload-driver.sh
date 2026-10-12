#!/usr/bin/env bash
# Live driver: a real Privateer session (real sandbox-exec, real tmux on a
# private socket dir, real egress proxy) in a disposable lab home, with a stub
# first mate; drives `fm-privateer.sh reload` from the captain's side and
# probes egress from a pane inside the sandbox.
set -u
WT=$1
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
TMUXD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
WORK=$(mktemp -d /tmp/fm-lab-work.XXXXXX)
say() { printf '\n### %s\n' "$*"; }
cleanup() {
  env -u NO_MISTAKES_GATE FM_HOME="$LAB" TMUX_TMPDIR="$TMUXD" FM_TEST_SEAM=1 bin/fm-privateer.sh stop >/dev/null 2>&1
  [ -n "${APID:-}" ] && kill "$APID" "$BPID" 2>/dev/null
  bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB" "$WORK"
}
trap cleanup EXIT
serve() { ( cd "$1" && exec python3 -u -m http.server 0 --bind 127.0.0.1 ) > "$2" 2>&1 & echo $!; }
port_of() { for _ in $(seq 100); do p=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$1" | head -1); [ -n "$p" ] && { echo "$p"; return; }; sleep 0.1; done; }
mkdir -p "$WORK/a/v1" "$WORK/b/v1"
printf '{"data":[{"id":"coder"}]}\n' > "$WORK/a/v1/models"
printf '{"data":[{"id":"coder"}]}\n' > "$WORK/b/v1/models"
APID=$(serve "$WORK/a" "$WORK/a.log"); BPID=$(serve "$WORK/b" "$WORK/b.log")
AP=$(port_of "$WORK/a.log"); BP=$(port_of "$WORK/b.log")
printf 'tiller/coder\n' > "$LAB/config/privateer"
printf 'opencode\n' > "$LAB/config/crew-harness"
: > "$LAB/config/sailor-sandbox"
jq -n --arg e "http://127.0.0.1:$AP/v1" '{sailors:{tiller:{title:"Tiller",endpoint:$e,status:"live",models:["coder"]}},default:{harness:"opencode",sailor:"tiller",model:"coder"}}' > "$LAB/config/crew-dispatch.json"
printf '#!/bin/sh\nexec sleep 100000\n' > "$WORK/primary"; chmod +x "$WORK/primary"
PV() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  FM_HOME="$LAB" TMUX_TMPDIR="$TMUXD" FM_TEST_SEAM=1 FM_PRIVATEER_PRIMARY="$WORK/primary" bin/fm-privateer.sh "$@" 2>&1; echo "[exit $?]"; }
EG="$LAB/state/privateer/egress"
SOCK=$(. bin/fm-privateer-lib.sh; fm_privateer_socket_name "$(cd "$LAB" && pwd -P)")
n=0
# probe: run a script in a new window of the real sandboxed session; print its output
probe() {
  n=$((n+1)); local out="$LAB/state/probe.$n"
  cat > "$WORK/p$n.sh" <<SH
#!/bin/sh
{ $1 ; } > '$out.tmp' 2>&1; mv '$out.tmp' '$out'
SH
  chmod +x "$WORK/p$n.sh"
  TMUX_TMPDIR="$TMUXD" tmux -L "$SOCK" new-window -d "$WORK/p$n.sh"
  for _ in $(seq 100); do [ -e "$out" ] && break; sleep 0.1; done
  cat "$out" 2>/dev/null || echo "(probe produced nothing)"
}
CURL='code() { /usr/bin/curl -sS -m 3 -o /dev/null -w "%{http_code}" "$1" 2>/dev/null; }'
reach() { probe "$CURL; echo \"sailor A (127.0.0.1:$AP) -> \$(code http://127.0.0.1:$AP/v1/models)\"; echo \"sailor B (127.0.0.1:$BP) -> \$(code http://127.0.0.1:$BP/v1/models)\""; }

say "S0: reload with no session running (captain)"; PV reload
say "start the real Privateer session"; PV start
echo "socket=$SOCK  proxy pid=$(cat "$EG/pid")  port=$(cat "$EG/port")"; PID0=$(cat "$EG/pid")
say "allow file written by start ($EG/allow)"; cat "$EG/allow"; ls -l "$EG/allow"
say "S1 before: egress from inside the sandbox (only A listed)"; reach
say "S2: reload with config unchanged"; PV reload
say "S3: captain adds sailor B to crew-dispatch.json and runs reload"
jq --arg e "http://127.0.0.1:$BP/v1" '.sailors.bravo={title:"Bravo",endpoint:$e,status:"live",models:["coder"]}' "$LAB/config/crew-dispatch.json" > "$WORK/d" && mv "$WORK/d" "$LAB/config/crew-dispatch.json"
PV reload
echo "proxy pid after reload: $(cat "$EG/pid") (was $PID0)"; ps -p "$PID0" -o pid=,command= | sed 's/^/still running: /'
say "S3 after: egress from inside the sandbox"; reach
say "S4: captain removes sailor A (endpoint) from crew-dispatch.json and runs reload"
jq '.sailors.tiller.endpoint="http://127.0.0.1:1/v1"' "$LAB/config/crew-dispatch.json" > "$WORK/d" && mv "$WORK/d" "$LAB/config/crew-dispatch.json"
PV reload
say "S4 after: egress from inside the sandbox"; reach
say "S5 adversarial: from inside the session try to rewrite the allowlist, move aside its directories, or run reload"
probe "echo 127.0.0.1:$AP >> '$EG/allow' && echo 'append allow: WRITTEN' || echo 'append allow: refused'
printf 'x\n' > '$EG/allow.evil' && echo 'create egress/allow.evil: WRITTEN' || echo 'create egress/allow.evil: refused'
for t in '$EG' '$LAB/state/privateer' '$LAB/state'; do mv \"\$t\" \"\$t.aside\" 2>/dev/null && echo \"mv \$t: MOVED\" || echo \"mv \$t: refused\"; done
cd '$WT' && bin/fm-privateer.sh reload; echo \"in-session reload exit=\$?\""
say "S5 after: allow file and egress unchanged"; cat "$EG/allow"; reach
say "proxy log (reload entries and A/B verdicts)"; jq -c 'select(.verdict|startswith("reload")) // select(.dest|test(":('"$AP|$BP"')"))' "$EG/log"
say "S6: stop, then reload refuses"; PV stop; PV reload
