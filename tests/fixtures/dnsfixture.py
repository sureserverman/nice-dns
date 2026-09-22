#!/usr/bin/env python3
"""Controlled DNS, DNSSEC and DNS-over-TLS fixture for nice-dns tests.

Sub-plan 01, Task 1.2 (ARCH-09). Development-only: Python standard library
plus the openssl CLI (ARCH-05). Listens on 127.0.0.1 only, never recurses or
forwards, and generates fresh keys and certificates on every start.

Zone fixture.test. (signed, ECDSAP256SHA256, NSEC):
  signed.fixture.test.       A 192.0.2.1   valid RRSIG
  bogus.fixture.test.        A 192.0.2.66  RRSIG deliberately corrupted here
  tc.fixture.test.           TXT           TC=1 over UDP, full answer over TCP
  unsigned.fixture.test.     insecure delegation (signed NSEC proves no DS)
  host.unsigned.fixture.test A 192.0.2.7   unsigned answer
  drop.fixture.test.         never answered (client timeout)
  servfail.fixture.test.     SERVFAIL
  anything else under the zone: NXDOMAIN/NODATA with signed NSEC proofs.
Names outside the zone are REFUSED.

Commands:
  dnsfixture.py pki --out DIR     CA + good/wrongname/expired/untrusted leaves
  dnsfixture.py serve --state DIR [--tls NAME:CERT:KEY ...]
The serve command writes anchor.bind (delv), anchor.unbound (Unbound
trust-anchor line) and, once listening, ports.tsv (name<TAB>port).
"""
import argparse
import base64
import datetime
import os
import socket
import socketserver
import ssl
import struct
import subprocess
import threading
import time

ZONE = "fixture.test."
CHILD = "unsigned." + ZONE
TLS_NAME = "dns." + ZONE.rstrip(".")
T = {"A": 1, "NS": 2, "SOA": 6, "TXT": 16, "AAAA": 28, "OPT": 41, "DS": 43,
     "RRSIG": 46, "NSEC": 47, "DNSKEY": 48}
TTL = 300
ALG = 13  # ECDSAP256SHA256


def openssl(*args, data=None):
    return subprocess.run(("openssl",) + args, input=data, check=True,
                          capture_output=True).stdout


def wire_name(name):
    out = b""
    for label in name.lower().rstrip(".").split("."):
        if label:
            out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def parse_name(msg, off):
    labels, end = [], None
    while True:
        ln = msg[off]
        if ln == 0:
            off += 1
            break
        if ln & 0xC0 == 0xC0:
            end = end if end is not None else off + 2
            off = ((ln & 0x3F) << 8) | msg[off + 1]
            continue
        labels.append(msg[off + 1:off + 1 + ln].decode("ascii", "replace"))
        off += 1 + ln
    name = (".".join(labels) + ".").lower() if labels else "."
    return name, (end if end is not None else off)


def canon_key(name):
    """RFC 4034 section 6.1 canonical order: compare reversed label lists."""
    return [lbl.encode() for lbl in reversed(name.lower().rstrip(".").split("."))]


def type_bitmap(types):
    windows = {}
    for t in types:
        windows.setdefault(t >> 8, bytearray(32))[(t & 0xFF) >> 3] |= 0x80 >> (t & 7)
    out = b""
    for w in sorted(windows):
        bm = bytes(windows[w]).rstrip(b"\x00")
        out += bytes([w, len(bm)]) + bm
    return out


