#!/usr/bin/env bash
# Live drive of fm-sailor.sh sync against two disposable lab homes sharing one slot registry.
set -u
W=/Users/cotton/.no-mistakes/worktrees/e74e4e411ceb/01M4XA251CYKP10V5MCTFZSRVQ
S="$W/bin/fm-sailor.sh"
FMH=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); PVH=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); MLX=$(mktemp -d "${TMPDIR:-/tmp}/fm-mlx.XXXXXX")
trap 'rm -rf "$FMH" "$PVH" "$MLX"' EXIT
"$W/bin/fm-lab-home.sh" create "$FMH" >/dev/null; "$W/bin/fm-lab-home.sh" create "$PVH" >/dev/null
export FM_MLX_SERVE_SERVERS="$MLX/servers.json"
run() { echo; echo "\$ [$1] fm-sailor.sh ${*:2}"; h=$FMH; [ "$1" = privateer ] && h=$PVH
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$h" "$S" "${@:2}" 2>&1; echo "[exit $?]"; }
jq -n '{servers:[{id:"mlx-serve",name:"MLX Serve",baseURL:"http://127.0.0.1:11234"},{id:"bonsai-1",name:"Bonsai",baseURL:"http://127.0.0.1:11310/"},{id:"hf-inference",name:"Hugging Face",baseURL:"https://router.huggingface.co"}]}' > "$MLX/servers.json"
# Both homes start with identical hand-kept copies (the problem the intent describes)
HAND='{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["qwen-coder"]},"bonsai-1":{"endpoint":"http://127.0.0.1:11310/v1","status":"live","models":["bonsai-2bit"]}},"rules":[{"when":"Any worker task","use":[{"harness":"opencode","sailor":"bonsai-1","model":"bonsai-2bit"}]}],"default":[{"harness":"claude","model":"claude-sonnet-5-5"}]}'
for h in "$FMH" "$PVH"; do echo "$HAND" | jq . > "$h/config/crew-dispatch.json"; printf '# slot registry\n%s\n' "$MLX/sailors.json" > "$h/config/sailor-registry"; done
jq '.default = .rules[0].use' "$PVH/config/crew-dispatch.json" > "$PVH/x" && mv "$PVH/x" "$PVH/config/crew-dispatch.json"
printf '# first mate\ntiller/qwen-coder\n' > "$PVH/config/privateer"; printf 'opencode\n' > "$PVH/config/crew-harness"; : > "$PVH/config/sailor-sandbox"
reg() { jq -n --arg f "$FMH" --arg p "$PVH" '{schema:1,homes:{firstmate:$f,privateer:$p},privateer_first_mate:"tiller",slots:{
 tiller:{title:"Tiller",server:"mlx-serve",model:"qwen-coder",grade:"specialist",facets:["helm"],capacity:2,homes:{firstmate:1,privateer:1},status:"live"},
 "bonsai-1":{title:"Bonsai 1",server:"bonsai-1",model:"bonsai-2bit",grade:"deckhand",capacity:3,homes:{firstmate:2,privateer:1},status:"live"},
 lookout:{title:"Lookout",server:"hf-inference",model:"OBLITERATUS/Qwen3.8-27B-OBLITERATED:cheapest",grade:"expert",paid:true,auth_env:"HF_TOKEN",unlisted_models:true,capacity:2,homes:{firstmate:1,privateer:1},status:"placeholder"},
 stoker:{title:"Stoker"},flint:{title:"Flint"},bosun:{title:"Bosun"}}}' | jq "${1:-.}" > "$MLX/sailors.json"; }
