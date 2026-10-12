#!/usr/bin/env bash
# drive.sh <launcher> <label>: real Privateer session (real sandbox-exec + tmux, stub first mate),
# a worker pane plants a commondir redirect with core.fsmonitor, then the captain runs git outside.
set -u
L=$1; LABEL=$2
ROOT=$(cd "$(dirname "$L")/.." && pwd)
. "$ROOT/tests/fixtures.sh"
W=$(mktemp -d "${DRIVE_BASE}/w.XXXX"); W=$(cd "$W" && pwd -P)
home="$W/home"; mkdir -p "$home"/{config,state,data,projects}
printf 'tiller/coder\n' > "$home/config/privateer"; printf 'opencode\n' > "$home/config/crew-harness"; : > "$home/config/sailor-sandbox"
fm_git_init_commit "$home"; mkdir -p "$home/docs"; cp -R "$ROOT/docs/privateer" "$home/docs/privateer"
proj="$home/projects/proj"; fm_git_init_commit "$proj"
mkdir -p "$W/sailor/v1"; printf '{"data":[{"id":"coder"}]}\n' > "$W/sailor/v1/models"
( cd "$W/sailor" && exec python3 -u -m http.server 0 --bind 127.0.0.1 ) > "$W/sailor.log" 2>&1 & spid=$!
for _ in $(seq 100); do port=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$W/sailor.log"|head -1); [ -n "$port" ] && break; sleep .1; done
jq -n --arg e "http://127.0.0.1:$port/v1" '{sailors:{tiller:{title:"Tiller",endpoint:$e,status:"live",models:["coder"]}},default:{harness:"opencode",sailor:"tiller",model:"coder"}}' > "$home/config/crew-dispatch.json"
evil="$home/state/evil"; marker="$W/PWNED-outside-sandbox"
cat > "$W/window" <<SH
#!/bin/sh
# worker: build an evil common dir and try to point the clone and checkout at it
cp -R '$proj/.git' '$evil' && git config -f '$evil/config' core.fsmonitor 'touch $marker; false'
r=""
( echo '$evil' > '$proj/.git/commondir' ) 2>/dev/null && r="\$r proj-commondir-written" || r="\$r proj-commondir-DENIED"
( echo '$evil' > '$home/.git/commondir' ) 2>/dev/null && r="\$r home-commondir-written" || r="\$r home-commondir-DENIED"
# ordinary Git work in the checkout still goes through
echo hi > '$home/worker.txt'; git -C '$home' add worker.txt && git -C '$home' -c user.name=w -c user.email=w@x commit -qm worker && r="\$r checkout-commit-ok" || r="\$r checkout-commit-FAILED"
echo "\$r" > '$W/probe'
SH
printf '#!/bin/sh\ntmux new-window -d %q\nexec sleep 60\n' "$W/window" > "$W/primary"; chmod +x "$W/window" "$W/primary"
out=$(env -u NO_MISTAKES_GATE FM_TEST_SEAM=1 FM_PRIVATEER_PRIMARY="$W/primary" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$L" start 2>&1); st=$?
for _ in $(seq 300); do [ -e "$W/probe" ] && break; sleep .1; done
env -u NO_MISTAKES_GATE FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$L" stop >/dev/null 2>&1; kill $spid 2>/dev/null
echo "== [$LABEL] launcher: $L  start exit=$st"
echo "worker pane result:$(cat "$W/probe" 2>/dev/null)"
echo "captain (outside sandbox) runs: git -C projects/proj status"
git -C "$proj" status --short >/dev/null 2>&1
echo "clone common dir now: $(git -C "$proj" rev-parse --path-format=absolute --git-common-dir)"
[ -e "$marker" ] && echo "RESULT: fsmonitor from worker-planted config RAN outside the sandbox (redirect open)" || echo "RESULT: no worker code ran; Git still uses the clone's own config and hooks"
rm -rf "$W"
