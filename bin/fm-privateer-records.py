#!/usr/bin/env python3
"""fm-privateer-records.py - the Privateer record writer: the only process that
writes a Privateer home's task records, state/<id>.meta, while its session runs.

bin/fm-privateer.sh owns when it runs and where its files live;
bin/fm-privateer-lib.sh owns its socket path and when a script hands it a
write; docs/configuration.md ("Privateer quarantine") owns the operator
contract. This header owns the wire behavior and the identity check.

Usage:
  fm-privateer-records.py serve <socket> <state-dir> <dir> <anchor-pid> <anchor-start>
  fm-privateer-records.py request <socket> ping
  fm-privateer-records.py request <socket> publish <id> [<mode>]
  fm-privateer-records.py request <socket> append|remove <id>

serve runs outside the session's sandbox. <anchor-pid> is the first mate's
pane process and <anchor-start> its start time as `ps -o lstart=` prints it
under LC_ALL=C, the locale the writer reads it in too.
It refuses to start (exit 1) unless the anchor runs with that start time, then
binds the Unix socket <socket>, replacing only a stale socket there, makes it
owner-only, and once it listens writes <socket> to <dir>/records.ready. It
stages every write in <dir>/records.tmp/, which must be on the same file
system as <state-dir>, appends one JSON line per refusal to <dir>/records.log,
and on SIGTERM removes its socket and ready file and exits.

Each connection carries one request, a JSON object {"op", "id", "content"},
with an optional "mode" on a publish,
that ends when the caller shuts down its side, and gets one reply line: `ok`
or `refused: <why>`. A request is served only when the caller's user id,
which the socket reports, is the writer's own, the anchor still runs with its
start time (so a reused process id never passes), and the caller's process,
which the socket also reports, is the anchor or descends from it in one
`ps -A -o pid=,ppid=` snapshot. Every worker is a pane the session's tmux
server forks, so none descends from the first mate; a script the first mate
detaches with nohup or setsid reparents to init and is refused too.

  ping     answers ok, so a caller learns the writer accepts it before it
           writes anything.
  publish  replaces <state-dir>/<id>.meta with "content" whole: written to a
           new file in <dir>/records.tmp/ and renamed over the record, so the
           record never exists half-written and nothing a worker can write is
           ever staged.
  append   adds "content" to the end of the record the same way, keeping the
           record's mode, and refuses when there is no record.
  remove   deletes the record; one that is already gone is fine.

<id> must match [A-Za-z0-9._-]+, the class bin/fm-wake-lib.sh's
fm_meta_lock_path accepts, so a request can name nothing outside <state-dir>.
"content" is at most 65536 bytes. A published record gets the mode a shell
redirection would give it under the writer's umask, or the publish's "mode",
an integer that must be 0600 or grant nothing that default does not. Each refusal is logged as
{"time", "verdict": "refused", "op", "id", "pid", "why"}.

request sends one request, reading the content from stdin for publish and
append and taking a publish's <mode> in octal, and exits 0 on ok, 1 on a refusal (printed on stderr), 2 on a usage
error, and 3 when the writer cannot be reached.
"""
import json
import os
import re
import shutil
import signal
import socket
import socketserver
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time

MAX_CONTENT = 65536
MAX_REQUEST = 8 * MAX_CONTENT
ID_RE = re.compile(r"[A-Za-z0-9._-]+\Z")
PS = "/bin/ps" if os.path.exists("/bin/ps") else (shutil.which("ps") or "ps")
WRITE_LOCK = threading.Lock()
LOG_LOCK = threading.Lock()
# <sys/un.h> on macOS: SOL_LOCAL, LOCAL_PEERCRED (struct xucred), LOCAL_PEERPID.
SOL_LOCAL, LOCAL_PEERCRED, LOCAL_PEERPID = 0, 1, 2


def usage():
    sys.stderr.write(
        "usage: fm-privateer-records.py serve <socket> <state-dir> <dir> <anchor-pid> <anchor-start>\n"
        "       fm-privateer-records.py request <socket> ping | publish <id> [<mode>] | append|remove <id>\n")
    sys.exit(2)


def start_time(pid):
    """The process's start time as `ps -o lstart=` prints it, spaces folded,
    or "" when it does not run."""
    try:
        r = subprocess.run([PS, "-o", "lstart=", "-p", str(pid)], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True, timeout=10,
                           env=dict(os.environ, LC_ALL="C"))
    except (OSError, subprocess.SubprocessError):
        return ""
    return " ".join(r.stdout.split()) if r.returncode == 0 else ""


