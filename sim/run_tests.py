#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# run_tests.py - the rocelet simulation regression (Vivado xsim + Python models). Runs every
# test with the arguments below, prints one line per test and a summary, and exits non-zero
# if any test fails. --quick uses smaller workloads; -k <substring> selects tests.
# Needs Vivado 2025.x (xvlog / xelab / xsim on PATH or VIVADO_SETTINGS) and Python 3 with
# scapy (pip install scapy). Build products: sim/build (git-ignored).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# name: (script, full arguments, quick arguments, what it covers)
TESTS = [
    ('regs_generated', 'regs', ['--check'], ['--check'],
     'register map files are up to date with regs/rocelet_regs.py'),
    ('bd_wrapper', 'wrapper', ['--check'], ['--check'],
     'rtl/rocelet_bd.v is up to date with rocelet_top.sv'),
    ('host_tools', 'host', [], [],
     'host tools build (-Werror) and their selftests (skipped without libibverbs headers)'),
    ('roce_ref', 'roce_ref.py', [], [],
     'reference model: ICRC vs scapy.contrib.roce, golden vectors'),
    ('icrc_share', 'test_icrc.py', ['100', '6', '20', '20', '1'], ['40', '6', '20', '20', '1'],
     'ICRC generator / checker, shared CRC network'),
    ('icrc_split', 'test_icrc.py', ['60', '3', '0', '0', '0'], ['30', '3', '0', '0', '0'],
     'ICRC generator / checker, split CRC network, no gaps'),
    ('req_tx', 'test_req_tx.py', ['150', '7'], ['60', '7'],
     'requester segmentation RC / UC / HSB, HSB byte-exact vs NVIDIA format, scapy'),
    ('resp_core', 'test_resp.py', ['300', '3'], ['120', '3'],
     'RC responder vs model: WRITE/SEND/READ, dup/OOS/NAK, RNR NAK, READ continuation'),
    ('resp_top', 'test_resp.py', ['--top', '300', '5'], ['--top', '120', '5'],
     'responder through rocelet_top: MAC glue, AXI-Lite, AXI4 memory, PAUSE'),
    ('read_reissue', 'test_read_reissue.py', ['300', '1'], ['120', '1'],
     'READ responder vs a closed-loop requester losing responses: fast re-issue (CX-6) / re-issue after a timeout'),
    ('pair_core', 'test_pair.py', ['100', '5', '50'], ['40', '5', '50'],
     'two engines over a lossy link: go-back-N ring/reread, RNR, UC/HSB mix, flush, lossy'),
    ('pair_top', 'test_pair.py', ['--top', '100', '5', '50'], ['--top', '40', '5', '50'],
     'two rocelet_top: + PAUSE both ways, VID-0 tags, ARP/ICMP, other-traffic ports'),
    ('link_down', 'test_pair.py', ['100', '5', '0', 'link_down', 'link_nohold'],
     ['40', '5', '0', 'link_down', 'link_nohold'],
     'link_up low for 1.2 M ticks + partner silent in LINK_GRACE: ACK timeouts held, 1 per QP after, no loss'),
    ('axi_mem', 'test_axi_mem.py', ['300', '1'], ['100', '1'],
     'AXI4 master: 4 KB splits, out-of-order IDs, READ-after-WRITE ordering'),
    ('vlan', 'test_vlan.py', [], [],
     'VLAN tag insert / strip, 3000 random frames'),
]


def main():
    args = sys.argv[1:]
    quick = '--quick' in args
    sel = None
    if '-k' in args:
        sel = args[args.index('-k') + 1]
    results = []
    t_all = time.time()
    for name, script, full, qargs, what in TESTS:
        if sel and sel not in name:
            continue
        if script == 'regs':
            cmd = [sys.executable, '-I', os.path.join(ROOT, 'regs', 'rocelet_regs.py')] + full
        elif script == 'wrapper':
            cmd = [sys.executable, '-I', os.path.join(ROOT, 'scripts', 'gen_bd_wrapper.py')] + full
        elif script == 'host':
            if not os.path.exists('/usr/include/infiniband/verbs.h'):
                print('%-16s SKIP           %s' % (name, what), flush=True)
                continue
            cmd = ['make', '-s', '-C', os.path.join(ROOT, 'host'), 'test']
        else:
            cmd = [sys.executable, '-I', os.path.join(HERE, script)] + (qargs if quick else full)
        t0 = time.time()
        r = subprocess.run(cmd, capture_output=True, text=True)
        dt = time.time() - t0
        ok = r.returncode == 0
        last = [l for l in r.stdout.strip().splitlines() if l.strip()]
        results.append((name, ok, dt, what))
        print('%-16s %s  %6.0f s  %s' % (name, 'PASS' if ok else 'FAIL', dt, what), flush=True)
        if not ok:
            print('\n'.join('    ' + l for l in (last[-15:] + r.stderr.strip().splitlines()[-5:])))
    nfail = sum(1 for r in results if not r[1])
    print('REGRESSION %s: %d tests, %d failed, %.0f min%s' % ('PASS' if nfail == 0 else 'FAIL', len(results), nfail,
                                                            (time.time() - t_all) / 60, ' (quick)' if quick else ''))
    return 1 if nfail else 0


if __name__ == '__main__':
    sys.exit(main())
