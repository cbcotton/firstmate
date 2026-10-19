#!/usr/bin/env bash
# fm-sailor-identity.sh - give a named sailor's task copy its own commit identity.
#
# docs/configuration.md ("Sailor commit identity") owns the operator contract and
# bin/fm-spawn.sh owns when a spawn calls this. This header owns the mechanics.
#
# Usage:
#   fm-sailor-identity.sh resolve <config-dir> <project> <sailor>
#   fm-sailor-identity.sh apply <worktree> <name> <email>
#
# resolve reads <config-dir>/sailor-commit-identity, one mapping per line:
#   <project> <Name> <email-with-{sailor}>
# Blank lines and lines starting with # are ignored. It validates every line, not
# only the project's own, so a typo is caught on the first sailor spawn rather
# than on the one that happens to use it. A line is malformed unless it is a
# project token, a name with no angle brackets or braces, and one <address>
# holding {sailor} and no whitespace, and a project named twice is malformed too.
# It prints "<Name><TAB><email>" with {sailor} replaced when the project is
# mapped, prints nothing when the file or the project's line is absent, and exits
# 2 naming the line when the file is malformed.
#
# apply sets user.name and user.email in that one worktree's own configuration
# (extensions.worktreeConfig plus git config --worktree), never the repository's
# shared user.* settings, the primary checkout, or global configuration. It is
# idempotent, so a relaunch on the same worktree keeps the identity.
set -u

die() {
  echo "error: $*" >&2
  exit 2
}

cmd_resolve() {
  [ $# -eq 3 ] || die "usage: fm-sailor-identity.sh resolve <config-dir> <project> <sailor>"
  local file=$1/sailor-commit-identity project=$2 sailor=$3
  local line n=0 proj rest name addr found_name='' found_email='' seen=' '
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if ! [[ $line =~ ^[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]+([^<>{}]*[^<>{}[:space:]])[[:space:]]*\<([^<>[:space:]]*\{sailor\}[^<>[:space:]]*)\>[[:space:]]*$ ]]; then
      die "$file line $n is malformed (want '<project> <Name> <name-with-{sailor}@host>'): $line"
    fi
    proj=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]} addr=${BASH_REMATCH[3]}
    [[ $addr =~ ^[^@]+@[^@]+$ ]] || die "$file line $n has an address that is not user@host: $line"
    rest=${addr//\{sailor\}/}
    case $rest in *'{'* | *'}'*) die "$file line $n has a stray brace in its address: $line" ;; esac
    case $seen in *" $proj "*) die "$file line $n maps project $proj a second time" ;; esac
    seen="$seen$proj "
    if [ "$proj" = "$project" ]; then
      found_name=$name
      found_email=${addr//\{sailor\}/$sailor}
    fi
  done <"$file"
  [ -z "$found_name" ] || printf '%s\t%s\n' "$found_name" "$found_email"
}

cmd_apply() {
  [ $# -eq 3 ] || die "usage: fm-sailor-identity.sh apply <worktree> <name> <email>"
  local wt=$1 name=$2 email=$3
  local gd common
  gd=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || die "$wt is not a git worktree"
  common=$(cd "$wt" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || die "could not resolve the repository of $wt"
  [ "$(cd "$gd" && pwd -P)" != "$common" ] || die "$wt is the repository's primary checkout, not a linked worktree"
  git -C "$wt" config extensions.worktreeConfig true || die "could not enable extensions.worktreeConfig for $wt"
  git -C "$wt" config --worktree user.name "$name" || die "could not set user.name in $wt"
  git -C "$wt" config --worktree user.email "$email" || die "could not set user.email in $wt"
}

case ${1-} in
resolve) shift; cmd_resolve "$@" ;;
apply) shift; cmd_apply "$@" ;;
*) die "usage: fm-sailor-identity.sh resolve|apply ..." ;;
esac