def parents():
    """One snapshot of every process's parent, {pid: ppid}."""
    r = subprocess.run([PS, "-A", "-o", "pid=,ppid="], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True, timeout=10)
    table = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = int(parts[1])
    return table


def peer(conn):
    """The connecting process's (pid, uid), as the kernel recorded them."""
    if hasattr(socket, "SO_PEERCRED"):
        size = struct.calcsize("3i")
        pid, uid, _gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, size))
        return pid, uid
    cred = conn.getsockopt(SOL_LOCAL, LOCAL_PEERCRED, 76)
    _version, uid = struct.unpack("II", cred[:8])
    pid = struct.unpack("i", conn.getsockopt(SOL_LOCAL, LOCAL_PEERPID, 4))[0]
    return pid, uid


class Writer:
    def __init__(self, state, work, log, anchor, anchor_start):
        self.state, self.work, self.log = state, work, log
        self.anchor, self.anchor_start = anchor, anchor_start
        mask = os.umask(0)
        os.umask(mask)
        self.mode = 0o666 & ~mask

    def anchor_alive(self):
        return start_time(self.anchor) == self.anchor_start

    def why_not(self, pid, uid):
        """None when the caller may write, else why it may not."""
        if uid != os.getuid():
            return "the caller runs as another user"
        if not self.anchor_alive():
            return "the first mate's process has ended; the captain must stop and start the session again"
        table = parents()
        p, steps = pid, 0
        while p > 1 and p != self.anchor and steps < 4096:
            p, steps = table.get(p, 0), steps + 1
        if p != self.anchor:
            return "only the first mate and the processes it starts may write task records"
        if not self.anchor_alive():
            return "the first mate's process has ended; the captain must stop and start the session again"
        return None

    def record(self, op, ident, pid, why):
        line = json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "verdict": "refused",
                           "op": op, "id": ident, "pid": pid, "why": why})
        with LOG_LOCK:
            try:
                with open(self.log, "a") as f:
                    f.write(line + "\n")
            except OSError:
                pass

    def mode_allowed(self, mode):
        return mode == 0o600 or (0 <= mode <= 0o777 and not mode & ~self.mode)

    def replace(self, path, data, mode):
        fd, tmp = tempfile.mkstemp(prefix=".record.", dir=self.work)
        try:
            os.fchmod(fd, mode)
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
            os.close(fd)
            fd = -1
            os.rename(tmp, path)
        except BaseException:
            if fd >= 0:
                os.close(fd)
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def apply(self, op, ident, data, mode):
        """Do one accepted write; None on success, else why it failed."""
        path = os.path.join(self.state, ident + ".meta")
        try:
            if op == "publish":
                self.replace(path, data, self.mode if mode is None else mode)
            elif op == "append":
                try:
                    st = os.lstat(path)
                except FileNotFoundError:
                    return "there is no task record %s to append to" % ident
                if not stat.S_ISREG(st.st_mode):
                    return "the task record %s is not a regular file" % ident
                fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                with os.fdopen(fd, "rb") as f:
                    old = f.read()
                self.replace(path, old + data, stat.S_IMODE(st.st_mode))
            elif op == "remove":
                try:
                    st = os.lstat(path)
                except FileNotFoundError:
                    return None
                if stat.S_ISDIR(st.st_mode):
                    return "the task record %s is a directory" % ident
                os.unlink(path)
        except OSError as e:
            return "the task record %s could not be written: %s" % (ident, e.strerror or e)
        return None


