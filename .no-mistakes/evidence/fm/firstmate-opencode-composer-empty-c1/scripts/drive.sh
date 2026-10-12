#!/usr/bin/env bash
# Live driver: real opencode in a private tmux server; classify the real pane
# with the FIXED library (worktree) and the BASE library (4642c6a8) at
# several widths, empty and with a typed probe.
set -u
WT=$1 BASE=$2 OUT=$3 AGENT=${4:-}
SOCK=fm-nm-oc-$$
SHIM=$(mktemp -d); REAL=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL" "$SOCK" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH"
trap 'tmux kill-server 2>/dev/null; rm -rf "$SHIM"' EXIT
cls() { ( . "$1/bin/fm-tmux-lib.sh"; fm_tmux_composer_state "$2" ) ; }
tmux new-session -d -s oc -x 200 -y 50 -c "$WT"
if [ -n "$AGENT" ]; then tmux new-window -d -t oc: -n hx -c "${HELM:-$WT}" -- opencode --agent "$AGENT"
else tmux new-window -d -t oc: -n hx -c "$WT" -- opencode; fi
T=oc:hx
for i in $(seq 1 45); do v=$(cls "$WT" $T); [ "$v" = empty ] && break; sleep 1; done
step() {  # <label>
  sleep 2
  local f=$OUT/pane-$1.txt
  tmux capture-pane -p -t $T > "$f"
  printf '%-34s width=%-4s fixed=%-8s base=%s\n' "$1" "$(tmux display -p -t $T '#{pane_width}')" "$(cls "$WT" $T)" "$(cls "$BASE" $T)"
}
step wide-200-empty
for w in 74 60 48; do tmux resize-window -t $T -x $w -y 50; step narrow-$w-empty; done
tmux send-keys -t $T -l 'audit probe never submitted'; step narrow-48-typed
tmux resize-window -t $T -x 200 -y 50; step wide-200-typed
# clear the draft without submitting (ctrl-u / ctrl-c clears input in opencode)
tmux send-keys -t $T C-c; sleep 1; tmux resize-window -t $T -x 48 -y 50; step narrow-48-cleared
