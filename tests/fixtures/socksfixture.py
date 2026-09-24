#!/usr/bin/env python3
"""Controlled SOCKS4 endpoint standing in for Tor's SocksPort (sub-plan 02).

A proxy image under test sends every upstream TCP stream through SOCKS4 to
127.0.0.1:9050. This fixture takes that port inside the test's network
namespace and records, per CONNECT request, the destination the proxy asked
for and the first bytes the client sent through it. A route test sends a
unique marker per listener, so the log proves which provider destination
each listener reaches -- including when every destination fails.

Behaviour is read per connection from <state>/mode:
  accept         grant (0x5A), read the first payload bytes, close
  reject         refuse (0x5B) every request
  reject IP...   refuse requests for these destination IPs, accept the rest
                 (a provider is down; a stream that switched provider would
                 then be accepted elsewhere and logged with its marker)
  relay PORT     grant, then relay the stream to 127.0.0.1:PORT (e.g. the
                 DoT fixture), so a client's TLS runs end to end
Missing mode file means accept.

Log: <state>/connects.tsv, one row per request:
  utc  dest_ip  dest_port  mode  payload   (payload: printable prefix, or -)
Writes <state>/ready once listening. Exits by itself when its parent dies
or after --max-seconds (like dnsfixture.py). Standard library only.
"""

import argparse
import datetime
import os
import socket
import threading
import time

LOCK = threading.Lock()


def watchdog(max_seconds):
    owner, deadline = os.getppid(), time.monotonic() + max_seconds
    while os.getppid() == owner and time.monotonic() < deadline:
        time.sleep(0.2)
    os._exit(0)


def read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("short read")
        buf += chunk
    return buf


def read_until_nul(conn, limit=256):
    buf = b""
    while len(buf) < limit:
        c = conn.recv(1)
        if not c:
            raise ConnectionError("short read")
        if c == b"\0":
            return buf
        buf += c
    raise ConnectionError("SOCKS4 user id too long")


def printable(data):
    if not data:
        return "-"
    return "".join(chr(b) if 33 <= b < 127 else "." for b in data[:64])


def log_row(state, ip, port, mode, payload):
    utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    with LOCK, open(os.path.join(state, "connects.tsv"), "a") as f:
        f.write("%s\t%s\t%d\t%s\t%s\n" % (utc, ip, port, mode, payload))


def current_mode(state):
    try:
        with open(os.path.join(state, "mode")) as f:
            words = f.read().split()
    except FileNotFoundError:
        return ("accept",)
    if not words:
        return ("accept",)
    if words[0] == "accept" or words == ["reject"]:
        return (words[0],)
    if words[0] == "reject":
        return ("reject-some", set(words[1:]))
    if words[0] == "relay" and len(words) == 2 and words[1].isdigit():
        return ("relay", int(words[1]))
    return ("reject",)


def pump(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(conn, state):
    conn.settimeout(5)
    try:
        vn, cd = read_exact(conn, 2)
        port = int.from_bytes(read_exact(conn, 2), "big")
        ip = socket.inet_ntoa(read_exact(conn, 4))
        read_until_nul(conn)
        if vn != 4 or cd != 1:
            conn.sendall(b"\x00\x5b" + b"\0" * 6)
            log_row(state, ip, port, "bad-request", "-")
            return
        mode = current_mode(state)
        if mode[0] == "reject" or (mode[0] == "reject-some" and ip in mode[1]):
            conn.sendall(b"\x00\x5b" + b"\0" * 6)
            log_row(state, ip, port, "reject", "-")
            return
        if mode[0] == "relay":
            up = socket.create_connection(("127.0.0.1", mode[1]), timeout=5)
            conn.sendall(b"\x00\x5a" + b"\0" * 6)
            log_row(state, ip, port, "relay", "-")
            conn.settimeout(None)
            up.settimeout(None)
            t = threading.Thread(target=pump, args=(up, conn), daemon=True)
            t.start()
            pump(conn, up)
            t.join(5)
            up.close()
            return
        conn.sendall(b"\x00\x5a" + b"\0" * 6)
        conn.settimeout(2)
        try:
            data = conn.recv(64)
        except socket.timeout:
            data = b""
        log_row(state, ip, port, "accept", printable(data))
    except (OSError, ConnectionError, ValueError):
        pass
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--state", required=True)
    ap.add_argument("--port", type=int, default=9050)
    ap.add_argument("--max-seconds", type=int, default=900)
    a = ap.parse_args()
    threading.Thread(target=watchdog, args=(a.max_seconds,), daemon=True).start()
    os.makedirs(a.state, mode=0o700, exist_ok=True)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(64)
    open(os.path.join(a.state, "connects.tsv"), "a").close()
    with open(os.path.join(a.state, "ready"), "w") as f:
        f.write("%d\n" % a.port)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn, a.state), daemon=True).start()


if __name__ == "__main__":
    main()