class Signer:
    def __init__(self, state):
        self.key = os.path.join(state, "zsk.pem")
        openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", self.key)
        os.chmod(self.key, 0o600)
        self.pub = openssl("ec", "-in", self.key, "-pubout", "-outform", "DER")[-64:]
        self.dnskey = struct.pack("!HBB", 257, 3, ALG) + self.pub
        acc = 0
        for i, b in enumerate(self.dnskey):  # RFC 4034 appendix B key tag
            acc += b if i & 1 else b << 8
        self.tag = (acc + ((acc >> 16) & 0xFFFF)) & 0xFFFF

    def sign(self, data):
        der = openssl("dgst", "-sha256", "-sign", self.key, data=data)
        # DER SEQUENCE { INTEGER r, INTEGER s } -> r || s, 32 bytes each (RFC 6605)
        i, out = (2 if der[1] < 0x80 else 3), b""
        for _ in range(2):
            ln = der[i + 1]
            out += der[i + 2:i + 2 + ln].lstrip(b"\x00").rjust(32, b"\x00")
            i += 2 + ln
        return out

    def rrsig(self, owner, rtype, rdatas):
        now = int(time.time())
        labels = len([lbl for lbl in owner.rstrip(".").split(".") if lbl])
        head = struct.pack("!HBBIIIH", rtype, ALG, labels, TTL, now + 86400,
                           now - 3600, self.tag) + wire_name(ZONE)
        data = head
        for rd in sorted(rdatas):
            data += wire_name(owner) + struct.pack("!HHIH", rtype, 1, TTL, len(rd)) + rd
        return head + self.sign(data)


def txt(s):
    return bytes([len(s)]) + s


def soa(apex):
    return (wire_name("ns." + ZONE) + wire_name("hostmaster." + apex)
            + struct.pack("!IIIII", 1, 3600, 600, 86400, 60))


class Zones:
    def __init__(self, signer):
        ip = socket.inet_aton
        z = {
            ZONE: {T["SOA"]: [soa(ZONE)], T["NS"]: [wire_name("ns." + ZONE)],
                   T["DNSKEY"]: [signer.dnskey]},
            "ns." + ZONE: {T["A"]: [ip("127.0.0.1")]},
            "signed." + ZONE: {T["A"]: [ip("192.0.2.1")]},
            "bogus." + ZONE: {T["A"]: [ip("192.0.2.66")]},
            "tc." + ZONE: {T["TXT"]: [txt((b"t%03d" % i) * 40) for i in range(12)]},
            CHILD: {T["NS"]: [wire_name("ns." + ZONE)]},  # delegation, no DS
        }
        names = sorted(z, key=canon_key)
        for i, n in enumerate(names):
            types = set(z[n]) | {T["NSEC"], T["RRSIG"]}
            z[n][T["NSEC"]] = [wire_name(names[(i + 1) % len(names)]) + type_bitmap(sorted(types))]
        self.sigs = {}
        for n, rrsets in z.items():
            for t, rds in rrsets.items():
                if n == CHILD and t == T["NS"]:
                    continue  # delegation NS is not authoritative data; unsigned
                sig = signer.rrsig(n, t, rds)
                if n == "bogus." + ZONE and t == T["A"]:
                    sig = sig[:-1] + bytes([sig[-1] ^ 0xFF])  # the fixture serves it bogus
                self.sigs[(n, t)] = [sig]
        self.zone = z
        self.names = names
        self.child = {
            CHILD: {T["SOA"]: [soa(CHILD)], T["NS"]: [wire_name("ns." + ZONE)]},
            "host." + CHILD: {T["A"]: [ip("192.0.2.7")]},
        }

    @staticmethod
    def rr(name, t, rd):
        return wire_name(name) + struct.pack("!HHIH", t, 1, TTL, len(rd)) + rd

    def rrset(self, name, t, do):
        out = [self.rr(name, t, rd) for rd in self.zone[name][t]]
        if do:
            out += [self.rr(name, T["RRSIG"], s) for s in self.sigs.get((name, t), [])]
        return out

    def covering(self, qname):
        prev = self.names[-1]
        for n in self.names:
            if canon_key(n) > canon_key(qname):
                break
            prev = n
        return prev

    def answer(self, q, tcp):
        if len(q) < 12:
            return None
        qid, flags, qdcount, _, _, arcount = struct.unpack("!HHHHHH", q[:12])
        if qdcount != 1:
            return struct.pack("!HHHHHH", qid, 0x8001, 0, 0, 0, 0)  # FORMERR
        qname, off = parse_name(q, 12)
        qtype = struct.unpack("!H", q[off:off + 2])[0]
        question = q[12:off + 4]
        rest, do = q[off + 4:], False
        if arcount and len(rest) >= 11 and rest[0] == 0 and struct.unpack("!H", rest[1:3])[0] == T["OPT"]:
            do = bool(struct.unpack("!I", rest[5:9])[0] & 0x8000)
        if qname == "drop." + ZONE:
            return None  # measurement fixture: the client must time out
        an, ns, rcode, aa, tc = [], [], 0, 0x0400, 0
        in_child = qname == CHILD or qname.endswith("." + CHILD)
        if qname == "servfail." + ZONE:
            rcode, aa = 2, 0
        elif in_child and not (qname == CHILD and qtype == T["DS"]):
            if qname in self.child and qtype in self.child[qname]:
                an = [self.rr(qname, qtype, r) for r in self.child[qname][qtype]]
            else:
                rcode = 0 if qname in self.child else 3
                ns = [self.rr(CHILD, T["SOA"], self.child[CHILD][T["SOA"]][0])]
        elif qname == ZONE or qname.endswith("." + ZONE):
            if qname == "tc." + ZONE and not tcp:
                tc = 0x0200
            elif qname in self.zone and qtype in self.zone[qname]:
                an = self.rrset(qname, qtype, do)
            elif qname in self.zone:  # NODATA
                ns = self.rrset(ZONE, T["SOA"], do)
                if do:
                    ns += self.rrset(qname, T["NSEC"], do)
            else:  # NXDOMAIN; the apex NSEC also denies the wildcard
                rcode = 3
                ns = self.rrset(ZONE, T["SOA"], do)
                if do:
                    cov = self.covering(qname)
                    ns += self.rrset(cov, T["NSEC"], do)
                    if cov != ZONE:
                        ns += self.rrset(ZONE, T["NSEC"], do)
        else:
            rcode, aa = 5, 0  # REFUSED: never recurse, never forward
        ar = [b"\x00" + struct.pack("!HHIH", T["OPT"], 1232, 0x8000 if do else 0, 0)] if arcount else []
        hdr = struct.pack("!HHHHHH", qid, 0x8000 | aa | tc | (flags & 0x0110) | rcode,
                          1, len(an), len(ns), len(ar))
        return hdr + question + b"".join(an + ns + ar)


