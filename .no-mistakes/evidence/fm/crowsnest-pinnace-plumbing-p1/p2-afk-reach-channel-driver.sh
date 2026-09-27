#!/usr/bin/env bash
# P2 live driver: the pinnace as the recorded reach channel, driven through the
# real bin/fm-afk-launch.sh enter (the skill's entry point) and
# bin/fm-afk-contract.sh against disposable lab homes (FM_HOME only).
set -u
ROOT=$(pwd)
say() { printf '\n### %s\n' "$*"; }
newlab() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$d" >/dev/null || exit 1; printf '%s' "$d"; }
FM() { local home=$1; shift; env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$home" "$ROOT/bin/$1" "${@:2}"; }
run() { local home=$1; shift; printf '$ %s\n' "$*"; FM "$home" "$@"; printf '[exit %s]\n' "$?"; }

say "A. config/pinnace present: /afk entry records the pinnace and announces it"
A=$(newlab)
printf 'captain@example.com\n' > "$A/config/pinnace"
run "$A" fm-afk-launch.sh enter --words 'merge the windows fix when green' --expected-return 2026-09-28T08:00:00Z --spend 2
say "A1. the record on disk"
cat "$A/state/.afk-contract"
say "A2. field, validate, readback"
run "$A" fm-afk-contract.sh field reach_channels
run "$A" fm-afk-contract.sh validate
run "$A" fm-afk-contract.sh readback
say "A3. a bare /afk refresh on the pinnace home announces the recorded channel with no 'waits for your return' tail"
run "$A" fm-afk-launch.sh enter
say "A4. the return archives a pinnace record cleanly"
run "$A" fm-afk-launch.sh stop
ls "$A/state/afk-contracts/"
printf 'archived reach_channels: '; sed -n 's/^reach_channels: //p' "$A"/state/afk-contracts/*.afk-contract
rm -rf "$A"

say "B. no flag: entry is exactly the hold-for-return record and announcement as before"
B=$(newlab)
run "$B" fm-afk-launch.sh enter --words 'merge the windows fix when green'
run "$B" fm-afk-contract.sh field reach_channels
printf '$ grep -c pinnace state/.afk-contract\n'; grep -c pinnace "$B/state/.afk-contract"; printf '[exit %s]\n' "$?"
say "B1. a bare /afk with no words and no flag"
rm -f "$B/state/.afk-contract"
run "$B" fm-afk-launch.sh enter
rm -rf "$B"

say "C. a standing version-2 none record survives the flag appearing; refresh keeps it; new words re-record; flag removal keeps a pinnace record valid; unknown channel refused"
C=$(newlab)
run "$C" fm-afk-contract.sh enter --words 'merge it when green' >/dev/null
printf 'version: %s, reach_channels: %s\n' "$(FM "$C" fm-afk-contract.sh field version)" "$(FM "$C" fm-afk-contract.sh field reach_channels)"
printf 'captain@example.com\n' > "$C/config/pinnace"
run "$C" fm-afk-contract.sh validate
run "$C" fm-afk-launch.sh enter
printf 'after refresh with flag present, reach_channels: %s\n' "$(FM "$C" fm-afk-contract.sh field reach_channels)"
run "$C" fm-afk-launch.sh enter --words 'now the phone is on'
printf 'after new words, reach_channels: %s\n' "$(FM "$C" fm-afk-contract.sh field reach_channels)"
ls "$C/state/afk-contracts/"
rm -f "$C/config/pinnace"
run "$C" fm-afk-contract.sh validate
run "$C" fm-afk-contract.sh readback
sed -i.bak 's/^reach_channels: pinnace$/reach_channels: pager/' "$C/state/.afk-contract" && rm -f "$C/state/.afk-contract.bak"
run "$C" fm-afk-contract.sh validate
run "$C" fm-afk-launch.sh enter
rm -rf "$C"

say "D. presence is the switch: an empty config/pinnace still turns the channel on; a directory of that name does not"
D=$(newlab)
: > "$D/config/pinnace"
FM "$D" fm-afk-contract.sh enter >/dev/null 2>&1; printf 'empty flag file -> reach_channels: %s\n' "$(FM "$D" fm-afk-contract.sh field reach_channels)"
rm -rf "$D"
D=$(newlab)
mkdir "$D/config/pinnace"
FM "$D" fm-afk-contract.sh enter >/dev/null 2>&1; printf 'directory named pinnace -> reach_channels: %s\n' "$(FM "$D" fm-afk-contract.sh field reach_channels)"
rm -rf "$D"

say "E. a hand-written version 1 record with none (the older schema) still validates and reads back"
E=$(newlab)
cat > "$E/state/.afk-contract" <<'REC'
version: 1
entered: 2026-09-20T10:00:00Z
entered_epoch: 1789898400
expected_return: -
reach_channels: none
reach_announced: No phone channel is configured; anything that needs you waits for your return.
spend_max_concurrent_workers: 4
confirmed: 2026-09-20T10:00:00Z
confirmed_epoch: 1789898400
words: |-
  merge it when green
clauses:
refused:
merge_grants:
REC
run "$E" fm-afk-contract.sh validate
run "$E" fm-afk-contract.sh readback
rm -rf "$E"
printf '\nall lab homes removed\n'
