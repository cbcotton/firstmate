#!/usr/bin/env bash
# Static watcher program for a validated pull request, merge request, or Gerrit
# change poll sidecar.
# It emits exactly one merged line for a merged change and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, gerrit-axi for Gerrit, and tea for Gitea, so an upstream checkout
# needs no extra tooling to follow the first two. The Gerrit and Gitea branches
# additionally need jq, which bin/fm-pr-check.sh refuses to arm either without.
# A Gitea pull request also reports a standing condition as one line naming its
# URL: "closed:" when it was closed without merging, and "out-of-date:" when its
# base branch moved past it, naming the base tip and noting that it may also
# conflict, so firstmate can have the base merged in. Gitea cannot tell a
# conflict apart from a pending or failed conflict check, so a conflict is
# reported through this one out-of-date line and never as "conflicting:". The watcher wakes once per distinct condition line
# (bin/fm-pr-lib.sh fm_pr_poll_condition_matches).
# "--gitea-login <host>" prints the one tea login for a Gitea host, the rule
# bin/fm-pr-lib.sh fm_pr_gitea_login also reads through this program.
set -u
LC_ALL=C
export LC_ALL

# The one tea login for a Gitea host: exactly one login whose URL is
# https://<host>, and none otherwise, so a request to one instance never carries
# another instance's token. tea lists logins without their tokens and only the
# name is read from that list.
gitea_login() {  # <host>
  local logins login
  logins=$(tea logins list --output json 2>/dev/null) || return 1
  login=$(printf '%s' "$logins" | jq -r --arg url "https://$1" '
    if type == "array" then
      [.[] | select(type == "object" and (.name | type) == "string"
        and (.url | type) == "string" and (.url | sub("/+$"; "")) == $url)] as $match
      | if ($match | length) == 1 then $match[0].name
        else error("no single login for this host")
        end
    else
      error("invalid login list")
    end' 2>/dev/null) || return 1
  case "$login" in
    ''|-*|*[!A-Za-z0-9._@-]*) return 1 ;;
  esac
  printf '%s\n' "$login"
}

if [ "$#" -eq 2 ] && [ "$1" = --gitea-login ]; then
  gitea_login "$2" || exit 1
  exit 0
elif [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  gerrit)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A Gerrit project name is a path at no fixed depth that needs no enclosing
    # group, so one segment is canonical here where GitLab needs two, and Gerrit
    # reserves no route segment inside it.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 1 ] || exit 0
    [ "$url" = "https://$host/c/$path/+/$number" ] || exit 0
    # gerrit-axi resolves its server from the current directory's origin remote
    # first, and the watcher runs in no repository, so the host must be passed
    # explicitly from the validated record. Without it the tool has no host to
    # reach and fails before reading anything, and this poll is silent on every
    # failure, so the watch would wait forever on a change it never looked at.
    #
    # The status is read explicitly and is the only thing that can wake this
    # poll. Gerrit's submittability is a different question: a merged change
    # still reports its submit state as OK with nothing blocking it, so reading
    # submittability, a blocked_on list, or vote values would report a merge for
    # an open change that is merely ready to submit.
    #
    # jq selects the one record whose change number matches. A change number is
    # server-global and --host already pins the server, so the number alone
    # names the change. The record's own url field is deliberately not compared
    # against the stored URL: Gerrit composes that field from
    # gerrit.canonicalWebUrl and omits it when that setting is unset, so an
    # equality test would leave a correctly armed watch silent forever on such
    # a server, and this poll has no channel to report that it never matched.
    json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) || exit 0
    [ -n "$json" ] || exit 0
    status=$(printf '%s' "$json" | jq -r --argjson change "$number" '
      if type == "object" and .ok == true and (.changes | type) == "array" then
        [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
        | if ($match | length) == 1
             and ($match[0].status | type) == "string"
          then $match[0].status
          else error("no exact change record")
          end
      else
        error("invalid gerrit record")
      end' 2>/dev/null) || exit 0
    [ "$status" = MERGED ] && printf '%s\n' merged
    ;;
  gitea)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    # A Gitea repository is exactly owner/repository.
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 40 ] || exit 0
    case "$owner" in
      [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://$host/$owner/$repo/pulls/$number" ] || exit 0
    login=$(gitea_login "$host") || exit 0
    json=$(tea api --login "$login" "/repos/$owner/$repo/pulls/$number" 2>/dev/null) || exit 0
    [ -n "$json" ] || exit 0
    # tea exits zero on an HTTP error and prints the error body, so only the
    # pull request with exactly this number is read. merge_base is the fork
    # point Gitea last computed against the base tip base.sha, so the two differ
    # exactly when the base branch has moved past the pull request. Its
    # mergeable flag is not read: the API reports it false alike while Gitea is
    # still checking, after a failed check, and for a real conflict, so it
    # cannot tell a conflict apart. A pull request the base moved past is out
    # of date and possibly conflicting whichever it is, in one line that stays
    # the same across the check so one move of the base wakes once.
    printf '%s' "$json" | jq -r --argjson number "$number" --arg url "$url" '
      def shaish: type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
      if type == "object" and .number == $number and (.merged | type) == "boolean" then
        if .merged == true then "merged"
        elif .state == "closed" then "closed: \($url) was closed without merging"
        elif .state != "open" or .draft == true then empty
        elif (.base | type) == "object" and (.base.sha | shaish) and (.merge_base | shaish)
             and .merge_base != .base.sha then
          (if (.base.ref | type) == "string" and (.base.ref | test("^[A-Za-z0-9._/-]{1,255}$"))
           then .base.ref else "its base branch" end) as $base
          | "out-of-date: \($url) is behind \($base) at \(.base.sha) and possibly conflicting; merge \($base) into its branch"
        else empty
        end
      else empty
      end' 2>/dev/null
    ;;
  *) exit 0 ;;
esac
exit 0
