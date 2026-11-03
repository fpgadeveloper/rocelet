#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_icrc.py - RoCE v2 ICRC generator and checker (rocelet_icrc_tx / rocelet_icrc_rx, xsim
# tb_icrc): frames from roce_ref.py (ICRC cross-checked against scapy.contrib.roce), random
# input gaps and output back-pressure; good frames, frames with only ICRC-masked fields
# changed (must stay good), changed Ethernet addresses (not covered), single bit flips in
# covered bytes (must fail), Ethernet-padded short frames; GRAN 4 (RoCE lengths) and 1
# (any length); the VLAN-aware (OFF_MODE 1) and programmable-offset (OFF_MODE 2) variants.
# Usage: test_icrc.py [nframes] [seed] [gap %] [bp %] [share 0/1]
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import roce_ref as R  # noqa: E402
import simlib as S  # noqa: E402

FILES = S.files('common/rocelet_crc32_xor.sv', 'common/rocelet_crc32_inv.sv', 'common/rocelet_keep2n.sv',
                'common/rocelet_fifo.sv', 'common/rocelet_crc32_core.sv', 'icrc/rocelet_icrc_mask.sv',
                'icrc/rocelet_icrc_tx.sv', 'icrc/rocelet_icrc_rx.sv', 'tb_icrc.sv')

GAP, BP = 20, 20
SHARE = 1


def run(mode, gran, rem, frames_in, tag, seed, gap=None, bp=None, off_mode=0, offs=None):
    gap = GAP if gap is None else gap
    bp = BP if bp is None else bp
    d = os.path.join(S.BUILD, 'icrc_s%d' % SHARE)
    os.makedirs(d, exist_ok=True)
    fin = os.path.join(d, 'in_%s.txt' % tag)
    fout = os.path.join(d, 'out_%s.txt' % tag)
    R.write_beats(fin, frames_in, offs=offs if off_mode == 2 else None)
    g = dict(MODE=mode, GRAN=gran, REM=rem, OFF_MODE=off_mode, SHARE=SHARE)
    out, log = S.xsim(os.path.join(d, 'm%d_g%d_o%d' % (mode, gran, off_mode)), 'tb_icrc', g, FILES,
                      ['in=' + fin, 'out=' + fout, 'seed=%d' % seed, 'gap=%d' % gap, 'bp=%d' % bp])
    print('   ', out.replace('\n', ' | '))
    if 'TB_DONE' not in out:
        raise SystemExit('simulation failed (%s)' % tag)
    return fout


def mutate(fr, rng):
    """Return (frame, expected_ok, kind)."""
    k = rng.random()
    if k < 0.25:
        return fr, True, 'good'
    if k < 0.45:
        return R.mutate_variant_fields(fr, rng), True, 'variant-fields'
    if k < 0.55:
        f = bytearray(fr)
        for i in range(12):
            f[i] = rng.getrandbits(8)
        return bytes(f), True, 'eth-mac'
    f = bytearray(fr)
    # flip one bit in a covered, non-masked byte (IP header start .. end)
    ipv6 = fr[12:14] == b'\x86\xdd'
    masked = ({15, 16, 17, 21, 60, 61, 66} if ipv6 else {15, 22, 24, 25, 40, 41, 46})
    while True:
        pos = rng.randrange(14, len(fr))
        if pos in masked or (ipv6 and pos == 14):
            continue
        break
    f[pos] ^= 1 << rng.randrange(8)
    return bytes(f), False, 'bitflip@%d' % pos


