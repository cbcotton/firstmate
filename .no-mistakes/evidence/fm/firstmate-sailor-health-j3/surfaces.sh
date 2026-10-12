#!/usr/bin/env bash
# surfaces.sh <lab> <label>: show every sailor-health surface for the lab home.
LAB=$1; W=$PWD
E="env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=$LAB FM_MLX_SERVE_SERVERS=$LAB/servers.json"
echo "===== $2 ====="
echo "--- \$ bin/fm-sailor.sh health"; $E bin/fm-sailor.sh health
echo "--- \$ bin/fm-sailor.sh status --all"; $E bin/fm-sailor.sh status --all
echo "--- \$ bin/fm-fleet-snapshot.sh --json | jq .sailors"; $E bin/fm-fleet-snapshot.sh --json 2>/dev/null | jq -c '.sailors'
echo "--- \$ bin/fm-bearings-snapshot.sh --json | jq .sailors"; $E bin/fm-bearings-snapshot.sh --json 2>/dev/null | jq -c '.sailors'
echo "--- \$ bin/fm-bearings-snapshot.sh (TOON, sailors rows)"; $E bin/fm-bearings-snapshot.sh 2>/dev/null | grep -A3 '^sailors'
