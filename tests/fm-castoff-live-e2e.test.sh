#!/usr/bin/env bash
# Live guard for the phone mirror's writer (bin/fm-castoff.sh): each INSTALLED
# primary harness with a writer (Claude and Cursor) runs one real prompt in a
# fixture primary checkout that carries this repo's tracked castoff
# registrations with the mirror on, and bin/fm-inbox.sh receipts must serve
# that turn's final message, stamped captain, and never the captain's prompt.
# The writer reads vendor hook payloads, so only the real harness can prove it.
# Opt-in because it submits prompts:
#
#   FM_CASTOFF_LIVE_E2E=1 tests/fm-castoff-live-e2e.test.sh
#
# FM_CASTOFF_LIVE_HARNESSES (default "claude cursor") narrows the set. An
# absent harness is reported, never passed over silently, and a run that
# checked no harness fails. Claude also runs a turn it starts itself (its
# Stop-hook rewake, submitted as a prompt), which must be stamped operational.
# Every harness runs in a private tmux server.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CASTOFF_LIVE_E2E jq tmux python3

HARNESSES=${FM_CASTOFF_LIVE_HARNESSES:-claude cursor}
LAB=$(fm_test_tmproot fm-castoff-live)
SOCKET="fmco-$$"
PROMPT='Reply with exactly the word castoff-ok and nothing else.'
CHECKED=0
ABSENT=

