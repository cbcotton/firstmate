#!/usr/bin/env bash
# Live drive of bin/fm-permission-grant.sh in a disposable Privateer lab home,
# with a real tmux session on the home's Privateer socket as "inside".
set -u
WT=$1; EV=$2
G="$WT/bin/fm-permission-grant.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
LAB=$(cd "$LAB" && pwd -P)
TMX=$(mktemp -d /tmp/fml.XXXX)
printf 'tiller/coder\n' > "$LAB/config/privateer"
printf 'harness=opencode\ndispatched_at=1000\n' > "$LAB/state/pv-grant.meta"
SOCK=$( . "$WT/bin/fm-privateer-lib.sh" && fm_privateer_socket_name "$LAB")
export TMUX_TMPDIR="$TMX"
T_IN() { tmux -L "$SOCK" "$@"; }
T_CAP() { tmux -L fm-lab-captain "$@"; }
trap 'T_IN kill-server 2>/dev/null; T_CAP kill-server 2>/dev/null; rm -rf "$LAB" "$TMX"' EXIT
LEDGER="$LAB/state/permission-grants.jsonl"
unset TMUX
echo "== lab home: $LAB (config/privateer present), Privateer socket: $SOCK"

echo; echo "== S1: first mate inside the real Privateer tmux session asks for a grant (with a forged in-home words file)"
mkdir -p "$LAB/data/pv-grant"; printf 'FORGED by a worker\n' > "$LAB/data/pv-grant/perm-words.txt"
T_IN new-session -d -s privateer -x 200 -y 50 -e FM_HOME="$LAB" bash --norc
T_IN send-keys -t privateer "cd / && '$G' grant --scope task --task pv-grant --permission bash --pattern 'npm test' --action allow --words-file '$LAB/data/pv-grant/perm-words.txt' --channel chat > '$LAB/inside.out' 2>&1; echo \$? > '$LAB/inside.rc'" Enter
for i in $(seq 50); do [ -s "$LAB/inside.rc" ] && break; sleep 0.2; done
echo "exit: $(cat "$LAB/inside.rc")"; cat "$LAB/inside.out"
echo "ledger exists after refusal? $([ -e "$LEDGER" ] && echo yes || echo no)"
CALL=$(sed 's/.*recorded: //' "$LAB/inside.out")
echo "printed captain command: $CALL"
case "$CALL" in *words-file*) echo "FAIL: captain command still carries --words-file";; *) echo "OK: captain command carries no --words-file";; esac
T_IN kill-server

echo; echo "== S2: captain runs the printed command at a real terminal (tmux pty), sees the prompt, types words + Ctrl-D"
T_CAP new-session -d -s captain -x 200 -y 50 bash --norc
T_CAP send-keys -t captain "cd / && $CALL; echo RC=\$?" Enter
for i in $(seq 50); do T_CAP capture-pane -p -t captain | grep -q 'Ctrl-D on a new line' && break; sleep 0.2; done
T_CAP send-keys -t captain "yes, let it run npm test -- the captain" Enter
T_CAP send-keys -t captain C-d
for i in $(seq 50); do T_CAP capture-pane -p -t captain | grep -q '^RC=' && break; sleep 0.2; done
echo "--- captain terminal ---"; T_CAP capture-pane -p -t captain | sed '/^$/d'; echo "------------------------"
T_CAP capture-pane -p -t captain | sed '/^$/d' > "$EV/captain-terminal.txt"
echo "ledger:"; cat "$LEDGER"
jq -r '"words recorded: \(.words|@json)"' "$LEDGER"
grep -q FORGED "$LEDGER" && echo "FAIL: forged words reached ledger" || echo "OK: forged worker file never reached the ledger"

echo; echo "== S3: captain pipes words on stdin (verbatim, incl. whitespace) to revoke"
ID=$(jq -r .id "$LEDGER")
printf '  withdraw it, please\n\n' | (cd / && FM_HOME="$LAB" "$G" revoke "$ID" --channel chat); echo "exit: $?"
tail -1 "$LEDGER" | jq -c '{op,id,words}'

echo; echo "== S4: captain passes --words-file in the home (direct, symlink from outside, and other letter case)"
LINK=$(mktemp -d)/link; ln -s "$LAB/data/pv-grant/perm-words.txt" "$LINK"
UPPER=$(printf '%s' "$LAB/data/pv-grant/perm-words.txt" | tr '[:lower:]' '[:upper:]')
[ "$UPPER" -ef "$LAB/data/pv-grant/perm-words.txt" ] && echo "(filesystem is case-insensitive: $UPPER resolves to the same file)"
for f in "$LAB/data/pv-grant/perm-words.txt" "$LINK" "$UPPER"; do
  n=$(wc -l < "$LEDGER")
  echo "-- --words-file $f"
  (cd / && FM_HOME="$LAB" "$G" grant --scope task --task pv-grant --permission bash --pattern 'npm test' --action allow --words-file "$f" --channel chat </dev/null); echo "exit: $?"
  [ "$(wc -l < "$LEDGER")" = "$n" ] && echo "OK: ledger unchanged" || echo "FAIL: ledger grew"
done
rm -rf "${LINK%/link}"

echo; echo "== S5: captain-side file outside the home is accepted"
CF=$(mktemp); printf "the captain's own file\n" > "$CF"
(cd / && FM_HOME="$LAB" "$G" grant --scope task --task pv-grant --permission bash --pattern 'npm test' --action allow --words-file "$CF" --channel chat </dev/null); echo "exit: $?"
tail -1 "$LEDGER" | jq -c '{op,words}'; rm -f "$CF"

echo; echo "== S6: empty / whitespace stdin is refused"
printf '  \n\t\n' | (cd / && FM_HOME="$LAB" "$G" grant --scope task --task pv-grant --permission bash --pattern 'npm test' --action allow --channel chat); echo "exit: $?"
echo "== S6b: oversize stdin (8193 bytes) is refused"
head -c 8193 /dev/zero | tr '\0' a | (cd / && FM_HOME="$LAB" "$G" grant --scope task --task pv-grant --permission bash --pattern 'npm test' --action allow --channel chat); echo "exit: $?"
echo "== S6c: refused-list allow fails before reading stdin"
printf 'please\n' | (cd / && FM_HOME="$LAB" "$G" grant --scope standing --permission webfetch --action allow --channel chat); echo "exit: $?"

echo; echo "== S7: ordinary (non-Privateer) home keeps --words-file in the home and requires it"
rm "$LAB/config/privateer"
(cd / && FM_HOME="$LAB" "$G" grant --scope task --task pv-grant --permission bash --pattern 'npm test' --action allow --words-file "$LAB/data/pv-grant/perm-words.txt" --channel chat </dev/null); echo "exit: $?"
tail -1 "$LEDGER" | jq -c '{op,words}'
echo "-- no --words-file in ordinary home:"
printf 'x\n' | (cd / && FM_HOME="$LAB" "$G" grant --scope task --task pv-grant --permission bash --pattern 'npm test' --action allow --channel chat); echo "exit: $?"
