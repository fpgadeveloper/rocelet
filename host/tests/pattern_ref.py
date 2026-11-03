#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""The rocelet test payload pattern (the reference designs' traffic generator and data
checker produce it; first defined as rl_sys_pkg::pat_beat in the research prototype):

    x               = a ^ {seed, ~seed}
    beat[63:0]      = a
    beat[64i +: 64] = x + K[i]          i = 1..7

Byte j of a 512-bit AXI-Stream beat is tdata[8j +: 8] and is the j-th byte on
the wire / in memory, so every 64-bit word is stored little endian.

  pattern_ref.py --addr 0x10000000000 --seed 0x5eed1234 [--len 64]   hex dump
  pattern_ref.py --check ./rocelet_host       compare with `rocelet_host pattern`
"""
import argparse
import random
import struct
import subprocess
import sys

K = [0x0000000000000000, 0x9E3779B97F4A7C15, 0x3C6EF372FE94F82A, 0xDAA66D2C7DDF743F,
     0x78DDE6E5FD29F054, 0x1715609F7C746C69, 0xB54CDA58FBBEE87E, 0x538454127B096493]
M64 = (1 << 64) - 1


def pat_beat(a, seed):
    x = a ^ (((seed & 0xFFFFFFFF) << 32) | (~seed & 0xFFFFFFFF))
    words = [a & M64] + [(x + K[i]) & M64 for i in range(1, 8)]
    return b"".join(struct.pack("<Q", w) for w in words)


def pattern(addr, length, seed):
    """Bytes of a region with pattern address addr (beat k = pat_beat(addr + 64k))."""
    out = bytearray()
    off = 0
    while off < length:
        out += pat_beat(addr + off, seed)[: min(64, length - off)]
        off += 64
    return bytes(out)


def dump(addr, data):
    lines = []
    for j in range(0, len(data), 16):
        lines.append("%016x: %s" % (addr + j, " ".join("%02x" % b for b in data[j:j + 16])))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--addr", type=lambda s: int(s, 0), default=0x10000000000)
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x5EED1234)
    ap.add_argument("--len", type=lambda s: int(s, 0), default=64)
    ap.add_argument("--check", metavar="RL_HOST", help="compare with `RL_HOST pattern` output")
    a = ap.parse_args()
    if not a.check:
        print(dump(a.addr, pattern(a.addr, a.len, a.seed)))
        return 0
    rng = random.Random(1)
    cases = [(0x10000000000, 0x5EED1234, 64), (0, 0, 128), (0x7F3E40000000, 0xFFFFFFFF, 256),
             (0x1234567, 7, 100), (M64 - 63, 0x80000000, 64)]
    cases += [(rng.getrandbits(64) & ~63, rng.getrandbits(32), 64 * rng.randint(1, 4)) for _ in range(20)]
    bad = 0
    for addr, seed, length in cases:
        got = subprocess.run([a.check, "pattern", "--addr", hex(addr), "--seed", hex(seed),
                              "--len", str(length)], capture_output=True, text=True, check=True).stdout.strip()
        exp = dump(addr, pattern(addr, length, seed))
        if got != exp:
            bad += 1
            print("MISMATCH addr 0x%x seed 0x%x len %d\n--- rocelet_host\n%s\n--- python\n%s" % (addr, seed, length, got, exp))
    print("pattern_ref: %d cases, %s" % (len(cases), "FAIL" if bad else "PASS"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