def main():
    nframes = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    global GAP, BP, SHARE
    GAP = int(sys.argv[3]) if len(sys.argv) > 3 else 20
    BP = int(sys.argv[4]) if len(sys.argv) > 4 else 20
    SHARE = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    rng = random.Random(seed)
    R.selftest()
    frames = []
    for i in range(nframes):
        mp = rng.choice([64, 300, 1500, 4096])
        frames.append(R.random_roce_frame(rng, max_payload=mp))
    # the shortest frames: zero-length SEND ONLY (58 B IPv4), ACK, READ_REQ
    frames.append(R.build_frame(R.OP['SEND_ONLY'], b''))
    frames.append(R.build_frame(R.OP['SEND_ONLY'], b'', ipv6=True))
    frames.append(R.build_frame(R.OP['ACK'], b'', syndrome=0, msn=5))
    frames.extend(R.GOLDEN)          # golden vectors
    sizes = [len(f) for f in frames]
    print('frames: %d, %d..%d bytes, %d IPv6' % (len(frames), min(sizes), max(sizes),
          sum(f[12:14] == b'\x86\xdd' for f in frames)))
    fails = 0
    for gran, rem in ((4, 2), (1, 0)):
        # ---- MODE 0: ICRC generation ----
        print('MODE 0 rocelet_icrc_tx GRAN=%d SHARE=%d' % (gran, SHARE))
        fout = run(0, gran, rem, [f[:-4] for f in frames], 'tx_g%d' % gran, seed)
        got = [g for g, _ in R.read_beats(fout)]
        bad = sum(1 for a, b in zip(got, frames) if a != b) + abs(len(got) - len(frames))
        print('    %d frames out, %d mismatches' % (len(got), bad))
        fails += bad
        # ---- MODE 1/2: ICRC check ----
        rx, exp, kinds = [], [], []
        for f in frames:
            m, ok, kind = mutate(f, rng)
            rx.append(m); exp.append(ok); kinds.append(kind)
        # Ethernet-padded short frames (58 -> 60 bytes), still good
        for f in frames[-5:]:
            if len(f) < 60:
                rx.append(f + b'\x00' * (60 - len(f))); exp.append(True); kinds.append('padded')
        for mode in (1, 2):
            print('MODE %d rocelet_icrc_rx PASS_DATA=%d GRAN=%d' % (mode, mode == 1, gran))
            fout = run(mode, gran, rem, rx, 'rx%d_g%d' % (mode, gran), seed + mode)
            if mode == 1:
                outs = R.read_beats(fout)
                got_frames = [g for g, _ in outs]
                verdict = [x[0] == '0' for _, x in outs]
                bad = sum(1 for a, b in zip(got_frames, rx) if a != b)
            else:
                verdict = [l.strip() == '1' for l in open(fout) if l.strip()]
                bad = 0
            bad += abs(len(verdict) - len(exp))
            vb = [(k, e, v) for k, e, v in zip(kinds, exp, verdict) if e != v]
            bad += len(vb)
            print('    %d verdicts (%d good expected), %d mismatches %s' % (
                len(verdict), sum(exp), bad, vb[:5]))
            fails += bad
    # ---- programmable ICRC start: VLAN (OFF_MODE 1) and any offset (OFF_MODE 2) ----
    for off_mode, gran, rem in ((1, 4, 2), (2, 1, 0)):
        tx_in, tx_exp, rx, rx_exp, offs = [], [], [], [], []
        for f in frames:
            if off_mode == 1:
                extra = (b'\x81\x00' + bytes([rng.getrandbits(8), rng.getrandbits(8)])) if rng.random() < 0.5 else b''
            else:
                extra = bytes(rng.getrandbits(8) for _ in range(rng.randint(0, 26)))
            g = R.add_l2(f, extra)
            off = 14 + len(extra)
            assert R.icrc_ok(g, off)
            tx_in.append(g[:-4]); tx_exp.append(g); offs.append(off)
            h = bytearray(g)
            ok = True
            if rng.random() < 0.4:
                pos = rng.randrange(off + 20 if g[off - 2:off] == b'\x08\x00' else off + 40, len(g))
                h[pos] ^= 1 << rng.randrange(8)
                ok = R.icrc_ok(bytes(h), off)
            rx.append(bytes(h)); rx_exp.append(ok)
        print('OFF_MODE %d rocelet_icrc_tx GRAN=%d' % (off_mode, gran))
        fout = run(0, gran, rem, tx_in, 'tx_off%d' % off_mode, seed, off_mode=off_mode, offs=offs)
        got = [g for g, _ in R.read_beats(fout)]
        bad = sum(1 for a, b in zip(got, tx_exp) if a != b) + abs(len(got) - len(tx_exp))
        print('    %d frames out, %d mismatches' % (len(got), bad))
        fails += bad
        print('OFF_MODE %d rocelet_icrc_rx verdict GRAN=%d' % (off_mode, gran))
        fout = run(2, gran, rem, rx, 'rx_off%d' % off_mode, seed, off_mode=off_mode, offs=offs)
        verdict = [l.strip() == '1' for l in open(fout) if l.strip()]
        bad = sum(1 for a, b in zip(verdict, rx_exp) if a != b) + abs(len(verdict) - len(rx_exp))
        print('    %d verdicts (%d good expected), %d mismatches' % (len(verdict), sum(rx_exp), bad))
        fails += bad
    print('ICRC TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
