#!/usr/bin/env bash
# fm-sandbox-exec.sh - run a command inside a macOS Seatbelt sandbox that
# confines its file writes and its network connections.
#
# docs/configuration.md ("Sailor sandbox") owns the operator contract and
# bin/fm-spawn.sh owns which paths and endpoints a sailor launch passes. This
# header owns the profile.
#
# Usage:
#   fm-sandbox-exec.sh available
#   fm-sandbox-exec.sh profile [options]
#   fm-sandbox-exec.sh run [options] -- <command> [args...]
#
# Options (each repeatable):
#   --write <dir>            allow writes anywhere under <dir>
#   --deny-write <path>      deny writes to <path> and everything under it, even
#                            inside a --write directory or $TMPDIR
#   --write-prefix <prefix>  allow writes to every path that starts with <prefix>,
#                            even inside a --deny-write path
#   --connect <endpoint>     allow outbound TCP to <endpoint>, a URL or host:port
#   --unix-socket <path>     allow connecting to that Unix socket
#
# The profile starts from the system default, then denies every file write and
# every outbound network connection. Seatbelt lets a later rule win, so file
# writes are allowed back in three layers, in this order:
#   1. the caller's temporary directory ($TMPDIR, physical path), /dev/null, the
#      terminal, the process's own file descriptors, and every --write directory;
#   2. every --deny-write path is denied again;
#   3. every --write-prefix path is allowed again, so a caller can deny a whole
#      directory and still expose the exact files it names.
# Outbound connections are allowed back only to each --connect endpoint, the
# system DNS resolver socket, and each --unix-socket. A loopback endpoint host
# (localhost, 127.0.0.1, ::1) allows that one port, and any other host allows
# that port on every host, because a Seatbelt rule can name only localhost or
# any host.
# Reads, process launches, and every other operation keep the system default.
# The sandbox therefore bounds where a sandboxed process can write and what it
# can connect to; it does not stop it reading what the user can read, and it is
# not a boundary against same-user system services that start programs outside
# it.
#
# available exits 0 when sandbox-exec is installed and can run a trivial
# command under a trivial profile here, and 1 otherwise.
#
# Paths must be absolute and free of double quotes, backslashes, and control
# characters; they are resolved to physical paths when they exist, because
# Seatbelt compares physical paths. Exit status: `run` execs the command, so
# its status is the command's own; 2 is a usage error.
set -u
export LC_ALL=C

usage() {
  echo "usage: fm-sandbox-exec.sh available | profile [options] | run [options] -- <command> [args...]" >&2
  exit 2
}

die() {
  echo "fm-sandbox-exec: $*" >&2
  exit 2
}

# physical <path>: the path with its nearest existing directory ancestor
# resolved, so a path that does not exist yet still matches what Seatbelt sees.
physical() {
  local dir=$1 rest='' base
  while [ ! -d "$dir" ] && [ "$dir" != / ]; do
    base=$(basename -- "$dir")
    rest="/$base$rest"
    dir=$(dirname -- "$dir")
  done
  dir=$(cd "$dir" && pwd -P)
  [ "$dir" != / ] || dir=
  printf '%s%s\n' "$dir" "$rest"
}

safe_path() {  # <path> <option>
  case "$1" in
    /*) ;;
    *) die "$2 needs an absolute path, got '$1'" ;;
  esac
  case "$1" in
    *\"* | *\\* | *[[:cntrl:]]*) die "$2 path must not contain quotes, backslashes, or control characters: '$1'" ;;
  esac
}

regex_quote() {
  printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'
}

# endpoint_rule <endpoint>: the Seatbelt remote address for one endpoint.
endpoint_rule() {
  local e=$1 hostport host port
  hostport=${e#*://}
  hostport=${hostport%%/*}
  case "$hostport" in
    \[*\]:*) host=${hostport%%]*}; host=${host#[}; port=${hostport##*]:} ;;
    *:*) host=${hostport%:*}; port=${hostport##*:} ;;
    *)
      host=$hostport
      case "$e" in
        https://*) port=443 ;;
        http://*) port=80 ;;
        *) die "--connect needs a port or an http(s) URL, got '$e'" ;;
      esac
      ;;
  esac
  case "$port" in '' | *[!0-9]*) die "--connect port must be a number, got '$e'" ;; esac
  [ -n "$host" ] || die "--connect needs a host, got '$e'"
  case "$host" in
    localhost | 127.0.0.1 | ::1) printf '(remote ip "localhost:%s")' "$port" ;;
    *) printf '(remote ip "*:%s")' "$port" ;;
  esac
}

WRITES=()
PREFIXES=()
DENIES=()
CONNECTS=()
SOCKETS=()

parse_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --write | --write-prefix | --deny-write | --connect | --unix-socket)
        [ "$#" -ge 2 ] || die "$1 requires a value"
        case "$1" in
          --write) safe_path "$2" "$1"; WRITES+=("$(physical "$2")") ;;
          --write-prefix) safe_path "$2" "$1"; PREFIXES+=("$(physical "$2")") ;;
          --deny-write) safe_path "$2" "$1"; DENIES+=("$(physical "$2")") ;;
          --connect) endpoint_rule "$2" >/dev/null; CONNECTS+=("$2") ;;
          --unix-socket) safe_path "$2" "$1"; SOCKETS+=("$(physical "$2")") ;;
        esac
        shift 2
        ;;
      --)
        shift
        REST=("$@")
        return 0
        ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  REST=()
}

render_profile() {
  local p tmp
  tmp=$(physical "${TMPDIR:-/tmp}")
  printf '%s\n' '(version 1)' '(allow default)' '(deny file-write*)'
  printf '%s\n' '(allow file-write*'
  printf '  (subpath "%s")\n' "$tmp"
  for p in "${WRITES[@]+"${WRITES[@]}"}"; do printf '  (subpath "%s")\n' "$p"; done
  printf '%s\n' '  (literal "/dev/null")' '  (regex #"^/dev/tty")' '  (regex #"^/dev/fd/"))'
  if [ "${#DENIES[@]}" -gt 0 ]; then
    printf '%s\n' '(deny file-write*'
    for p in "${DENIES[@]}"; do printf '  (subpath "%s")\n' "$p"; done
    printf '%s\n' ')'
  fi
  if [ "${#PREFIXES[@]}" -gt 0 ]; then
    printf '%s\n' '(allow file-write*'
    for p in "${PREFIXES[@]}"; do printf '  (regex #"^%s")\n' "$(regex_quote "$p")"; done
    printf '%s\n' ')'
  fi
  printf '%s\n' '(deny network-outbound)'
  for p in "${CONNECTS[@]+"${CONNECTS[@]}"}"; do printf '(allow network-outbound %s)\n' "$(endpoint_rule "$p")"; done
  printf '%s\n' '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))'
  for p in "${SOCKETS[@]+"${SOCKETS[@]}"}"; do
    printf '(allow network-outbound (remote unix-socket (path-literal "%s")))\n' "$p"
  done
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  available)
    [ "$#" -eq 0 ] || usage
    command -v sandbox-exec >/dev/null 2>&1 || exit 1
    sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1 || exit 1
    ;;
  profile)
    parse_options "$@"
    [ "${#REST[@]}" -eq 0 ] || usage
    render_profile
    ;;
  run)
    parse_options "$@"
    [ "${#REST[@]}" -gt 0 ] || die "run needs -- <command>"
    command -v sandbox-exec >/dev/null 2>&1 || die "sandbox-exec is not available on this machine"
    exec sandbox-exec -p "$(render_profile)" "${REST[@]}"
    ;;
  -h | --help)
    sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    ;;
  *) usage ;;
esac
