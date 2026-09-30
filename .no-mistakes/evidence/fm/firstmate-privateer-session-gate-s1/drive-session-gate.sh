#!/usr/bin/env bash
# Live driver: session gate of a sealed Privateer home (S1).
set -u
WT=${WT:?}; cd "$WT"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_GATE_REFUSE_BYPASS
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
PLAIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$PLAIN" >/dev/null
mkdir -p "$LAB/tmux"; TT=$(bin/fm-lab-home.sh tmux-dir "$LAB")
touch "$LAB/config/privateer"
. bin/fm-privateer-lib.sh
SOCK=$(fm_privateer_socket_name "$LAB")
trap 'TMUX_TMPDIR="$TT" tmux -L "$SOCK" kill-server 2>/dev/null; TMUX_TMPDIR="$TT" tmux -L fm-lab kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$PLAIN"' EXIT
export FM_HOME="$LAB"
snap() { (cd "$LAB" && find . -path ./tmux -prune -o -print | sort; find . -type f -not -path './tmux/*' -exec shasum {} + | sort); }
declare -a CMDS=(
 "fm-tasks-axi.sh list"
 "fm-brief.sh probe-task"
 "fm-send.sh fm-probe hello"
 "fm-control.sh stop fm-probe"
 "fm-captain-hold.sh open fm-probe"
 "fm-permission-grant.sh list"
 "fm-merge-local.sh fm-probe"
 "fm-teardown.sh fm-probe"
 "fm-spawn.sh fm-probe"
)
echo "== 1. OUTSIDE the session (no TMUX), sealed home $LAB =="
before=$(snap); fails=0
for c in "${CMDS[@]}"; do
  out=$(bin/$c 2>&1 </dev/null); rc=$?
  leak=no; case "$out" in *fm-privateer-*|*"$SOCK"*) leak=YES;; esac
  ok=FAIL; [ $rc -eq 2 ] && [[ "$out" == *"this is a sealed Privateer home; attach with bin/fm-privateer.sh attach, and never drive its session from outside"* ]] && [ $leak = no ] && ok=PASS
  [ $ok = PASS ] || fails=$((fails+1))
  printf '[%s] %-36s rc=%s socket-leak=%s\n      %s\n' "$ok" "$c" "$rc" "$leak" "$out"
done
after=$(snap); [ "$before" = "$after" ] && echo "[PASS] home tree byte-identical after all 9 refusals" || { echo "[FAIL] home changed"; diff <(echo "$before") <(echo "$after"); fails=$((fails+1)); }

echo; echo "== 2. OUTSIDE, TMUX pointing at some OTHER tmux socket (e.g. captain's own tmux) =="
out=$(TMUX="/private/tmp/tmux-501/default,123,0" bin/fm-tasks-axi.sh list 2>&1); rc=$?
[ $rc -eq 2 ] && echo "[PASS] fm-tasks-axi.sh list rc=$rc: $out" || { echo "[FAIL] rc=$rc $out"; fails=$((fails+1)); }

echo; echo "== 3. launch-env outside: refusal names no socket (the original leak) =="
out=$(bin/fm-privateer.sh launch-env 2>&1); rc=$?
case "$out" in *fm-privateer-*) echo "[FAIL] leaks socket rc=$rc: $out"; fails=$((fails+1));; *) echo "[PASS] rc=$rc: $out";; esac

echo; echo "== 4. INSIDE a real tmux server on the home's socket ($SOCK) =="
TMUX_TMPDIR="$TT" tmux -L "$SOCK" -f /dev/null new-session -d -s privateer -x 200 -y 50 -c "$WT" -e FM_HOME="$LAB" "bash --norc"
sleep 0.5
for c in "${CMDS[@]}"; do
  TMUX_TMPDIR="$TT" tmux -L "$SOCK" send-keys -t privateer "clear; echo \"TMUX=\$TMUX\" | sed 's/,.*//;s#.*/#TMUX socket basename: #'; bin/$c </dev/null 2>&1 | head -3; echo \"rc=\${PIPESTATUS[0]} END\"" Enter
  for i in $(seq 1 60); do sleep 0.25; TMUX_TMPDIR="$TT" tmux -L "$SOCK" capture-pane -p -t privateer | grep -q '^rc=.* END' && break; done
  pane=$(TMUX_TMPDIR="$TT" tmux -L "$SOCK" capture-pane -p -t privateer | sed '/^$/d')
  ok=PASS; case "$pane" in *"sealed Privateer home"*) ok=FAIL; fails=$((fails+1));; esac
  printf '[%s] inside: %s (gate passed; script ran its own logic)\n%s\n' "$ok" "$c" "$(echo "$pane" | sed 's/^/      /')"
