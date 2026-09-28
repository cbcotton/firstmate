#!/usr/bin/env bash
# Live: real OpenCode + restricted profile + captain grants (via fm-permission-grant.sh)
# over git log/diff/show/shortlog and one exact touch. Scripted OpenAI-compatible model.
set -u
ROOT=$1; T=$(mktemp -d "${TMPDIR:-/tmp}/fm-grant-live.XXXXXX"); T=$(cd $T && pwd -P)
trap 'kill $SP 2>/dev/null; rm -rf "$T"' EXIT
home=$T/home; wt=$T/wt; mkdir -p $home/config $home/state $wt $T/xdg
printf 'restricted\n' > $home/config/opencode-permission-profile; : > $home/state/t1.status
git -C $wt init -q -b main; git -C $wt config user.email s@x.invalid; git -C $wt config user.name s
echo foo > $wt/a.txt; git -C $wt add a.txt; git -C $wt commit -qm init; echo bar > $wt/a.txt; git -C $wt commit -qam two
echo "captain: allow git log/diff/show/shortlog with any args, and touch granted.txt" > $T/words
for p in 'git log *' 'git diff *' 'git show *' 'git shortlog *' 'touch granted.txt'; do
  FM_HOME=$home $ROOT/bin/fm-permission-grant.sh grant --scope standing --permission bash --pattern "$p" --action allow --words-file $T/words --channel chat
done
sed -n '/^write_scripted_model/,/^}/p' $ROOT/tests/fm-opencode-restricted-live-e2e.test.sh > $T/fn.sh; . $T/fn.sh; write_scripted_model $T/model.py
jq -n --arg o "$T/out" '[
 {tool:"bash",args:{command:("git log -1 --format=%H --output="+$o+"-log.txt"),description:"log output"}},
 {tool:"bash",args:{command:("git diff --output="+$o+"-diff.txt HEAD~1"),description:"diff output"}},
 {tool:"bash",args:{command:("git show --output="+$o+"-show.txt HEAD"),description:"show output"}},
 {tool:"bash",args:{command:("git shortlog --output="+$o+"-shortlog.txt HEAD"),description:"shortlog output"}},
 {tool:"bash",args:{command:"git log -1 --format=GRANTED-LOG-%s --no-color",description:"plain log"}},
 {tool:"bash",args:{command:"touch granted.txt",description:"granted touch"}},
 {tool:"bash",args:{command:"touch notgranted.txt",description:"ungranted touch"}}
]' > $T/script.json
python3 $T/model.py $T/port $T/script.json $T/model.log & SP=$!
for _ in $(seq 100); do [ -s $T/port ] && break; sleep 0.05; done; port=$(cat $T/port)
perm=$(FM_HOME=$home $ROOT/bin/fm-opencode-permissions.sh compose t1)
echo "composed bash tail: $(jq -c '.bash|to_entries|map(select(.key|test("^git")))|map("\(.key)=\(.value)")' <<<"$perm")"
config=$(jq -cn --argjson perm "$perm" --arg url "http://127.0.0.1:$port/v1" '{autoupdate:false,share:"disabled",permission:$perm,provider:{sailor:{npm:"@ai-sdk/openai-compatible",name:"Scripted",options:{baseURL:$url},models:{scripted:{name:"scripted"}}}}}')
( cd $wt && XDG_CONFIG_HOME=$T/xdg OPENCODE_DB=$T/oc.db OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_CONFIG_CONTENT="$config" perl -e 'alarm shift; exec @ARGV' 120 opencode run --model sailor/scripted go ) </dev/null >$T/run.out 2>$T/run.err
echo "opencode $(opencode --version) run exit=$?"
fails=0
for k in log diff show shortlog; do if [ -e $T/out-$k.txt ]; then echo "FAIL: git $k --output wrote a file despite the guard"; fails=1; else echo "PASS: git $k --output denied (no file written) despite 'git $k *' grant"; fi; done
r=$(jq -r 'select(.results==5)|.last' $T/model.log|tail -1); case $r in *GRANTED-LOG-two*) echo "PASS: granted plain git log ran: ${r:0:80}";; *) echo "FAIL: plain git log result: ${r:0:200}"; fails=1;; esac
[ -e $wt/granted.txt ] && echo "PASS: granted exact 'touch granted.txt' ran" || { echo "FAIL: granted touch did not run"; fails=1; }
[ ! -e $wt/notgranted.txt ] && echo "PASS: ungranted 'touch notgranted.txt' denied" || { echo "FAIL: ungranted touch ran"; fails=1; }
echo "overall=$([ $fails = 0 ] && echo PASS || echo FAIL)"
