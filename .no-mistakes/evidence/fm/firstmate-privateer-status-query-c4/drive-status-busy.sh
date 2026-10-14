#!/usr/bin/env bash
# Live drive of `status` while the real OpenCode first mate is mid-turn on a local model.
set -u
WT=$1; cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-scratch.XXXXXX")
export TMUX_TMPDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"; touch "$LAB/config/privateer"
SOCK=$(. bin/fm-privateer-lib.sh; fm_privateer_socket_name "$LAB")
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$SCRATCH"; }
trap cleanup EXIT
tmux -L "$SOCK" new-session -d -s privateer -n firstmate -x 160 -y 48 -c "$SCRATCH" "opencode"
sleep 12
echo "\$ bin/fm-privateer.sh status   # before any prompt"; bin/fm-privateer.sh status; echo "[exit $?]"
# The test driver (not status) submits a turn to the local model.
tmux -L "$SOCK" send-keys -t privateer:firstmate Tab
sleep 1
tmux -L "$SOCK" send-keys -t privateer:firstmate -l "Without using any tools, write the numbers from 1 to 300 in English words, one per line."
sleep 1; tmux -L "$SOCK" send-keys -t privateer:firstmate Enter
seen_busy=0
for i in $(seq 1 40); do
  sleep 2
  out=$(bin/fm-privateer.sh status)
  echo "t+$((i*2))s: $(echo $out)"
  case "$out" in *"turn busy"*) seen_busy=1; tmux -L "$SOCK" capture-pane -p -t privateer:firstmate | grep -v '^[[:space:]]*$' | tail -8 > /tmp/.fm-busy-pane.$$ ;; esac
  [ "$seen_busy" = 1 ] && case "$out" in *"turn idle"*) break ;; esac
done
if [ -s /tmp/.fm-busy-pane.$$ ]; then echo "--- pane footer during a busy read:"; cat /tmp/.fm-busy-pane.$$; rm -f /tmp/.fm-busy-pane.$$; fi
echo "--- final pane footer:"; tmux -L "$SOCK" capture-pane -p -t privateer:firstmate | grep -v '^[[:space:]]*$' | tail -6
