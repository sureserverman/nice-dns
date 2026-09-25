#!/usr/bin/env python3
"""Paced DNS query load for nice-dns transition measurements (Sub-plan 2,
Task 2.3; ARCH-09). Development-only, standard library.

  dnsload.py --out FILE --duration S --rate QPS --timeout T
             --class NAME:HOST:PORT:NAMESPEC [--class ...]

Each --class sends A queries at --rate per second to HOST:PORT over UDP for
--duration seconds, every query in its own thread, so a slow answer never
delays the next send. NAMESPEC is either a comma-separated list of names
(cycled; e.g. cached "warm" names) or "fresh:SUFFIX" (a new random label per
query, so every query misses every cache and travels upstream).

Every attempted query is one row of FILE (nice-dns-transition-samples/1):
  class  name  sent_unix_ns  done_unix_ns  outcome  rcode  ms
outcome: answered (NOERROR/NXDOMAIN), error (another rcode), timeout.
Timeouts and errors stay in the file: nothing attempted is dropped.
"""
import argparse
import os
import random
import socket
import struct
import threading
import time


def query(name):
    qid = random.randint(0, 0xFFFF)
    q = b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\x00"
    return qid, struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + q + struct.pack(">HH", 1, 1)


RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}


def one(cls, name, host, port, timeout, rows, lock):
    qid, pkt = query(name)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    sent = time.time_ns()
    outcome, rcode = "timeout", "-"
    try:
        s.sendto(pkt, (host, port))
        end = time.monotonic() + timeout
        while True:
            s.settimeout(max(0.001, end - time.monotonic()))
            data, _ = s.recvfrom(4096)
            if len(data) >= 4 and struct.unpack(">H", data[:2])[0] == qid:
                rc = data[3] & 0x0F
                rcode = RCODES.get(rc, str(rc))
                outcome = "answered" if rc in (0, 3) else "error"
                break
    except OSError:
        pass
    finally:
        s.close()
    done = time.time_ns()
    with lock:
        rows.append((cls, name, sent, done, outcome, rcode, (done - sent) // 1_000_000))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--rate", type=float, required=True)
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--class", dest="classes", action="append", required=True)
    a = ap.parse_args()
    specs = []
    for c in a.classes:
        name, host, port, spec = c.split(":", 3)
        specs.append((name, host, int(port), spec))
    rows, lock, threads = [], threading.Lock(), []
    n = int(a.duration * a.rate)
    start = time.monotonic()
    for i in range(n):
        delay = start + i / a.rate - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        for cls, host, port, spec in specs:
            if spec.startswith("fresh:"):
                qname = "%s%d%06d.%s" % (cls, i, random.randint(0, 999999), spec[6:])
            else:
                names = spec.split(",")
                qname = names[i % len(names)]
            t = threading.Thread(target=one, args=(cls, qname, host, port, a.timeout, rows, lock))
            t.start()
            threads.append(t)
    for t in threads:
        t.join()
    tmp = a.out + ".tmp"
    with open(tmp, "w") as f:
        f.write("# schema\tnice-dns-transition-samples/1\n")
        f.write("class\tname\tsent_unix_ns\tdone_unix_ns\toutcome\trcode\tms\n")
        for r in sorted(rows, key=lambda r: r[2]):
            f.write("\t".join(str(x) for x in r) + "\n")
    os.replace(tmp, a.out)


if __name__ == "__main__":
    main()