cleanup() {
  local harness
  for harness in claude cursor; do
    tmux -L "$SOCKET-$harness" kill-server >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TMUX TMUX_PANE

# A primary checkout carrying only the tracked castoff registrations, with the
# mirror on, so no other hook of this repo runs in it.
make_primary() {  # <name>
  local root="$LAB/$1"
  mkdir -p "$root/state" "$root/config" "$root/.claude" "$root/.cursor"
  git init -q "$root"
  : > "$root/AGENTS.md"
  ln -s "$ROOT/bin" "$root/bin"
  FM_HOME="$root" "$ROOT/bin/fm-castoff.sh" on >/dev/null || fail "could not turn the mirror on in the lab"
  jq '.hooks |= (with_entries(.value |= (map(.hooks |= map(select(.command | contains("fm-castoff.sh")))) | map(select(.hooks | length > 0)))) | with_entries(select(.value | length > 0))) | {hooks}' \
    "$ROOT/.claude/settings.json" > "$root/.claude/settings.json"
  jq '.hooks |= (with_entries(.value |= map(select(.command | contains("fm-castoff.sh")))) | with_entries(select(.value | length > 0)))' \
    "$ROOT/.cursor/hooks.json" > "$root/.cursor/hooks.json"
  printf '%s\n' "$root"
}

# "<turn>|<body>" per mirrored message the pinnace would be served.
mirrored() {  # <root>
  FM_HOME="$1" "$ROOT/bin/fm-inbox.sh" receipts --all-mate 2>/dev/null \
    | python3 -c 'import json,sys
for r in json.load(sys.stdin)["mate"]:
    print("%s|%s" % (r["turn"], r["body"].replace("\n", " ")))'
}

has() {  # <root> <turn> <fixed text>
  mirrored "$1" | grep -F -- "$2|" | grep -F -- "$3" >/dev/null
}

wait_for() {  # <root> <turn> <text> <seconds>
  local i=0
  while [ "$i" -lt "$(( $4 * 2 ))" ]; do
    has "$1" "$2" "$3" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

check() {  # <harness> <version> <root>
  has "$3" captain castoff-ok \
    || fail "$1 $2: the mirror did not serve the final message as a captain turn: $(mirrored "$3")"
  ! mirrored "$3" | grep -F -- "$PROMPT" >/dev/null \
    || fail "$1 $2: the captain's own prompt was mirrored: $(mirrored "$3")"
  printf 'ok - %s %s: the tracked registrations mirrored the final message, stamped captain, and not the prompt\n' "$1" "$2"
  CHECKED=$((CHECKED + 1))
}

# The harness process records its own pid as the session lock, then execs the
# harness, so the lock holder is the harness that fires the hooks.
LOCKED_EXEC='printf "%s\n" "$$" > state/.lock; exec "$@"'

# Claude runs interactively with one extra Stop hook that rewakes the session
# once, so the guard also proves a harness-started turn is stamped operational.
run_claude() {
  local root
  root=$(make_primary claude)
  cat > "$root/rewake-once.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
dir=$(cd "$(dirname "$0")" && pwd)
[ ! -e "$dir/rewake.done" ] || exit 0
: > "$dir/rewake.done"
sleep 2
echo "lab rewake: reply with exactly the word castoff-rewake-ok" >&2
exit 2
SH
  chmod +x "$root/rewake-once.sh"
  jq '.hooks.Stop += [{hooks: [{type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/rewake-once.sh", asyncRewake: true, timeout: 60}]}]' \
    "$root/.claude/settings.json" > "$root/.claude/settings.json.tmp" && mv "$root/.claude/settings.json.tmp" "$root/.claude/settings.json"
  REWAKE_WANTED=castoff-rewake-ok run_interactive claude claude --model haiku --dangerously-skip-permissions
}

# An interactive session in a private tmux server: answer a trust prompt when
# one appears, type the prompt, and wait for the mirrored message.
run_interactive() {  # <harness> <command> [arguments...]
  local harness=$1 command=$2 root version i screen
  shift 2
  version=$("$command" --version 2>/dev/null | head -n 1)
  root="$LAB/$harness"
  [ -d "$root" ] || root=$(make_primary "$harness")
  tmux -L "$SOCKET-$harness" new-session -d -s "$harness" -x 200 -y 50 -c "$root" \
    "sh -c '$LOCKED_EXEC' sh $command $*" || fail "$harness $version: the tmux session did not start"
  i=0
  while [ "$i" -lt 60 ]; do
    screen=$(tmux -L "$SOCKET-$harness" capture-pane -p -t "$harness" 2>/dev/null)
    case "$screen" in
      *'[a] Trust this workspace'*) tmux -L "$SOCKET-$harness" send-keys -t "$harness" a; sleep 3 ;;
      *'Yes, I trust this folder'*|*'Trust all and continue'*)
        tmux -L "$SOCKET-$harness" send-keys -t "$harness" Down; sleep 0.5; tmux -L "$SOCKET-$harness" send-keys -t "$harness" Enter; sleep 3 ;;
      *'1. Yes, continue'*) tmux -L "$SOCKET-$harness" send-keys -t "$harness" Enter; sleep 3 ;;
      *'bypass permissions on'*) break ;;
      *'Do you trust the contents of this directory'*) tmux -L "$SOCKET-$harness" send-keys -t "$harness" y; sleep 3 ;;
      *'Plan, search, build'*) break ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  sleep 3
  tmux -L "$SOCKET-$harness" send-keys -t "$harness" -l "$PROMPT"
  sleep 1
  tmux -L "$SOCKET-$harness" send-keys -t "$harness" Enter
  if ! wait_for "$root" captain castoff-ok 180; then
    tmux -L "$SOCKET-$harness" capture-pane -p -t "$harness" > "$LAB/$harness.screen" 2>/dev/null || true
  fi
  if [ -n "${REWAKE_WANTED:-}" ]; then
    wait_for "$root" "" "$REWAKE_WANTED" 120 \
      || fail "$harness $version: the harness-started turn never ran, so the guard proved nothing about it"
    has "$root" operational "$REWAKE_WANTED" \
      || fail "$harness $version: a turn the harness started itself was not stamped operational: $(mirrored "$root")"
    printf 'ok - %s %s: a turn the harness started itself was stamped operational\n' "$harness" "$version"
  fi
  tmux -L "$SOCKET-$harness" kill-session -t "$harness" >/dev/null 2>&1 || true
  check "$harness" "$version" "$root"
}

for harness in $HARNESSES; do
  case "$harness" in
    claude) bin=$harness ;;
    cursor) bin=cursor-agent ;;
    *) fail "unknown harness in FM_CASTOFF_LIVE_HARNESSES: $harness" ;;
  esac
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'absent - %s is not installed, so its phone-mirror writer was not checked\n' "$harness"
    ABSENT="$ABSENT $harness"
    continue
  fi
  case "$harness" in
    claude) run_claude ;;
    cursor) run_interactive cursor cursor-agent ;;
  esac
done

[ "$CHECKED" -gt 0 ] || fail "no installed harness was checked (absent:${ABSENT:- none})"
pass "castoff live: $CHECKED harness(es) proved their writers${ABSENT:+; absent:$ABSENT}"
