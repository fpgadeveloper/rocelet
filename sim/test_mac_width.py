#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_mac_width.py - the MAC width converters (rtl/mac/rocelet_mac_width.sv) at 64, 128 and
# 256 bits, in xsim (tb_mac_width, self-checking): RX packing with tvalid gaps, partial last
# beats, the bad-frame flag and an abort; TX unpacking with MAC back-pressure, no gap inside
# a frame, and full rate back to back.
# Usage: test_mac_width.py [frames] [seed] [width...]
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import simlib as S  # noqa: E402

FILES = S.files('mac/rocelet_mac_width.sv', 'tb_mac_width.sv')


def run(w, nf, seed):
    d = os.path.join(S.BUILD, 'mac_width_%d' % w)
    out, _ = S.xsim(d, 'tb_mac_width', dict(MAC_W=w), FILES,
                    ['seed=%d' % seed, 'nf=%d' % nf, 'gap=25', 'bp=25'])
    print('[%d bits] %s' % (w, out.replace('\n', ' | ')))
    m = re.search(r'TB_DONE .* errors=(\d+)', out)
    return 0 if (m and int(m.group(1)) == 0 and 'TB_ERROR' not in out) else 1


def main():
    a = sys.argv[1:]
    nf = int(a[0]) if len(a) > 0 else 500
    seed = int(a[1]) if len(a) > 1 else 1
    widths = [int(x) for x in a[2:]] or [64, 128, 256]
    fails = sum(run(w, nf, seed) for w in widths)
    print('MAC WIDTH TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