done

echo; echo "== 5. Captain-side commands OUTSIDE the session stay usable =="
out=$(bin/fm-privateer.sh check 2>&1); rc=$?; case "$out" in *"sealed Privateer home"*) r=FAIL; fails=$((fails+1));; *) r=PASS;; esac
printf '[%s] fm-privateer.sh check rc=%s\n%s\n' $r $rc "$(echo "$out" | head -5 | sed 's/^/      /')"
out=$(bin/fm-sailor.sh list 2>&1); rc=$?; case "$out" in *"sealed Privateer home"*) r=FAIL; fails=$((fails+1));; *) r=PASS;; esac
printf '[%s] fm-sailor.sh list rc=%s\n%s\n' $r $rc "$(echo "$out" | head -5 | sed 's/^/      /')"
out=$(bin/fm-update.sh --help 2>&1); rc=$?; case "$out" in *"sealed Privateer home"*) r=FAIL; fails=$((fails+1));; *) r=PASS;; esac
printf '[%s] fm-update.sh --help rc=%s: %s\n' $r $rc "$out"
# attach from outside (from a separate lab tmux server's pane, which gives it a tty)
TMUX_TMPDIR="$TT" tmux -L "$SOCK" send-keys -t privateer "clear; echo PRIVATEER-FIRSTMATE-PANE" Enter; sleep 0.5
TMUX_TMPDIR="$TT" tmux -L fm-lab -f /dev/null new-session -d -s outside -x 120 -y 30 -c "$WT" "env -u TMUX FM_HOME=$LAB TMUX_TMPDIR=$TT bin/fm-privateer.sh attach; echo ATTACH-EXITED; sleep 30"
sleep 1.5
pane=$(TMUX_TMPDIR="$TT" tmux -L fm-lab capture-pane -p -t outside | sed '/^$/d')
clients=$(TMUX_TMPDIR="$TT" tmux -L "$SOCK" list-clients -F '#{client_session}' 2>&1)
if [[ "$pane" == *PRIVATEER-FIRSTMATE-PANE* ]] && [ "$clients" = privateer ]; then r=PASS; else r=FAIL; fails=$((fails+1)); fi
printf '[%s] fm-privateer.sh attach from outside: attached clients on session=%s; outside terminal shows:\n%s\n' $r "$clients" "$(echo "$pane" | sed 's/^/      /')"
TMUX_TMPDIR="$TT" tmux -L fm-lab kill-server 2>/dev/null
out=$(TMUX_TMPDIR="$TT" bin/fm-privateer.sh stop 2>&1); rc=$?
alive=$(TMUX_TMPDIR="$TT" tmux -L "$SOCK" has-session -t privateer 2>/dev/null && echo yes || echo no)
case "$out" in *"sealed Privateer home"*) r=FAIL; fails=$((fails+1));; *) [ $alive = no ] && r=PASS || { r=FAIL; fails=$((fails+1)); };; esac
printf '[%s] fm-privateer.sh stop from outside rc=%s session-still-alive=%s: %s\n' $r $rc $alive "$out"

echo; echo "== 6. Ordinary (non-Privateer) home: gate is a no-op =="
export FM_HOME="$PLAIN"
out=$(bin/fm-tasks-axi.sh list 2>&1); rc=$?; case "$out" in *"sealed Privateer home"*) r=FAIL; fails=$((fails+1));; *) r=PASS;; esac
printf '[%s] fm-tasks-axi.sh list rc=%s: %s\n' $r $rc "$(echo "$out"|head -3)"
out=$(bin/fm-brief.sh probe-task 2>&1); rc=$?; case "$out" in *"sealed Privateer home"*) r=FAIL; fails=$((fails+1));; *) r=PASS;; esac
printf '[%s] fm-brief.sh probe-task rc=%s: %s\n' $r $rc "$(echo "$out"|head -3)"
echo; echo "TOTAL FAILURES: $fails"