reg; cp "$MLX/sailors.json" "$MLX/sailors.orig"; cp "$MLX/servers.json" "$MLX/servers.orig"
echo "=== S1: dry-run both homes before applying (as MLX Serve Apply would) ==="
run firstmate sync "$MLX/sailors.json" --home firstmate --dry-run | tail -6
run privateer sync "$MLX/sailors.json" --home privateer --dry-run | tail -4
echo "dispatch unchanged after dry-run: $(echo "$HAND" | jq -S . | cmp -s - <(jq -S . "$FMH/config/crew-dispatch.json") && echo yes || echo NO)"
echo; echo "=== S2: apply to both homes from the one registry ==="
run firstmate sync "$MLX/sailors.json" --home firstmate
run privateer sync "$MLX/sailors.json" --home privateer
echo; echo "--- firstmate sailors ---"; jq -c '.sailors | to_entries[] | {(.key): .value}' "$FMH/config/crew-dispatch.json"
echo "--- privateer sailors ---"; jq -c '.sailors | to_entries[] | {(.key): .value}' "$PVH/config/crew-dispatch.json"
echo "blank slots (stoker/flint/bosun) absent in both: $(jq -r '[.sailors|has("stoker","flint","bosun")]|any|not' "$FMH/config/crew-dispatch.json" "$PVH/config/crew-dispatch.json" | paste -sd, -)"
run firstmate validate; run privateer validate
echo "\$ fm-privateer.sh check (privateer home)"; FM_HOME="$PVH" "$W/bin/fm-privateer.sh" check 2>&1; echo "[exit $?]"
echo "slot registry untouched: $(cmp -s "$MLX/sailors.orig" "$MLX/sailors.json" && echo yes || echo NO); servers.json untouched: $(cmp -s "$MLX/servers.orig" "$MLX/servers.json" && echo yes || echo NO); .env created: $(ls "$FMH/.env" "$PVH/.env" 2>/dev/null || echo none)"
echo; echo "=== S3: re-sync is a no-op ==="; run firstmate sync "$MLX/sailors.json" --home firstmate
echo; echo "=== S4: one swap in the registry reaches both homes; first mate follows its helm slot ==="
reg '.slots.tiller.model = "qwen-next"'
run firstmate sync "$MLX/sailors.json" --home firstmate | tail -3
run privateer sync "$MLX/sailors.json" --home privateer
echo "firstmate tiller models: $(jq -c '.sailors.tiller.models' "$FMH/config/crew-dispatch.json")  privateer tiller models: $(jq -c '.sailors.tiller.models' "$PVH/config/crew-dispatch.json")"
echo "--- privateer config/privateer ---"; cat "$PVH/config/privateer"
echo; echo "=== S5: hand edit in registry-managed home gets a note and is overwritten by next sync ==="
run firstmate set bonsai-1 --host "hand edit"
run firstmate sync "$MLX/sailors.json" --home firstmate | tail -2
echo "host after sync: $(jq -r '.sailors["bonsai-1"].host' "$FMH/config/crew-dispatch.json")"
echo; echo "=== S6 adversarial: invalid registries refused whole, nothing written ==="
cp "$FMH/config/crew-dispatch.json" "$MLX/fm.before"; cp "$PVH/config/crew-dispatch.json" "$MLX/pv.before"; cp "$PVH/config/privateer" "$MLX/pvf.before"
for f in '.slots.lookout.grade = "scout"' '.slots["bonsai-1"].homes.firstmate = 3' '.slots.tiller.server = "ghost"' '.slots.tiller.model = "qwen-next" | .slots.lookout.server = "mlx-serve" | .slots.lookout.model = null'; do
  reg ".slots.tiller.model = \"qwen-next\" | $f"; echo; echo "# registry edit: $f"; run firstmate sync "$MLX/sailors.json" --home firstmate; done
for f in '.privateer_first_mate = "bonsai-1"' '.privateer_first_mate = "stoker"' '.slots.tiller.status = "placeholder"'; do
  reg ".slots.tiller.model = \"qwen-next\" | $f"; echo; echo "# registry edit: $f"; run privateer sync "$MLX/sailors.json" --home privateer; done
reg '.slots.tiller.model = "qwen-next" | .slots.tiller.homes = {firstmate:1}'
echo; echo "# registry edit: privateer loses its share of tiller (still privateer_first_mate)"; run privateer sync "$MLX/sailors.json" --home privateer
echo; echo "# a running task on bonsai-1/bonsai-2bit while registry rebinds bonsai-1"
reg '.slots.tiller.model = "qwen-next" | .slots["bonsai-1"].model = "bonsai-3bit"'
printf 'harness=opencode\nsailor=bonsai-1\nmodel=bonsai-2bit\n' > "$FMH/state/busy-t1.meta"
run firstmate sync "$MLX/sailors.json" --home firstmate
rm "$FMH/state/busy-t1.meta"
echo; echo "# firstmate home with no config/sailor-registry (hand-managed)"; mv "$FMH/config/sailor-registry" "$MLX/x"; reg '.slots.tiller.model = "qwen-next"'
run firstmate sync "$MLX/sailors.json" --home firstmate; mv "$MLX/x" "$FMH/config/sailor-registry"
echo; echo "# wrong home key: firstmate home synced as privateer"; run firstmate sync "$MLX/sailors.json" --home privateer
echo; echo "refusals left files untouched: firstmate=$(cmp -s "$MLX/fm.before" "$FMH/config/crew-dispatch.json" && echo yes || echo NO) privateer=$(cmp -s "$MLX/pv.before" "$PVH/config/crew-dispatch.json" && echo yes || echo NO) config/privateer=$(cmp -s "$MLX/pvf.before" "$PVH/config/privateer" && echo yes || echo NO)"