class Handler(socketserver.BaseRequestHandler):
    def reply(self, text):
        try:
            self.request.sendall((text + "\n").encode())
        except OSError:
            pass

    def handle(self):
        writer = self.server.writer
        conn = self.request
        conn.settimeout(10)
        try:
            pid, uid = peer(conn)
        except (OSError, struct.error):
            pid, uid = 0, -1
        raw, op, ident = b"", "?", ""
        try:
            while len(raw) <= MAX_REQUEST:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                raw += chunk
        except OSError:
            return self.refuse(op, ident, pid, "the request did not arrive in time")
        if len(raw) > MAX_REQUEST:
            return self.refuse(op, ident, pid, "the request is too large")
        try:
            req = json.loads(raw.decode("utf-8"))
            op, ident, content = req.get("op"), req.get("id", ""), req.get("content", "")
            mode = req.get("mode")
            if not isinstance(op, str) or not isinstance(ident, str) or not isinstance(content, str):
                raise ValueError
            if mode is not None and (not isinstance(mode, int) or isinstance(mode, bool)):
                raise ValueError
            data = content.encode("utf-8", "surrogateescape")
        except (ValueError, AttributeError, UnicodeError):
            return self.refuse("?", "", pid, "the request is not a JSON object with op, id, content, and an integer mode")
        if op not in ("ping", "publish", "append", "remove"):
            return self.refuse(op, ident, pid, "unknown request %r" % op)
        if op != "ping" and not ID_RE.match(ident):
            return self.refuse(op, ident, pid, "%r is not a task id" % ident)
        if mode is not None and op != "publish":
            return self.refuse(op, ident, pid, "only a publish takes a mode")
        if mode is not None and not writer.mode_allowed(mode):
            return self.refuse(op, ident, pid, "mode %o is wider than the writer's default %o" % (mode, writer.mode))
        if len(data) > MAX_CONTENT:
            return self.refuse(op, ident, pid, "the content is larger than %d bytes" % MAX_CONTENT)
        with WRITE_LOCK:
            try:
                why = writer.why_not(pid, uid)
            except (OSError, subprocess.SubprocessError):
                why = "the process table could not be read"
            if why is None and op != "ping":
                why = writer.apply(op, ident, data, mode)
        if why is not None:
            return self.refuse(op, ident, pid, why)
        self.reply("ok")

    def refuse(self, op, ident, pid, why):
        self.server.writer.record(op, ident, pid, why)
        self.reply("refused: " + why)


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve(args):
    if len(args) != 5:
        usage()
    sock_path, state, directory, anchor, anchor_start = args
    if not anchor.isdigit():
        usage()
    anchor_start = " ".join(anchor_start.split())
    work = os.path.join(directory, "records.tmp")
    ready = os.path.join(directory, "records.ready")
    if not os.path.isdir(state):
        sys.stderr.write("fm-privateer-records: %s is not a directory\n" % state)
        sys.exit(1)
    writer = Writer(state, work, os.path.join(directory, "records.log"), int(anchor), anchor_start)
    if not anchor_start or not writer.anchor_alive():
        sys.stderr.write("fm-privateer-records: the first mate's process %s is not running with start time %r\n"
                         % (anchor, anchor_start))
        sys.exit(1)
    try:
        os.makedirs(work, exist_ok=True)
        if os.path.lexists(sock_path):
            if not stat.S_ISSOCK(os.lstat(sock_path).st_mode):
                sys.stderr.write("fm-privateer-records: %s exists and is not a socket\n" % sock_path)
                sys.exit(1)
            os.unlink(sock_path)
        server = Server(sock_path, Handler)
        os.chmod(sock_path, 0o600)
    except OSError as e:
        sys.stderr.write("fm-privateer-records: cannot listen on %s: %s\n" % (sock_path, e))
        sys.exit(1)
    server.writer = writer
    bound = os.stat(sock_path).st_ino

    def stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    try:
        with open(ready + ".tmp", "w") as f:
            f.write(sock_path + "\n")
        os.replace(ready + ".tmp", ready)
        server.serve_forever()
    finally:
        try:
            os.unlink(ready)
        except OSError:
            pass
        try:
            if os.stat(sock_path).st_ino == bound:
                os.unlink(sock_path)
        except OSError:
            pass


def request(args):
    if len(args) < 2:
        usage()
    sock_path, op = args[0], args[1]
    req = {"op": op}
    if op == "ping":
        if len(args) != 2:
            usage()
        ident, content = "", b""
    elif op in ("publish", "append", "remove"):
        if len(args) != 3 and not (op == "publish" and len(args) == 4):
            usage()
        ident = args[2]
        if len(args) == 4:
            if not re.match(r"[0-7]{1,4}\Z", args[3]):
                usage()
            req["mode"] = int(args[3], 8)
        content = sys.stdin.buffer.read(MAX_CONTENT + 1) if op != "remove" else b""
    else:
        usage()
    req.update(id=ident, content=content.decode("utf-8", "surrogateescape"))
    body = json.dumps(req)
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
        conn.connect(sock_path)
        conn.sendall(body.encode())
        conn.shutdown(socket.SHUT_WR)
        reply = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            reply += chunk
        conn.close()
    except OSError as e:
        sys.stderr.write("the Privateer record writer cannot be reached: %s\n" % (e.strerror or e))
        sys.exit(3)
    text = reply.decode("utf-8", "replace").strip()
    if text == "ok":
        sys.exit(0)
    sys.stderr.write((text or "refused: the record writer gave no answer") + "\n")
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        usage()
    if sys.argv[1] == "serve":
        serve(sys.argv[2:])
    elif sys.argv[1] == "request":
        request(sys.argv[2:])
    else:
        usage()


if __name__ == "__main__":
    main()
