#!/usr/bin/env bash
# Live drive of `fm-privateer.sh status` against a disposable Privateer lab home,
# a real tmux server on the session's derived socket running the real OpenCode TUI,
# and the real egress proxy process.
set -u
WT=$1
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
export TMUX_TMPDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"
touch "$LAB/config/privateer"
PS() { echo; echo "\$ FM_HOME=\$LAB bin/fm-privateer.sh $*"; bin/fm-privateer.sh "$@"; echo "[exit $?]"; }
SOCK=$(. bin/fm-privateer-lib.sh; fm_privateer_socket_name "$LAB")
snap() { (cd "$LAB" && find . -path ./tmux -prune -o -print0 | xargs -0 stat -f '%N %m %z' | sort); }
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null; [ -n "${PROXY:-}" ] && kill "$PROXY" 2>/dev/null; "$WT"/bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT

echo "=== 1. no session, no helpers"
PS status

echo; echo "=== 2. session running: real opencode TUI in privateer:firstmate on the home's socket"
tmux -L "$SOCK" new-session -d -s privateer -n firstmate -x 160 -y 48 -c "$WT" "opencode"
sleep 12
before_pane=$(tmux -L "$SOCK" capture-pane -p -t privateer:firstmate)
echo "--- pane (last 15 non-blank lines) before status:"; printf '%s\n' "$before_pane" | grep -v '^[[:space:]]*$' | tail -15
before_tree=$(snap)
PS status
PS status
after_pane=$(tmux -L "$SOCK" capture-pane -p -t privateer:firstmate)
after_tree=$(snap)
echo
[ "$before_tree" = "$after_tree" ] && echo "CHECK home tree unchanged by status (paths+mtime+ctime): yes" || { echo "CHECK home tree unchanged: NO"; diff <(echo "$before_tree") <(echo "$after_tree"); }
[ "$before_pane" = "$after_pane" ] && echo "CHECK first mate pane unchanged by status (nothing typed): yes" || echo "CHECK pane unchanged: NO"
echo "CHECK attached clients on the session socket: $(tmux -L "$SOCK" list-clients 2>/dev/null | wc -l | tr -d ' ')"

echo; echo "=== 3. session running, first mate pane inconclusive (blank pane)"
tmux -L "$SOCK" kill-server; sleep 1
tmux -L "$SOCK" new-session -d -s privateer -n firstmate -x 160 -y 48 "printf '\033[2J'; sleep 600"
sleep 1
PS status
tmux -L "$SOCK" kill-server; sleep 1

echo; echo "=== 4. session gone, real egress proxy left behind"
mkdir -p "$LAB/state/privateer/egress"; : > "$LAB/state/privateer/egress/allow"
python3 bin/fm-privateer-proxy.py "$LAB/state/privateer/egress/port" "$LAB/state/privateer/egress/log" "$LAB/state/privateer/egress/allow" &
PROXY=$!; echo "$PROXY" > "$LAB/state/privateer/egress/pid"
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$LAB/state/privateer/egress/port" ] && break; sleep 0.3; done
before_tree=$(snap)
PS status
after_tree=$(snap)
[ "$before_tree" = "$after_tree" ] && echo "CHECK home tree unchanged by status: yes" || echo "CHECK home tree unchanged: NO"
kill -0 "$PROXY" && echo "CHECK proxy still alive after status (status stops nothing): yes"

echo; echo "=== 5. adversarial: stale pid file naming an unrelated live process"
kill "$PROXY"; wait "$PROXY" 2>/dev/null; PROXY=
sleep 600 & DECOY=$!; echo "$DECOY" > "$LAB/state/privateer/egress/pid"; echo "$DECOY" > "$LAB/state/privateer/egress/records.pid"
PS status
kill "$DECOY"; rm -f "$LAB/state/privateer/egress/pid" "$LAB/state/privateer/egress/records.pid"

echo; echo "=== 6. after cleanup"
PS status

echo; echo "=== 7. guards"
PS status extra
rm "$LAB/config/privateer"
PS status