def cmd_pki(out):
    os.makedirs(out, mode=0o700, exist_ok=False)
    now = datetime.datetime.now(datetime.timezone.utc)
    stamp = lambda d: d.strftime("%Y%m%d%H%M%SZ")  # noqa: E731
    valid = (stamp(now - datetime.timedelta(hours=1)), stamp(now + datetime.timedelta(days=1)))
    ec = ("-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes")

    def path(n, ext):
        return os.path.join(out, n + ext)

    for ca in ("ca", "rogue"):
        openssl("req", "-x509", *ec, "-keyout", path(ca, ".key"), "-out", path(ca, ".pem"),
                "-days", "2", "-subj", "/CN=nice-dns fixture " + ca,
                "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign")
    leaves = {"good": ("ca", TLS_NAME, valid),
              "wrongname": ("ca", "other.fixture.test", valid),
              "expired": ("ca", TLS_NAME, ("20200101000000Z", "20200102000000Z")),
              "untrusted": ("rogue", TLS_NAME, valid)}
    for leaf, (ca, cn, (start, end)) in leaves.items():
        db = os.path.join(out, "db-" + leaf)
        os.mkdir(db, 0o700)
        open(os.path.join(db, "index"), "w").close()
        with open(os.path.join(db, "serial"), "w") as f:
            f.write(os.urandom(8).hex() + "\n")
        with open(path(leaf, ".cnf"), "w") as f:
            f.write("[ca]\ndefault_ca=c\n[c]\ndatabase=%s/index\nnew_certs_dir=%s\n"
                    "serial=%s/serial\ndefault_md=sha256\npolicy=p\ncopy_extensions=none\n"
                    "[p]\ncommonName=supplied\n" % (db, db, db))
        with open(path(leaf, ".ext"), "w") as f:
            f.write("subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n"
                    "basicConstraints=CA:FALSE\n" % cn)
        openssl("req", *ec, "-keyout", path(leaf, ".key"), "-out", path(leaf, ".csr"),
                "-subj", "/CN=" + cn)
        openssl("ca", "-batch", "-config", path(leaf, ".cnf"), "-cert", path(ca, ".pem"),
                "-keyfile", path(ca, ".key"), "-in", path(leaf, ".csr"), "-out", path(leaf, ".pem"),
                "-extfile", path(leaf, ".ext"), "-startdate", start, "-enddate", end, "-notext")
    for n in os.listdir(out):
        if n.endswith(".key"):
            os.chmod(os.path.join(out, n), 0o600)


