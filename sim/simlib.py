#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# simlib.py - helpers shared by the rocelet testbench drivers: the RTL file lists and an
# xsim runner (compile once per build directory and configuration, then run with
# plusargs). Needs Vivado's xvlog / xelab / xsim on PATH, or VIVADO_SETTINGS pointing at
# Vivado's settings64.sh (a few usual install locations are tried as well).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import glob
import hashlib
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RTL = os.path.join(ROOT, 'rtl')
BUILD = os.environ.get('SIM_BUILD', os.path.join(HERE, 'build'))


def rtl_files():
    """The IP's source list (rtl/rocelet.f), absolute paths, in compile order."""
    out = []
    with open(os.path.join(RTL, 'rocelet.f')) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                out.append(os.path.join(ROOT, line))
    return out


def files(*names):
    """RTL files by path relative to rtl/ (package first), plus testbench files from sim/."""
    out = []
    for n in names:
        p = os.path.join(RTL, n) if not n.startswith('tb_') else os.path.join(HERE, n)
        out.append(p)
    return out


def top_files(*tb):
    """The whole IP (rtl/rocelet.f) plus the simulation models and the given testbench files."""
    return rtl_files() + [os.path.join(HERE, 'axi_slave_model.sv')] + [os.path.join(HERE, t) for t in tb]


# the engine (rocelet_core) and everything below it
CORE = ['rocelet_pkg.sv', 'common/rocelet_crc32_xor.sv', 'common/rocelet_crc32_inv.sv',
        'common/rocelet_keep2n.sv', 'common/rocelet_fifo.sv', 'common/rocelet_crc32_core.sv',
        'common/rocelet_byte_shift.sv', 'common/rocelet_ram_sdp.sv',
        'icrc/rocelet_icrc_mask.sv', 'icrc/rocelet_icrc_tx.sv', 'icrc/rocelet_icrc_rx.sv',
        'tx/rocelet_tx_builder.sv', 'tx/rocelet_tx_arb.sv', 'tx/rocelet_req_ctrl.sv',
        'rx/rocelet_rx_parser.sv', 'rx/rocelet_resp_rx.sv', 'rx/rocelet_resp_tx.sv',
        'rc/rocelet_ack_proc.sv', 'rc/rocelet_retx_desc.sv', 'rc/rocelet_retx_ring.sv',
        'rocelet_core.sv']


_env = None


def _tool_env():
    global _env
    if _env is not None:
        return _env
    env = dict(os.environ)
    if shutil.which('xvlog') is None:
        cands = [os.environ.get('VIVADO_SETTINGS', '')]
        cands += sorted(glob.glob('/tools/Xilinx/*/Vivado/settings64.sh'), reverse=True)
        cands += sorted(glob.glob(os.path.expanduser('~/Xilinx/*/Vivado/settings64.sh')), reverse=True)
        cands += sorted(glob.glob('/opt/Xilinx/*/Vivado/settings64.sh'), reverse=True)
        cands += sorted(glob.glob('/tools/Xilinx/Vivado/*/settings64.sh'), reverse=True)
        for c in cands:
            if c and os.path.exists(c):
                out = subprocess.run(['bash', '-c', 'source "%s" >/dev/null 2>&1; env -0' % c],
                                     capture_output=True, text=True).stdout
                env = dict(kv.split('=', 1) for kv in out.split('\0') if '=' in kv)
                break
        else:
            raise RuntimeError('Vivado xsim not found: put xvlog on PATH or set VIVADO_SETTINGS')
    _env = env
    return env


def xsim(build_dir, top, generics, srcs, plusargs=(), defines=(), timeout=3600):
    """Compile (once per configuration) and run a testbench; returns (stdout_filtered, log)."""
    env = _tool_env()
    os.makedirs(build_dir, exist_ok=True)
    key = '%s %s %s %s' % (top, sorted(generics.items()), srcs, sorted(defines))
    stamp = hashlib.md5(key.encode()).hexdigest()[:10]
    snap = 'snap_' + stamp
    marker = os.path.join(build_dir, 'built.' + stamp)
    newest = max(os.path.getmtime(f) for f in srcs)
    if not os.path.exists(marker) or os.path.getmtime(marker) < newest:
        cmd = ['xvlog', '--sv', '-i', HERE] + sum([['-d', d] for d in defines], []) + list(srcs)
        r = subprocess.run(cmd, cwd=build_dir, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            errs = [l for l in r.stdout.splitlines() if 'ERROR' in l]
            return 'COMPILE_ERROR\n' + '\n'.join(errs[:30]), r.stdout
        gargs = []
        for k, v in generics.items():
            if isinstance(v, str):
                gargs += ['-generic_top', '%s="%s"' % (k, v)]
            else:
                gargs += ['-generic_top', '%s=%d' % (k, v)]
        cmd = ['xelab', '-debug', 'off', '--timescale', '1ns/1ps'] + gargs + [top, '-s', snap]
        r = subprocess.run(cmd, cwd=build_dir, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            errs = [l for l in r.stdout.splitlines() if 'ERROR' in l]
            return 'ELAB_ERROR\n' + '\n'.join(errs[:30]), r.stdout
        open(marker, 'w').close()
    cmd = ['xsim', snap, '-R'] + sum([['-testplusarg', a] for a in plusargs], [])
    try:
        r = subprocess.run(cmd, cwd=build_dir, env=env, capture_output=True, text=True, timeout=timeout)
        log = r.stdout
    except subprocess.TimeoutExpired as e:
        log = (e.stdout or b'').decode() if isinstance(e.stdout, bytes) else (e.stdout or '')
        log += '\nTB_TIMEOUT (wall clock)'
    keep = [l for l in log.splitlines() if (l.startswith('TB_') and not l.startswith('TB_CNT')) or 'ERROR' in l or
            'FATAL' in l or 'Fatal' in l]
    return '\n'.join(keep[:40]), log
