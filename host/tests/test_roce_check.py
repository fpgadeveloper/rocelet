#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""Tests for roce_check.py without hardware: the two golden ICRC vectors of
the research study (scapy and an independent zlib model), scapy-built frame streams that
must pass, and deliberately broken streams that must fail in the expected way.
Run: python3 -I tests/test_roce_check.py
"""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "..", "roce_check.py")
sys.path.insert(0, os.path.join(HERE, ".."))
import roce_check as rc  # noqa: E402

from scapy.all import Ether, IP, UDP, Raw, wrpcap  # noqa: E402
from scapy.contrib.roce import BTH, AETH  # noqa: E402

FPGA_MAC, HOST_MAC = "02:0a:35:72:6c:01", "6c:fe:54:91:77:f0"
FPGA_IP, HOST_IP = "192.168.20.2", "192.168.20.1"
SEED = 0x5EED1234
fails = 0


def ok(cond, what):
    global fails
    print("%s  %s" % ("PASS" if cond else "FAIL", what))
    if not cond:
        fails += 1


def frame(op, psn, dqpn, payload=b"", ext=b"", ackreq=0, mig=1, pad=None, sport=0xC123,
          src=FPGA_IP, dst=HOST_IP, ttl=64, tos=0, icrc=None):
    if pad is None:
        pad = (-len(payload)) % 4
    p = (Ether(src=FPGA_MAC if src == FPGA_IP else HOST_MAC, dst=HOST_MAC if src == FPGA_IP else FPGA_MAC)
         / IP(src=src, dst=dst, flags="DF", ttl=ttl, tos=tos, id=0)
         / UDP(sport=sport, dport=4791, chksum=0)
         / BTH(opcode=op, migreq=mig, padcount=pad, dqpn=dqpn, ackreq=ackreq, psn=psn, icrc=icrc)
         / Raw(ext + payload + b"\0" * pad))
    return bytes(p)


def reth(va, rkey, length):
    return struct.pack("!QII", va, rkey, length)


def write_msg(psn, dqpn, va, length, pmtu, ackreq_every=0):
    """RDMA WRITE of `length` bytes at VA as FIRST/MIDDLE/LAST or ONLY; payload = pattern(VA)."""
    out = []
    data = rc.pattern(va, length, SEED)
    npk = max(1, -(-length // pmtu))
    for i in range(npk):
        chunk = data[i * pmtu:(i + 1) * pmtu]
        last = i == npk - 1
        if npk == 1:
            op, ext = 0x0A, reth(va, 0x12ab, length)
        elif i == 0:
            op, ext = 0x06, reth(va, 0x12ab, length)
        elif last:
            op, ext = 0x08, b""
        else:
            op, ext = 0x07, b""
        ar = 1 if last or (ackreq_every and (i + 1) % ackreq_every == 0) else 0
        out.append(frame(op, (psn + i) & 0xFFFFFF, dqpn, chunk, ext, ackreq=ar))
    return out


def ack(psn, msn, qpn=0x100, syn=0x1F):
    return frame(0x11, psn, qpn, b"", struct.pack("!I", (syn << 24) | msn), mig=0, src=HOST_IP, dst=FPGA_IP,
                 sport=0xD001)


def run(frames, *args, hexmode=False):
    with tempfile.TemporaryDirectory() as d:
        if hexmode:
            path = os.path.join(d, "cap.txt")
            with open(path, "w") as f:
                f.write(frames)
            cmd = [sys.executable, "-I", CHECK, "--hex", path] + list(args)
        else:
            path = os.path.join(d, "cap.pcap")
            wrpcap(path, [Ether(f) for f in frames])
            cmd = [sys.executable, "-I", CHECK, path] + list(args)
        r = subprocess.run(cmd, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr


def main():
    # 1. golden vectors (generated with scapy 2.5 and a zlib model on 2026-10-20)
    g1 = bytes.fromhex("0c42a1000001000a350621a008004502004c000040004011914bc0a81402c0a81401c12312b70038"
                       "00000a00ffff000001238000001000000000000010001234567800000010000102030405060708090a"
                       "0b0c0d0e0f" "a94b580d")
    g2 = bytes.fromhex("0c42a1000001000a350621a00800450200300000400040119167c0a81402c0a81401c12312b7001c"
                       "00001100ffff00000123800000101f000001" "05b80dfb")
    for name, g in (("WRITE Only", g1), ("ACK", g2)):
        ip = g[14:]
        ok(rc.icrc_model(ip[:-4]) == ip[-4:], "golden %s: model ICRC" % name)
        ok(rc.icrc_scapy(g, 4791) == ip[-4:], "golden %s: scapy ICRC" % name)
    code, out = run([g1, g2], "--pmtu", "4096")
    ok(code == 0 and "2 ok, 0 BAD" in out, "golden vectors pass roce_check")

    # 2. a clean FPGA -> host stream: 3 multi-packet WRITEs (PMTU 1024) + one 13-byte WRITE
    #    Only (pad 3) + host ACKs; MigReq 1, payload = pattern(VA)
    pmtu, va, psn = 1024, 0x7F3E40000000, 0x123
    good = []
    for m in range(3):
        good += write_msg(psn, 0x1B, va + m * 4096, 4096, pmtu)
        psn += 4
        good.append(ack(psn - 1, m + 1))
    good += write_msg(psn, 0x1B, va + 3 * 4096, 13, pmtu)
    good.append(ack(psn, 4))
    code, out = run(good, "--pmtu", str(pmtu), "--seed", hex(SEED), "--src", FPGA_IP, "--expect-migreq", "1")
    ok(code == 0 and "result: PASS" in out and "payload pattern: 13 ok, 0 BAD" in out,
       "clean FPGA stream passes (pattern, PMTU, pad, ICRC)")
    code, out = run(good, "--pmtu", str(pmtu))
    ok(code == 0 and "MSN" in out, "clean stream incl. host ACKs passes")

    # 3. one corrupted ICRC
    bad = list(good)
    b = bytearray(bad[1])
    b[-1] ^= 0x01
    bad[1] = bytes(b)
    code, out = run(bad, "--pmtu", str(pmtu))
    ok(code == 1 and "1 BAD" in out, "corrupted ICRC is detected")

    # 4. corrupted payload with a *recomputed* ICRC: ICRC ok, pattern check catches it
    f = Ether(good[0])
    raw = bytearray(bytes(f[Raw]))
    raw[100] ^= 0xFF
    f[Raw].load = bytes(raw)
    f[BTH].icrc = None
    bad2 = [bytes(f)] + good[1:]
    code, out = run(bad2, "--pmtu", str(pmtu), "--seed", hex(SEED))
    ok(code == 1 and "payload != pattern" in out, "payload corruption caught by the pattern check")

    # 5. capture mode: IPv4 header checksum deliberately wrong (masked by the ICRC)
    cm = []
    for g in good[:4]:
        b = bytearray(g)
        b[25] ^= 0x01                      # IPv4 checksum low byte, as rl_inj byte 25 would
        cm.append(bytes(b))
    code, out = run(cm, "--pmtu", str(pmtu))
    ok(code == 1 and "header checksum" in out, "bad IPv4 checksum is an error by default")
    code, out = run(cm, "--pmtu", str(pmtu), "--expect-bad-ipcsum")
    ok(code == 0 and "4 ok, 0 BAD" in out and "4 frames with the expected bad IPv4 checksum" in out,
       "capture mode: ICRC still valid with the IPv4 checksum flipped")

    # 6. PSN gap (a lost packet) is an error, a go-back-N retransmission is not
    gap = good[:1] + good[2:4]
    code, out = run(gap, "--pmtu", str(pmtu))
    ok(code == 1 and "PSN gap" in out, "PSN gap detected")
    retx = good[:3] + write_msg(0x123 + 1, 0x1B, va + 1024, 3072, pmtu)[0:0] + good[1:5]
    # rebuild: FIRST, MIDDLE, MIDDLE, then go back to PSN 0x124 (MIDDLE) and finish the message
    retx = good[0:3] + good[1:4]
    code, out = run(retx, "--pmtu", str(pmtu), "--src", FPGA_IP)
    ok(code == 0 and "retransmissions 1" in out, "go-back-N retransmission accepted and counted")

    # 7. header violations: MigReq 0 warning, P_Key, TVer, DF missing, UDP checksum, PadCnt on FIRST
    b = Ether(good[0])
    b[IP].flags = 0
    b[IP].chksum = None
    b[BTH].icrc = None
    code, out = run([bytes(b)], "--pmtu", str(pmtu))
    ok(code == 0 and "IPv4 flags/fragment" in out and "warn" in out, "DF=0 is a warning")
    b = Ether(good[0])
    b[BTH].pkey = 0x7FFF
    b[BTH].icrc = None
    code, out = run([bytes(b)], "--pmtu", str(pmtu))
    ok(code == 1 and "P_Key" in out, "P_Key != 0xFFFF is an error")
    b = Ether(good[0])
    b[BTH].padcount = 2
    b[BTH].icrc = None
    code, out = run([bytes(b)], "--pmtu", str(pmtu))
    ok(code == 1 and "PadCnt" in out, "PadCnt on FIRST is an error")
    b = Ether(good[1])
    b[Raw].load = bytes(b[Raw])[:-64]
    b[IP].len = None
    b[IP].chksum = None
    b[UDP].len = None
    b[BTH].icrc = None
    code, out = run([bytes(b)], "--pmtu", str(pmtu))
    ok(code == 1 and "must equal PMTU" in out, "short MIDDLE packet is an error")
    code, out = run(good[:4], "--pmtu", str(pmtu), "--expect-migreq", "0")
    ok(code == 0 and "MigReq 1 (expected 0)" in out, "MigReq expectation warning")

    # 8. hex dumps (FPGA console capture formats)
    h1 = "\n".join(g.hex() for g in (g1, g2)) + "\n"
    code, out = run(h1, hexmode=True)
    ok(code == 0 and "2 ok, 0 BAD" in out, "hex dump: one frame per line")
    blocks = ""
    for g in (g1, g2):
        blocks += "rl> cap dump\nCAPF len=%d\n" % len(g)
        for o in range(0, len(g), 32):
            blocks += "%04x: %s\n" % (o, " ".join("%02x" % x for x in g[o:o + 32]))
        blocks += "CAPE\n"
    code, out = run(blocks, hexmode=True)
    ok(code == 0 and "2 ok, 0 BAD" in out, "hex dump: CAPF/offset/CAPE blocks")
    trunc = "CAPF len=%d\n%s\nCAPE\n" % (len(g1) + 100, g1.hex())
    code, out = run(trunc, hexmode=True)
    ok("1 not checkable" in out, "hex dump: truncated capture is reported, not failed")

    # 9. CNP is accepted (counted, not an error)
    cnp = bytes(Ether(src=HOST_MAC, dst=FPGA_MAC) / IP(src=HOST_IP, dst=FPGA_IP, flags="DF")
                / UDP(sport=0xD001, dport=4791, chksum=0) / BTH(opcode=0x81, becn=1, dqpn=0x100)
                / Raw(b"\0" * 16))
    code, out = run([cnp])
    ok(code == 0 and "CNP 1" in out, "CNP parsed")

    print("test_roce_check: %s" % ("FAIL (%d)" % fails if fails else "PASS"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
