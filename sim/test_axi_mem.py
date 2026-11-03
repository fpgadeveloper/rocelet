#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_axi_mem.py - rocelet_axi_mem (the AXI4 memory master) against axi_slave_model:
# write / read packets of 1..4096 bytes with 4 KB splits, random back-pressure and latency,
# out-of-order read IDs, READ-after-WRITE ordering on source 0 (self-checking tb_axi_mem).
# Usage: test_axi_mem.py [packets] [seed]
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import simlib as S  # noqa: E402

FILES = S.files('common/rocelet_fifo.sv', 'mem/rocelet_axi_mem.sv') + \
    [os.path.join(HERE, 'axi_slave_model.sv'), os.path.join(HERE, 'tb_axi_mem.sv')]


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    fails = 0
    for bp, lat in ((20, 8), (50, 60), (0, 0)):
        d = os.path.join(S.BUILD, 'axi_mem')
        out, log = S.xsim(d, 'tb_axi_mem', {}, FILES, ['n=%d' % n, 'seed=%d' % seed, 'axi_bp=%d' % bp,
                                                      'axi_lat=%d' % lat])
        print('[bp %d lat %d] %s' % (bp, lat, out.replace('\n', ' | ')))
        m = re.search(r'errors=(\d+)', out)
        if 'TB_DONE' not in out or not m or int(m.group(1)) != 0:
            fails += 1
    print('AXI_MEM TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
