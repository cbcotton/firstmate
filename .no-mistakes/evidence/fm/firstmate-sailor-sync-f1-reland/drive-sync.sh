#!/usr/bin/env bash
# Live drive of bin/fm-sailor.sh sync against a disposable lab home.
set -u
W=$1
run() { echo; echo "\$ $*"; "$@" 2>&1; echo "[exit $?]"; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB FM_MLX_SERVE_SERVERS=$LAB/servers.json
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
S="$W/bin/fm-sailor.sh"
cat > $LAB/config/crew-dispatch.json <<'J'
{"sailors":{"tiller":{"endpoint":"http://127.0.0.1:11234/v1","status":"live","models":["qwen-coder"]}},
 "rules":[{"when":"tiller only","use":{"harness":"opencode","sailor":"tiller","model":"qwen-coder"}}],
 "default":[{"harness":"claude","model":"claude-sonnet-5-5"}]}
J
jq -n '{servers:[{id:"mlx-serve",name:"MLX Serve",baseURL:"http://127.0.0.1:11234"},{id:"hf",name:"Hugging Face",baseURL:"https://router.huggingface.co"}]}' > $LAB/servers.json
REG=$LAB/sailors.json
jq -n --arg h "$LAB" '{schema:1,homes:{firstmate:$h,privateer:"/nonexistent"},privateer_first_mate:"helmsman",slots:{
 helmsman:{title:"Helmsman",server:"mlx-serve",model:"qwen-coder",grade:"specialist",facets:["helm"],capacity:2,homes:{firstmate:1,privateer:1},status:"live"},
 obliteratus:{title:"Obliteratus",server:"hf",model:"OBLITERATUS/Qwen3.8-27B-OBLITERATED:cheapest",grade:"expert",paid:true,auth_env:"HF_TOKEN",unlisted_models:true,capacity:2,homes:{firstmate:1,privateer:1},status:"placeholder"},
 spare:{title:"Spare"}}}' > $REG
echo "== 1. hand-managed home (no config/sailor-registry) is refused"
run "$S" sync "$REG" --home firstmate
printf '# slot registry\n%s\n' "$REG" > $LAB/config/sailor-registry
echo "== 2. dry run"
run "$S" sync "$REG" --home firstmate --dry-run
echo "== 2b. stale rule naming tiller -> rule dropped as retire would; sync"
run "$S" sync "$REG" --home firstmate
echo "-- resulting crew-dispatch.json"; cat $LAB/config/crew-dispatch.json; ls $LAB/config
echo "== 3. idempotent re-sync"
run "$S" sync "$REG" --home firstmate
echo "== 4. downstream: validate / status of placeholder"
run "$S" validate
run "$S" check obliteratus "OBLITERATUS/Qwen3.8-27B-OBLITERATED:cheapest"
echo "== 5. adversarial: rebind helmsman model while a task runs on it"
jq '.slots.helmsman.model="qwen-next"' $REG > $REG.t && mv $REG.t $REG
printf 'harness=opencode\nsailor=helmsman\nmodel=qwen-coder\n' > $LAB/state/busy-1.meta
cp $LAB/config/crew-dispatch.json $LAB/before.json
run "$S" sync "$REG" --home firstmate
cmp -s $LAB/before.json $LAB/config/crew-dispatch.json && echo "crew-dispatch.json unchanged after refusal"
rm $LAB/state/busy-1.meta
echo "== 6. adversarial: shares above capacity, bad grade, unknown server"
jq '.slots.helmsman.model="qwen-coder" | .slots.helmsman.homes.firstmate=5' $REG > $REG.t && mv $REG.t $REG; run "$S" sync "$REG" --home firstmate
jq '.slots.helmsman.homes.firstmate=1 | .slots.spare.grade="scout"' $REG > $REG.t && mv $REG.t $REG; run "$S" sync "$REG" --home firstmate
jq 'del(.slots.spare.grade) | .slots.obliteratus.server="nope"' $REG > $REG.t && mv $REG.t $REG; run "$S" sync "$REG" --home firstmate
jq '.slots.obliteratus.server="hf"' $REG > $REG.t && mv $REG.t $REG
echo "== 7. Privateer home: first mate follows helm slot; refuses non-helm"
rm -f $LAB/config/*.bak-*
jq --arg h "$LAB" '.homes={firstmate:"/nonexistent",privateer:$h}' $REG > $REG.t && mv $REG.t $REG
jq '.rules=[{when:"Any Privateer worker task",use:[{harness:"opencode",sailor:"helmsman",model:"qwen-coder"}]}] | .default=.rules[0].use' $LAB/config/crew-dispatch.json > $LAB/c.t && mv $LAB/c.t $LAB/config/crew-dispatch.json
printf '# first mate\nhelmsman/qwen-coder\n' > $LAB/config/privateer; printf 'opencode\n' > $LAB/config/crew-harness; : > $LAB/config/sailor-sandbox
run "$W/bin/fm-privateer.sh" check
jq '.slots.helmsman.model="qwen-next" | .rules=[] ' $REG > $REG.t && mv $REG.t $REG
jq '.rules=[{when:"Any Privateer worker task",use:[{harness:"opencode",sailor:"obliteratus",model:"OBLITERATUS/Qwen3.8-27B-OBLITERATED:cheapest"}]}] | .default=.rules[0].use' $LAB/config/crew-dispatch.json > $LAB/c.t && mv $LAB/c.t $LAB/config/crew-dispatch.json
run "$S" sync "$REG" --home privateer
echo "-- config/privateer"; cat $LAB/config/privateer
run "$W/bin/fm-privateer.sh" check
jq '.privateer_first_mate="obliteratus"' $REG > $REG.t && mv $REG.t $REG; run "$S" sync "$REG" --home privateer
jq '.privateer_first_mate="spare"' $REG > $REG.t && mv $REG.t $REG; run "$S" sync "$REG" --home privateer
echo "-- config/privateer after refusals"; cat $LAB/config/privateer
rm -rf "$LAB"; echo; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
