#!/usr/bin/env bash
L=$1
E="env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME=$L FM_MLX_SERVE_SERVERS=$L/servers.json"
echo 503 > $L/stub/health.code; echo "--- healthPath 503, /models 200: \$ fm-sailor.sh check tiller qwen-coder"; $E bin/fm-sailor.sh check tiller qwen-coder; echo "rc=$?"
echo 200 > $L/stub/health.code; echo 500 > $L/stub/models.code; echo "--- healthPath 200, /models 500: \$ fm-sailor.sh check tiller qwen-coder"; $E bin/fm-sailor.sh check tiller qwen-coder; echo "rc=$?"
echo 200 > $L/stub/models.code
