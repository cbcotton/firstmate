#!/usr/bin/env python3
"""fm-privateer-proxy.py - the Privateer egress proxy: the only way out of a
Privateer session's sandbox.

bin/fm-privateer.sh owns when it runs, where its files live, and which
destinations it allows; docs/configuration.md ("Privateer quarantine") owns the
operator contract. This header owns the wire behavior.

Usage:
  fm-privateer-proxy.py <port-file> <log> [<host>:<port> ...]

It listens on 127.0.0.1 on a port the system picks, and only once it is bound
writes that port to <port-file>; if it cannot bind it writes nothing and exits
1. Each <host>:<port> is one allowed destination: a lowercase host name or
IPv4 address, or a bracketed IPv6 address, and a port.

A CONNECT to an allowed destination becomes a tunnel. A request whose target is
an absolute http:// URL naming an allowed destination is forwarded to it with
its target reduced to the path, with `Connection: close`, and its response is
relayed as is. Every other request, including one whose URL authority carries
userinfo or a backslash, is refused with 403. A destination is compared on host
and port alone, the host case-insensitively; the proxy never follows DNS
aliases or redirects.

Every request appends one JSON line to <log>: {"time", "verdict" (allowed or
refused), "method", "dest" (host:port, or the raw target when it has none)}.
"""
import json
import os
import select
import socket
import socketserver
import sys
import threading
import time

PORT_FILE, LOG = sys.argv[1], sys.argv[2]
ALLOW = set(a.lower() for a in sys.argv[3:])
LOCK = threading.Lock()


def hostport(authority, default_port):
    """<host>:<port> for an authority, normalized as ALLOW is, or None."""
    if not authority or "@" in authority or "\\" in authority:
        return None
    if authority.startswith("["):
        host, sep, tail = authority[1:].partition("]")
        if not sep or not host:
            return None
        host = "[" + host + "]"
    else:
        host, sep, tail = authority.partition(":")
        tail = sep + tail
        if not host:
            return None
    if tail == "" and default_port:
        port = default_port
    elif tail.startswith(":") and tail[1:].isdigit():
        port = tail[1:]
    else:
        return None
    return "%s:%s" % (host.lower(), int(port))


def url_dest(target):
    """(<host>:<port>, origin-form path) for an absolute http URL, or None."""
    scheme, sep, rest = target.partition("://")
    if not sep or scheme.lower() != "http":
        return None
    end = len(rest)
    for c in "/?#":
        i = rest.find(c)
        if i != -1 and i < end:
            end = i
    dest = hostport(rest[:end], 80)
    if dest is None:
        return None
    path = rest[end:].split("#", 1)[0]
    if not path.startswith("/"):
        path = "/" + path
    return dest, path


def record(verdict, method, dest):
    line = json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                       "verdict": verdict, "method": method, "dest": dest})
    with LOCK:
        with open(LOG, "a") as f:
            f.write(line + "\n")


def connect(dest):
    host, _, port = dest.rpartition(":")
    return socket.create_connection((host.strip("[]"), int(port)), timeout=30)


def relay(a, b):
    a.settimeout(None)
    b.settimeout(None)
    socks = [a, b]
    while True:
        ready, _, _ = select.select(socks, [], [], 600)
        if not ready:
            return
        for s in ready:
            data = s.recv(65536)
            if not data:
                return
            (b if s is a else a).sendall(data)


class Handler(socketserver.BaseRequestHandler):
    def refuse(self, method, dest):
        record("refused", method, dest)
        body = b"refused by the Privateer egress proxy\n"
        self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: "
                             + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)

    def handle(self):
        buf = b""
        while b"\r\n\r\n" not in buf:
            data = self.request.recv(65536)
            if not data or len(buf) > 65536:
                return
            buf += data
        head, _, rest = buf.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        parts = lines[0].split(" ")
        if len(parts) != 3:
            return self.refuse("?", lines[0])
        method, target, version = parts
        if method.upper() == "CONNECT":
            dest = hostport(target, None)
            if dest not in ALLOW:
                return self.refuse(method, dest or target)
            record("allowed", method, dest)
            try:
                upstream = connect(dest)
            except OSError:
                self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                return
            self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            if rest:
                upstream.sendall(rest)
            relay(self.request, upstream)
            upstream.close()
            return
        parsed = url_dest(target)
        if parsed is None or parsed[0] not in ALLOW:
            return self.refuse(method, parsed[0] if parsed else target)
        dest, path = parsed
        record("allowed", method, dest)
        headers = [h for h in lines[1:] if h.split(":", 1)[0].strip().lower()
                   not in ("connection", "proxy-connection", "proxy-authorization", "keep-alive")]
        out = "\r\n".join(["%s %s %s" % (method, path, version)] + headers + ["Connection: close", "", ""])
        try:
            upstream = connect(dest)
        except OSError:
            self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
            return
        upstream.sendall(out.encode("latin-1") + rest)
        relay(self.request, upstream)
        upstream.close()


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


try:
    server = Server(("127.0.0.1", 0), Handler)
except OSError as e:
    sys.stderr.write("fm-privateer-proxy: cannot bind: %s\n" % e)
    sys.exit(1)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write("%d\n" % server.server_address[1])
os.replace(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
