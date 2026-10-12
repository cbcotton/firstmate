#!/usr/bin/env bash
# watch-leg.sh <lab> <tag>: run the real watcher once inside the lab tmux socket; it exits on its first wake.
L=$1; T=$2
TMUX_TMPDIR="$L/tmux" tmux -L fm-lab kill-session -t "w-$T" 2>/dev/null
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$L/tmux" tmux -L fm-lab new-session -d -s "w-$T" -c "$PWD" \
  -e FM_HOME="$L" -e FM_MLX_SERVE_SERVERS="$L/servers.json" -e FM_POLL=1 -e FM_SAILOR_HEALTH_SECS=1 \
  -e FM_CHECK_INTERVAL=999999 -e FM_HEARTBEAT=999999 -e FM_SECONDMATE_LIVENESS_SECS=99999999 \
  "bin/fm-watch.sh > $L/watch-$T.out 2> $L/watch-$T.err; echo \$? > $L/watch-$T.rc; sleep 600"
