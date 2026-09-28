#!/usr/bin/env bash
# Live lab drive: real fm-watch-arm.sh / fm-watch.sh / fm-inbox.sh on a disposable lab FM_HOME,
# production default poll interval (FM_POLL unset -> 15s).
set -u
ROOT=$1 LAB=$2
run() { env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$@"; }
ts() { date -u +%H:%M:%SZ; }
echo "[$(ts)] FM_HOME=$LAB  poll=default(15s)"
run FM_GATE_REFUSE_BYPASS=1 FM_WATCH_PREDECESSOR_ARM_PID=$$ "$ROOT/bin/fm-watch-arm.sh" > "$LAB/succ.out" 2>&1 &
succ=$!
for _ in $(seq 1 100); do w=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$LAB/succ.out"); [ -n "$w" ] && break; sleep 0.1; done
echo "[$(ts)] handling-successor arm pid=$succ -> $(head -1 "$LAB/succ.out")"
run FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-watch-arm.sh" > "$LAB/att.out" 2>&1 &   # the Claude Stop hook's attached arm
att=$!
sleep 3
echo "[$(ts)] Stop-hook arm pid=$att -> $(head -1 "$LAB/att.out")"
echo "[$(ts)] idling 35s (>2 poll intervals) with nothing queued ..."
sleep 35
kill -0 $att 2>/dev/null && echo "[$(ts)] Stop-hook arm still blocking (idle, no spurious wake): OK" || { echo "[$(ts)] arm exited early: $(cat "$LAB/att.out")"; }
t0=$(date +%s)
echo "[$(ts)] filing captain inbox note via bin/fm-inbox.sh note --source pinnace 'do number 1'"
run "$ROOT/bin/fm-inbox.sh" note --source pinnace "do number 1"
tail -1 "$LAB/state/.wake-queue" | sed 's/^/  queue row: /'
while kill -0 $att 2>/dev/null && [ $(( $(date +%s) - t0 )) -lt 60 ]; do sleep 0.2; done
t1=$(date +%s)
if kill -0 $att 2>/dev/null; then echo "[$(ts)] FAIL: Stop-hook arm still blocked after 60s"; else
echo "[$(ts)] Stop-hook arm returned after $((t1-t0))s with:"; sed 's/^/  | /' "$LAB/att.out"; fi
kill $succ $att 2>/dev/null; pkill -f "$LAB" 2>/dev/null; wait 2>/dev/null
echo "[$(ts)] done"
