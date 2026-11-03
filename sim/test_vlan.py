#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_vlan.py - rocelet_vlan_ins -> rocelet_vlan_strip with 3000 random frames (14..600
# bytes, random gaps and back-pressure): VID-0 tags inserted and removed byte-exactly,
# VID != 0 tags passed, untagged frames unchanged (self-checking tb_vlan).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import simlib as S  # noqa: E402


def main():
    out, log = S.xsim(os.path.join(S.BUILD, 'vlan'), 'tb_vlan', {}, S.files('mac/rocelet_vlan.sv', 'tb_vlan.sv'))
    print(out.replace('\n', ' | '))
    m = re.search(r'TB_DONE errors=(\d+)', out)
    ok = bool(m) and int(m.group(1)) == 0
    print('VLAN TEST %s' % ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