def cmd_serve(state, tls):
    os.makedirs(state, mode=0o700, exist_ok=True)
    signer = Signer(state)
    zones = Zones(signer)
    b64 = base64.b64encode(signer.pub).decode()
    with open(os.path.join(state, "anchor.bind"), "w") as f:
        f.write('trust-anchors { "%s" static-key 257 3 %d "%s"; };\n' % (ZONE, ALG, b64))
    with open(os.path.join(state, "anchor.unbound"), "w") as f:
        f.write('trust-anchor: "%s DNSKEY 257 3 %d %s"\n' % (ZONE, ALG, b64))

    class UDP(socketserver.BaseRequestHandler):
        def handle(self):
            data, sock = self.request
            r = zones.answer(data, False)
            if r:
                sock.sendto(r, self.client_address)

    class Stream(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                while True:
                    hdr = self._read(2)
                    if hdr is None:
                        return
                    msg = self._read(struct.unpack("!H", hdr)[0])
                    if msg is None:
                        return
                    r = zones.answer(msg, True)
                    if not r:
                        return
                    self.request.sendall(struct.pack("!H", len(r)) + r)
            except (OSError, ssl.SSLError):
                return

        def _read(self, n):
            buf = b""
            while len(buf) < n:
                chunk = self.request.recv(n - len(buf))
                if not chunk:
                    return None
                buf += chunk
            return buf

    class TCPServer(socketserver.ThreadingTCPServer):
        daemon_threads = True

    class UDPServer(socketserver.ThreadingUDPServer):
        daemon_threads = True

    def tls_server(ctx):
        class TLSServer(TCPServer):
            def get_request(self):
                sock, addr = super().get_request()
                sock.settimeout(10)
                return ctx.wrap_socket(sock, server_side=True), addr
        return TLSServer(("127.0.0.1", 0), Stream)

    # UDP and TCP share one port; retry if the TCP side is taken.
    for _ in range(20):
        udp = UDPServer(("127.0.0.1", 0), UDP)
        try:
            tcp = TCPServer(("127.0.0.1", udp.server_address[1]), Stream)
            break
        except OSError:
            udp.server_close()
    else:
        raise SystemExit("could not bind matching UDP/TCP ports")
    ports, servers = [("dns", udp.server_address[1])], [udp, tcp]
    for spec in tls or []:
        name, cert, key = spec.split(":", 2)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        srv = tls_server(ctx)
        ports.append(("dot-" + name, srv.server_address[1]))
        servers.append(srv)
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    tmp = os.path.join(state, "ports.tsv.tmp")
    with open(tmp, "w") as f:
        f.writelines("%s\t%d\n" % p for p in ports)
    os.rename(tmp, os.path.join(state, "ports.tsv"))
    while True:
        time.sleep(3600)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pki")
    p.add_argument("--out", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--state", required=True)
    s.add_argument("--tls", action="append", metavar="NAME:CERT:KEY")
    a = ap.parse_args()
    os.umask(0o077)
    if a.cmd == "pki":
        cmd_pki(a.out)
    else:
        cmd_serve(a.state, a.tls)


if __name__ == "__main__":
    main()
