#!/usr/bin/env bash
# P1 live driver: note provenance on the captain-note plane, driven through the
# real bin/fm-inbox.sh against a disposable lab home (FM_HOME only, no overrides).
set -u
ROOT=$(pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
INBOX() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" "$ROOT/bin/fm-inbox.sh" "$@"; }
say() { printf '\n### %s\n' "$*"; }
run() { printf '$ fm-inbox.sh %s\n' "$*"; INBOX "$@"; printf '[exit %s]\n' "$?"; }

say "1. the pinnace queues an order with provenance (request-id as the plan prescribes)"
run note --source pinnace --meta node=mac.home --meta login=captain@example.com --request-id pinnace:0d3f4c1a --json "merge the windows fix when green"
ID1=$(ls "$LAB/state/inbox"/*.note | head -1 | xargs -I{} basename {} .note)
say "1a. the durable record ($ID1.note) carries source, node, and login headers above the body"
cat "$LAB/state/inbox/$ID1.note"
say "1b. receipts return source=pinnace and the unchanged body"
run receipts
say "1c. a retry of the same request id replays the original note with its source intact"
run note --source pinnace --meta node=mac.home --meta login=captain@example.com --request-id pinnace:0d3f4c1a --json "merge the windows fix when green"
printf 'notes on disk: %s\n' "$(ls "$LAB/state/inbox"/*.note | wc -l | tr -d ' ')"
say "1d. the wake queue holds exactly one inbox wake for it"
grep -c 'inbox:' "$LAB/state/.wake-queue"
grep 'inbox:' "$LAB/state/.wake-queue"

say "2. body on stdin, the way the pinnace server sends it"
printf 'What is the fleet doing right now?\n' | INBOX note --source pinnace --meta node=phone --meta login=captain@example.com --json -
printf '[exit %s]\n' "$?"
ID2=$(ls -t "$LAB/state/inbox"/*.note | head -1 | xargs -I{} basename {} .note)
sed -n '1,/^--$/p' "$LAB/state/inbox/$ID2.note"

say "3. a plain terminal note keeps the default source=text and no extra headers"
run note "typed at the desk"
ID3=$(ls -t "$LAB/state/inbox"/*.note | head -1 | xargs -I{} basename {} .note)
sed -n '1,/^--$/p' "$LAB/state/inbox/$ID3.note"

say "4. human list and drain output print only the id and the body (no source header)"
run list
run drain

say "5. adversarial: malformed source tokens and forged or malformed meta are refused and write nothing"
before=$(ls "$LAB/state/inbox"/*.note | wc -l | tr -d ' ')
run note --source 'pin nace' --json "nope"
run note --source '../x' --json "nope"
run note --source '' --json "nope"
run note --source "$(printf 'pinnace\nid=forged')" --json "nope"
run note --source 'pinnace;rm' --json "nope"
run note --source pinnace --meta 'source=forged' --json "nope"
run note --source pinnace --meta 'id=forged' --json "nope"
run note --source pinnace --meta 'at=1999' --json "nope"
run note --source pinnace --meta 'announce_marker=0' --json "nope"
run note --source pinnace --meta 'request_id=x' --json "nope"
run note --source pinnace --meta 'novalue' --json "nope"
run note --source pinnace --meta 'node=' --json "nope"
run note --source pinnace --meta '=value' --json "nope"
run note --source pinnace --meta 'bad key=x' --json "nope"
run note --source pinnace --meta "$(printf 'node=phone\nid=forged')" --json "nope"
run note --source pinnace --meta "$(printf 'node=phone\rid=forged')" --json "nope"
run note --source --json "nope"
run note --meta --json "nope"
after=$(ls "$LAB/state/inbox"/*.note | wc -l | tr -d ' ')
printf 'notes before refusals: %s, after: %s\n' "$before" "$after"
printf 'inbox wakes after refusals: %s\n' "$(grep -c 'inbox:' "$LAB/state/.wake-queue")"

say "6. edge: a value may itself contain '=' and a key may use dots and dashes"
run note --source pinnace --meta 'tailnet.node-name=mac=home' --json "edge"
ID6=$(ls -t "$LAB/state/inbox"/*.note | head -1 | xargs -I{} basename {} .note)
sed -n '1,/^--$/p' "$LAB/state/inbox/$ID6.note"

say "7. --help documents the provenance flags"
run note --help
printf '$ fm-inbox.sh --help | grep -n "source\\|--meta"\n'
INBOX --help | grep -n 'source\|--meta'

say "8. the first mate answers the pinnace note with reply, then acknowledges; receipts show both"
run reply "$ID1" "Merged the windows fix; it was green at its live head."
run drain --ack "$ID1"
run receipts

say "teardown"
rm -rf "$LAB"
printf 'lab removed: %s\n' "$LAB"
