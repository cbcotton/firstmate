#!/usr/bin/env bash
# fm-privateer-rulebook-check.sh - the one owner of the rules the Privateer
# helm's tracked sources must meet.
#
# bin/fm-privateer.sh renders the helm, the Privateer first mate's whole
# instruction surface, from these sources at every start:
#   docs/privateer/AGENTS.md                the rulebook
#   docs/privateer/agents/privateer.md      the OpenCode agent
#   docs/privateer/skills/<name>/SKILL.md   the helm's skills
# The first mate runs on a local model, so the rulebook stays small and shows
# exact command forms, and every form it shows must work. The check prints one
# line per violation and exits 1 on any:
#   - the rulebook or the agent file is missing;
#   - the rulebook is over 12,000 bytes, or a skill is over 6,000 bytes;
#   - a skill's frontmatter names no description, or a name that is not its
#     directory's or not lowercase words joined by single hyphens, as
#     OpenCode requires;
#   - the agent's skill permission does not deny "*" and allow exactly the
#     skills under docs/privateer/skills/;
#   - a bin/<name> that any of those files mentions is not in this checkout's
#     bin/;
#   - a command any of those files shows, meaning an inline code span or a
#     fenced code line that starts with bin/<name>, names a script that is not
#     executable, or does not parse as shell once each <placeholder> is read as
#     one word; parsing runs nothing.
# It prints nothing and exits 0 when every rule holds, and exits 2 on a usage
# error. bin/fm-lint.sh runs it on its default path.
#
# Usage:
#   fm-privateer-rulebook-check.sh               check this checkout
#   fm-privateer-rulebook-check.sh --root <dir>  check the checkout at <dir>
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
RULEBOOK_MAX=12000
SKILL_MAX=6000

usage() {
  echo "usage: fm-privateer-rulebook-check.sh [--root <dir>]" >&2
  exit 2
}

case "${1:-}" in
  '') ;;
  --root)
    [ "$#" -eq 2 ] && [ -d "$2" ] || usage
    ROOT=$(cd "$2" && pwd)
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) usage ;;
esac

SRC="$ROOT/docs/privateer"
RULEBOOK="$SRC/AGENTS.md"
AGENT="$SRC/agents/privateer.md"

# frontmatter_value <file> <key>: the value of a top-level `key:` line in the
# file's leading --- frontmatter block.
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    index($0, key ":") == 1 { sub("^" key ":[[:space:]]*", ""); print; exit }
  ' "$1"
}

# agent_skill_rules <file>: one `<pattern>\t<action>` line per entry under
# permission: skill: in the file's frontmatter, the pattern unquoted.
agent_skill_rules() {
  awk '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^[^[:space:]]/ { in_perm = ($0 == "permission:"); in_skill = 0; next }
    in_perm && /^  [^[:space:]]/ { in_skill = ($0 == "  skill:"); next }
    in_skill && /^    [^[:space:]]/ {
      line = substr($0, 5)
      n = split(line, parts, ":")
      action = parts[n]
      sub(/^[[:space:]]*/, "", action)
      pattern = substr(line, 1, length(line) - length(parts[n]) - 1)
      gsub(/^"|"$/, "", pattern)
      print pattern "\t" action
    }
  ' "$1"
}

# commands <file>: every command the file shows, one per line: each inline
# code span, and each fenced code line, that starts with bin/<name>.
commands() {
  perl -ne '
    if (/^\s*```/) { $fence = !$fence; next }
    if ($fence) { s/^\s+//; print if m{^bin/[\w][\w.-]*}; next }
    while (/`([^`]+)`/g) { my $c = $1; print "$c\n" if $c =~ m{^bin/[\w][\w.-]*} }
  ' "$1"
}

# scripts <file>: every bin/<name> the file mentions, one per line.
scripts() {
  perl -ne 'while (m{(?<![\w./\$-])bin/([\w][\w.-]*[\w])}g) { print "$1\n" }' "$1" | LC_ALL=C sort -u
}

check_file() {  # <file>
  local file=$1 rel name cmd parsed
  rel=${file#"$ROOT"/}
  while IFS= read -r name; do
    [ -e "$ROOT/bin/$name" ] || echo "$rel names bin/$name, which is not in this checkout"
  done < <(scripts "$file")
  while IFS= read -r cmd; do
    name=${cmd%%[[:space:]]*}
    name=${name#bin/}
    if [ -e "$ROOT/bin/$name" ] && { [ ! -f "$ROOT/bin/$name" ] || [ ! -x "$ROOT/bin/$name" ]; }; then
      echo "$rel shows \`$cmd\`, but bin/$name is not an executable script"
    fi
    parsed=$(printf '%s' "$cmd" | sed 's/<[^<>]*>/x/g')
    bash -n -c "$parsed" 2>/dev/null || echo "$rel shows \`$cmd\`, which does not parse as a shell command"
  done < <(commands "$file")
}

out=$(
  if [ ! -f "$RULEBOOK" ]; then
    echo "docs/privateer/AGENTS.md is missing"
  else
    size=$(wc -c < "$RULEBOOK" | tr -d ' ')
    [ "$size" -le "$RULEBOOK_MAX" ] || echo "docs/privateer/AGENTS.md is $size bytes; the rulebook may be at most $RULEBOOK_MAX"
    check_file "$RULEBOOK"
  fi
  skills=()
  for skill in "$SRC"/skills/*/SKILL.md; do
    [ -f "$skill" ] || continue
    dir=${skill%/SKILL.md}
    dir=${dir##*/}
    skills+=("$dir")
    rel=${skill#"$ROOT"/}
    size=$(wc -c < "$skill" | tr -d ' ')
    [ "$size" -le "$SKILL_MAX" ] || echo "$rel is $size bytes; a helm skill may be at most $SKILL_MAX"
    name=$(frontmatter_value "$skill" name)
    [ "$name" = "$dir" ] || echo "$rel names itself '$name', but its directory is $dir"
    printf '%s\n' "$dir" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' ||
      echo "$rel sits in directory $dir, but OpenCode needs lowercase words joined by single hyphens"
    [ -n "$(frontmatter_value "$skill" description)" ] || echo "$rel has no description"
    check_file "$skill"
  done
  if [ ! -f "$AGENT" ]; then
    echo "docs/privateer/agents/privateer.md is missing"
  else
    rules=$(agent_skill_rules "$AGENT")
    printf '%s\n' "$rules" | grep -qx "\*$(printf '\t')deny" ||
      echo "docs/privateer/agents/privateer.md must deny every skill with \"*\": deny under permission: skill:"
    allowed=$(printf '%s\n' "$rules" | awk -F '\t' '$2 == "allow" { print $1 }' | LC_ALL=C sort)
    present=$(printf '%s\n' "${skills[@]+"${skills[@]}"}" | sed '/^$/d' | LC_ALL=C sort)
    while IFS= read -r name; do
      [ -z "$name" ] || echo "docs/privateer/agents/privateer.md allows skill $name, which docs/privateer/skills/ does not hold"
    done < <(LC_ALL=C comm -23 <(printf '%s\n' "$allowed") <(printf '%s\n' "$present"))
    while IFS= read -r name; do
      [ -z "$name" ] || echo "docs/privateer/skills/$name is not allowed by docs/privateer/agents/privateer.md, so the first mate could never load it"
    done < <(LC_ALL=C comm -13 <(printf '%s\n' "$allowed") <(printf '%s\n' "$present"))
    check_file "$AGENT"
  fi
)
[ -n "$out" ] || exit 0
printf '%s\n' "$out"
exit 1
