#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_pause.py - 802.3x PAUSE timing through rocelet_top at 10G, 25G, 40G and 100G (xsim,
# tb_top_pause, clock at the configured frequency): CAPS / CLK_KHZ / PAUSE_QCLK reset values,
# the TX hold of received quanta (1 ... 65535) against 512 bit times x quanta at the link
# speed (within one clock plus the rounding of PAUSE_QCLK), XON, PAUSE_QCLK rewritten by
# firmware, level mode (mac_pause_hold), and no TX frame starting while paused.
# Usage: test_pause.py [config...]   (10g 25g 40g 100g)
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import simlib as S  # noqa: E402

FILES = S.top_files('tb_top_pause.sv')

# name: (CLK_MHZ, CLK_KHZ, LINK_GBPS, MAC_WIDTH) - the MAC user clocks of real MACs
CONFIGS = {
    '10g':  (156, 156250, 10, 64),     # 10GBASE-R, 64 bits @ 156.25 MHz (omac_10g)
    '25g':  (391, 390625, 25, 64),     # 25GBASE-R, 64 bits @ 390.625 MHz (omac_10g SPEED 25)
    '40g':  (156, 156250, 40, 256),    # 40GBASE-R4, 256 bits @ 156.25 MHz (omac_40g)
    '100g': (322, 322266, 100, 512),   # 100G CMAC, 512 bits @ 322.27 MHz
}


def run(name):
    mhz, khz, gbps, w = CONFIGS[name]
    d = os.path.join(S.BUILD, 'top_pause_' + name)
    out, log = S.xsim(d, 'tb_top_pause', dict(CLK_MHZ=mhz, CLK_KHZ=khz, LINK_GBPS=gbps, MAC_WIDTH=w), FILES)
    lines = [l for l in log.splitlines() if l.startswith('TB_')]
    bad = 0
    if 'TB_DONE errors=0' not in log or 'TB_ERROR' in log or 'TB_TIMEOUT' in log:
        print('  %s' % [l for l in lines if 'ERROR' in l or 'DONE' in l or 'TIMEOUT' in l][:5])
        bad += 1
    tclk = 1e6 / khz                       # ns per clock
    quantum = 512.0 / gbps                 # ns per quantum
    qclk = (131072 * khz + gbps * 10**6 - 1) // (gbps * 10**6)
    caps = dict(re.findall(r'TB_CAPS (\w+)=(\w+)', log))
    exp = dict(version='00000300', caps='%08x' % ((gbps << 16) | w), clk_khz=str(khz), pause_qclk=str(qclk))
    if caps != exp:
        print('  capability registers %s, expected %s' % (caps, exp))
        bad += 1
    worst = 0.0
    for q, ns in re.findall(r'TB_Q q=(\d+) ns=([\d.]+)', log):
        q, ns = int(q), float(ns)
        want = q * quantum
        # the timer holds floor(q x PAUSE_QCLK / 256) clocks (PAUSE_QCLK rounded up), +-1
        # clock for the registered gate
        lo, hi = want - tclk * 1.01, want * (1 + 1.0 / qclk) + tclk * 1.01
        if q >= 100:
            worst = max(worst, abs(ns - want) / want * 100)
        if not (lo <= ns <= hi):
            print('  %d quanta: held %.1f ns, expected %.1f ns (%.1f .. %.1f)' % (q, ns, want, lo, hi))
            bad += 1
    m = re.search(r'TB_Q2 q=1000 ns=([\d.]+)', log)
    if not m or abs(float(m.group(1)) - 2000 * quantum) > 2000 * quantum / qclk + 2 * tclk:
        print('  PAUSE_QCLK x 2: %s ns for 1000 quanta, expected %.1f' % (m.group(1) if m else '-', 2000 * quantum))
        bad += 1
    m = re.search(r'TB_XON ns=[\d.]+ clocks=([\d.]+)', log)
    if not m or not (200 <= float(m.group(1)) <= 210):
        print('  XON: PAUSE ended after %s clocks, expected about 202' % (m.group(1) if m else '-'))
        bad += 1
    m = re.search(r'TB_LEVEL clocks=([\d.]+)', log)
    if not m or not (499 <= float(m.group(1)) <= 501):
        print('  level mode: gate high %s clocks, expected 500' % (m.group(1) if m else '-'))
        bad += 1
    m = re.search(r'TB_TXHOLD first_tx_after_gate_ns=([\d.]+)', log)
    if not m or float(m.group(1)) > 20 * tclk:
        print('  TX hold: first TX beat %s ns after the gate dropped' % (m.group(1) if m else 'never'))
        bad += 1
    print('[%s] %d MHz, %dG, %d-bit MAC: quantum %.2f ns = %.3f clocks, PAUSE_QCLK %d, hold within %.3f %% of 512 bit times x quanta (100+ quanta); %s' % (
        name, round(khz / 1000), gbps, w, quantum, quantum / tclk, qclk, worst, 'ok' if bad == 0 else 'FAIL'))
    return bad


def main():
    names = sys.argv[1:] or list(CONFIGS)
    fails = sum(run(n) for n in names)
    print('PAUSE TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
