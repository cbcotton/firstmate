#!/usr/bin/env bash
cd "$WT"
for spec in "graded-scout-s1:tiller:qwen-coder" "plain-scout-s2:plain:qwen-coder"; do
  IFS=: read -r id s m <<<"$spec"
  bin/fm-brief.sh "$id" demo --scout >/dev/null 2>&1
  b="$FM_HOME/data/$id/brief.md"
  # fill placeholder sections so spawn's brief validation accepts it
  perl -0pi -e 's/\{TASK\}/Write one line saying hello into the report./g; s/\{FIRSTMATE_SPEC\}/lab/g' "$b" 2>/dev/null
  echo "\$ fm-spawn.sh $id \$LAB/projects/demo --scout --harness opencode --model $m --sailor $s"
  bin/fm-spawn.sh "$id" "$FM_HOME/projects/demo" --scout --harness opencode --model "$m" --sailor "$s"
  echo "rc=$?"
done
echo "--- task.dispatched events ---"
jq -c 'select(.event=="task.dispatched" and (.task|test("scout")))' "$FM_HOME/state/fleet-ledger.jsonl"
echo DONE
