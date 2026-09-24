#!/usr/bin/env python3
"""Route listener stand-in for nice-dns route-transition tests (Sub-plan 2,
Task 2.1). Development-only, standard library.

Listens on 127.0.0.1 at each --listen port and relays every TCP connection
to 127.0.0.1:--target (the DoT fixture), so Unbound's own TLS session to the
fixture passes through unchanged. Every chunk a client sends appends
"<listen port>" to <state>/connects.tsv, so a test sees which route port
carried a query even on a reused connection. Writes <state>/ready once
listening. Exits when its parent dies or after --max-seconds.
"""
import argparse
import os
import socket
import threading
import time


def pump(src, dst, record=None):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            if record:
                record()
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve(listener, port, target, log, lock):
    while True:
        try:
            client, _ = listener.accept()
        except OSError:
            return
        def record():
            with lock:
                with open(log, "a") as f:
                    f.write("%d\n" % port)
        try:
            upstream = socket.create_connection(("127.0.0.1", target), timeout=5)
        except OSError:
            client.close()
            continue
        upstream.settimeout(None)
        threading.Thread(target=pump, args=(client, upstream, record), daemon=True).start()
        threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--target", type=int, required=True)
    ap.add_argument("--listen", required=True, help="comma-separated ports")
    ap.add_argument("--max-seconds", type=float, default=600)
    a = ap.parse_args()
    log = os.path.join(a.state, "connects.tsv")
    open(log, "a").close()
    lock = threading.Lock()
    for p in (int(x) for x in a.listen.split(",")):
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", p))
        s.listen(32)
        threading.Thread(target=serve, args=(s, p, a.target, log, lock), daemon=True).start()
    open(os.path.join(a.state, "ready"), "w").close()
    owner, end = os.getppid(), time.monotonic() + a.max_seconds
    while os.getppid() == owner and time.monotonic() < end:
        time.sleep(0.5)


if __name__ == "__main__":
    main()
