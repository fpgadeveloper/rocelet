#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# report.py - write docs/resources.md from the synthesis results (synth/build/results.csv and the
# hierarchical utilization report of the routed v1 top).
# Usage: report.py --version VER [build_dir]   (default synth/build): rewrite the page, keeping
#        its "MAC widths" section as it is
#        report.py --mac --version VER [build_dir]   (default synth/build_mac, `make synth-mac`):
#        rewrite only the "MAC widths" section of docs/resources.md, keeping the rest of the page
# VER is the rocelet version the results were built from (vX.Y.Z), or `rtl` for the version of the
# RTL in this tree (only right after the runs: results.csv does not record the version).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KU5P = dict(lut=216960, ff=433920, bram=480, uram=64, dsp=1824)
ZU7EV = dict(lut=230400, ff=460800, bram=312, uram=96, dsp=1728)
DEVICES = {'xcku5p-ffvb676-2-e': ('KU5P (KCU116)', KU5P), 'xczu7ev-ffvc1156-2-e': ('ZU7EV (ZCU106)', ZU7EV)}
# the routed v0.2.2 v1 top (docs/resources.md of v0.2.2, 2026-11-03): the comparison row
ERNIC_LUT = 42082   # AMD ERNIC v4.3, 8 QP, synthesis OOC
V022 = dict(lut=20812, ff=25064, bram=37, uram=8, dsp=0, wns='0.087', whs='0.024')
MAC_TEXT = {
    'mac512_ku5p': '512-bit MAC (100G CMAC), 322.27 MHz',
    'mac256_zu7ev': '256-bit MAC (40GBASE-R4), 156.25 MHz',
    'mac64_zu7ev': '64-bit MAC (10GBASE-R), 156.25 MHz',
}
MAC_HEAD = '## MAC widths'   # the section heading starts with this; it ends with ' (<version>)'
FLOWS = ('lint', 'synth', 'route')

VARIANT_TEXT = {
    'v1_top': 'v1 rocelet_top (all defaults)',
    'v1_core': 'v1 rocelet_core (engine only, native memory ports)',
    'var_reread': 'RTX_MODE "REREAD" (payload re-read from memory, no ring)',
    'var_lossy': 'RTX_MODE "LOSSY" (lossy resume, no payload storage)',
    'var_nohsb': 'HSB_EN = 0',
    'var_nocnt': 'COUNTERS_EN = 0',
    'var_noicrc': 'RX_ICRC_EN = 0 (rely on the Ethernet FCS)',
    'var_lean': 'COUNTERS_EN = 0, OTHER_EN = 0, VLAN_EN = 0',
    'var_250mhz': 'v1 at 250 MHz (4.0 ns)',
}

GROUPS = [
    ('u_core', 'engine (rocelet_core)'),
    ('u_mac', 'MAC glue (rocelet_mac)'),
    ('u_mem', 'AXI4 memory master (rocelet_axi_mem)'),
    ('u_regs', 'register file and counters (rocelet_regs)'),
]


def hier(path):
    """{instance path (indent-qualified): (module, lut, ff, ramb36, ramb18, uram)} of the report."""
    rows = []
    for line in open(path):
        m = re.match(r'^\|(\s+)(\S[^|]*?)\s*\|\s*([^|]*?)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|'
                     r'\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|', line)
        if m:
            depth = (len(m.group(1)) - 1) // 2
            rows.append((depth, m.group(2), m.group(3), int(m.group(4)), int(m.group(8)), int(m.group(9)),
                         int(m.group(10)), int(m.group(11))))
    return rows


def results(bdir):
    """The rows of <bdir>/results.csv, skipping any that do not match its header (rows of an older
    column layout appended to the file, or a header from one): those would mis-read every number."""
    path = os.path.join(bdir, 'results.csv')
    rows = []
    for k, r in enumerate(csv.DictReader(open(path)), 2):
        if None in r or None in r.values() or r.get('flow') not in FLOWS:
            print('warning: %s line %d does not match the header; skipped' % (os.path.relpath(path, ROOT), k))
            continue
        rows.append(r)
    return rows


def rtl_version():
    """rocelet version 'vX.Y.Z' of the RTL in this tree, from the generated register package."""
    txt = open(os.path.join(ROOT, 'rtl', 'ctl', 'rocelet_regs_pkg.sv')).read()
    v = [re.search(r'VER_%s\s*=\s*8\'d(\d+)' % k, txt).group(1) for k in ('MAJOR', 'MINOR', 'PATCH')]
    return 'v' + '.'.join(v)


def results_version(arg):
    """The version label of the results: --version vX.Y.Z, or 'rtl' for the RTL in this tree."""
    if arg == 'rtl':
        return rtl_version()
    if arg and re.match(r'^v\d+\.\d+\.\d+$', arg):
        return arg
    sys.exit('report.py: pass --version vX.Y.Z, the rocelet version the results were built from '
             '(or --version rtl right after the runs; the RTL in this tree is %s)' % rtl_version())


def bram(r36, r18):
    return r36 + r18 / 2.0


def n(x):
    """Thousands separators for integer counts (anything else unchanged)."""
    try:
        return '{:,}'.format(int(x))
    except (TypeError, ValueError):
        return x


def fmt_b(x):
    return ('%.1f' % x).rstrip('0').rstrip('.')


def mac_section(bdir, ver):
    """The "MAC widths" section from a `make synth-mac` build directory."""
    res = [r for r in results(bdir) if r['name'] in MAC_TEXT]
    last = {}
    for r in res:
        last[r['name']] = r
    date = max(r['date'] for r in last.values())[:10]
    L = ['%s (%s)' % (MAC_HEAD, ver), '',
         '*Generated by `synth/report.py --mac` from `make synth-mac` (Vivado 2025.2, %s).*' % date, '',
         'The v1 configuration (all other parameters at their defaults) with the MAC AXI-Stream at each '
         '`MAC_WIDTH`, placed and routed out of context: 512 bits on the KCU116 device at the 100G CMAC '
         'clock (the regression figure against v0.2.2), 256 and 64 bits on the ZCU106 device '
         '(**xczu7ev-ffvc1156-2-e**) at the 156.25 MHz clock of a 40G / 10G MAC, with the width '
         'converters inside `rocelet_top`. The v0.2.2 row is the routed v1 top of rocelet v0.2.2 (same part '
         'and clock), for comparison. The 512-bit build sets `CLK_KHZ` to the exact CMAC clock '
         '(322,266 kHz) and is placed and routed in its own run, so it differs slightly from the v1 top '
         'above.', '',
         '| Configuration | Device | LUT | FF | BRAM36 | URAM | DSP | WNS / WHS (ns) | LUT vs v0.2.2 |',
         '|---|---|---:|---:|---:|---:|---:|---|---:|',
         '| v0.2.2 v1 top (512-bit CMAC), 322.27 MHz | KU5P (KCU116) | %s | %s | %s | %s | %s | %s / %s | |' % (
             n(V022['lut']), n(V022['ff']), V022['bram'], V022['uram'], V022['dsp'], V022['wns'], V022['whs'])]
    for name in ['mac512_ku5p', 'mac256_zu7ev', 'mac64_zu7ev']:
        r = last.get(name)
        if not r:
            continue
        dev = DEVICES.get(r['part'], (r['part'], None))[0]
        if r['lut_impl'] in ('NA', '', 'ERROR', None):
            L.append('| %s %s | %s | %s | %s | %s | %s | %s | %s (synthesis) | |' % (
                ver, MAC_TEXT[name], dev, n(r['lut']), n(r['ff']), r['bram36'], r['uram'], r['dsp'],
                r['wns_synth']))
            continue
        L.append('| **%s %s** | %s | **%s** | %s | %s | %s | %s | **%s / %s** | %s |' % (
            ver, MAC_TEXT[name], dev, n(r['lut_impl']), n(r['ff_impl']), r['bram_impl'], r['uram_impl'],
            r['dsp_impl'], r['wns_impl'], r['whs_impl'], '{:+,}'.format(int(r['lut_impl']) - V022['lut'])))
    # the width converters, from the hierarchical reports
    conv = []
    for name in ['mac256_zu7ev', 'mac64_zu7ev']:
        hp = os.path.join(bdir, '%s_route_hier.rpt' % name)
        if not os.path.exists(hp):
            continue
        rows = hier(hp)
        up = [x for x in rows if 'u_rx_up' in x[1]]
        dn = [x for x in rows if 'u_tx_dn' in x[1]]
        if up and dn:
            conv.append('%s: RX packer %s LUT / %s FF, TX unpacker %s LUT / %s FF' % (
                MAC_TEXT[name].split(',')[0], n(up[0][3]), n(up[0][4]), n(dn[0][3]), n(dn[0][4])))
    zu = last.get('mac256_zu7ev')
    if zu and zu['lut_impl'] not in ('NA', '', 'ERROR'):
        L += ['', 'On the ZU7EV the 256-bit build is %.1f %% of the LUTs, %.1f %% of the BRAM36 and %.1f %% of '
              'the URAM.' % (100.0 * float(zu['lut_impl']) / ZU7EV['lut'], 100.0 * float(zu['bram_impl']) / ZU7EV['bram'],
                             100.0 * float(zu['uram_impl']) / ZU7EV['uram'])]
    if conv:
        L += ['', 'Width converters (routed): ' + '; '.join(conv) + '.']
    L += ['', 'The one DSP slice is the received-PAUSE quanta multiply (`PAUSE_QCLK`, since v0.3.0). '
          'Reproduce with `make synth-mac` (one Vivado process, the three jobs of `synth/jobs_mac.txt`; '
          'reports in `synth/build_mac/`).', '']
    return '\n'.join(L)


def mac_only(bdir, ver):
    out = os.path.join(ROOT, 'docs', 'resources.md')
    if not os.path.exists(os.path.join(bdir, 'results.csv')):
        sys.exit('report.py: no %s; %s left unchanged (run `make synth-mac` first)' % (
            os.path.join(bdir, 'results.csv'), os.path.relpath(out, ROOT)))
    page = open(out).read()
    sec = mac_section(bdir, ver)
    if MAC_HEAD in page:
        i = page.index(MAC_HEAD)
        j = page.find('\n## ', i + len(MAC_HEAD))
        page = page[:i] + sec + ('\n' + page[j + 1:] if j >= 0 else '')
    else:
        i = page.index('## Build options')
        page = page[:i] + sec + '\n' + page[i:]
    open(out, 'w').write(page)
    print('wrote the MAC widths section of %s' % os.path.relpath(out, ROOT))


def old_mac_section(out):
    """The "MAC widths" section of the current page (kept as it is when the page is rewritten)."""
    page = open(out).read() if os.path.exists(out) else ''
    if MAC_HEAD not in page:
        return None
    i = page.index(MAC_HEAD)
    j = page.find('\n## ', i + len(MAC_HEAD))
    return page[i:j] if j >= 0 else page[i:]


def main():
    args = sys.argv[1:]
    ver = None
    if '--version' in args:
        k = args.index('--version')
        ver = args[k + 1] if k + 1 < len(args) else None
        del args[k:k + 2]
    mac = '--mac' in args
    args = [x for x in args if x != '--mac']
    ver = results_version(ver)
    if mac:
        mac_only(args[0] if args else os.path.join(HERE, 'build_mac'), ver)
        return
    bdir = args[0] if args else os.path.join(HERE, 'build')
    out = os.path.join(ROOT, 'docs', 'resources.md')
    old_mac = old_mac_section(out)
    rtl = rtl_version()
    res = {}
    for r in results(bdir):   # the latest row of each job
        res[r['name']] = r
    top = res['v1_top']
    L = ['# rocelet resources and timing', '',
         '*Generated by `synth/report.py` from `make synth` and `make synth-variants` (Vivado 2025.2, %s).*'
         % top['date'][:10], '',
         'Out-of-context results on **xcku5p-ffvb676-2-e** (the KCU116 device) with the clock at the 100G '
         'CMAC user clock, **322.265625 MHz (3.103 ns)**, unless noted. Out of context means no I/O buffers '
         'and no optimisation across the IP boundary; in a full design the numbers are usually slightly '
         'lower. BRAM36 counts RAMB36 tiles plus half a tile per RAMB18. WNS / WHS: worst setup / hold '
         'slack, positive = met.', '',
         '## v1 configuration (%s)' % ver, '']
    if ver != rtl:
        dsp = ''
        if top['dsp'] == '0' and 'use_dsp' in open(os.path.join(ROOT, 'rtl', 'mac', 'rocelet_pause.sv')).read():
            dsp = ' and uses one DSP slice (the received-PAUSE multiply in `rtl/mac/rocelet_pause.sv`) where these show 0'
        L += ['*These figures and the build options below are for rocelet %s. The RTL in this tree is %s%s; '
              'its figures for these sections follow in the next `make synth` and `make synth-variants` '
              'run%s.*' % (ver, rtl, dsp, ' (the %s top at each MAC width, placed and routed, is in "MAC widths" '
                                            'below)' % rtl if old_mac and rtl in old_mac else ''), '']
    L += [
         'The parameter defaults of `rocelet_top`: 16 QPs, 16 memory windows, READ depth 16, a 256 KB URAM '
         'retransmit ring (`RTX_MODE` "RING"), 128 outstanding work requests, RX ICRC check, shared CRC '
         'network, HSB builder mode, VLAN, PAUSE, ARP/ICMP, other-traffic ports, counters, 32 KB RX and TX '
         'FIFOs, 16 KB other-traffic TX FIFO, AXI4 memory master with a 16 KB read buffer.', '',
         '| | LUT | FF | BRAM36 | URAM | DSP | WNS / WHS (ns) |',
         '|---|---:|---:|---:|---:|---:|---|']
    L.append('| synthesis | %s | %s | %s | %s | %s | %s / %s |' % (
        n(top['lut']), n(top['ff']), top['bram36'], top['uram'], top['dsp'], top['wns_synth'], top['whs_synth']))
    if top['lut_impl'] not in ('NA', ''):
        L.append('| **placed and routed** | **%s** | **%s** | **%s** | **%s** | %s | **%s / %s** |' % (
            n(top['lut_impl']), n(top['ff_impl']), top['bram_impl'], top['uram_impl'], top['dsp_impl'],
            top['wns_impl'], top['whs_impl']))
        L.append('| share of the KU5P | %.1f %% | %.1f %% | %.1f %% | %.1f %% | %.1f %% | |' % (
            100.0 * float(top['lut_impl']) / KU5P['lut'], 100.0 * float(top['ff_impl']) / KU5P['ff'],
            100.0 * float(top['bram_impl']) / KU5P['bram'], 100.0 * float(top['uram_impl']) / KU5P['uram'],
            100.0 * float(top['dsp_impl']) / KU5P['dsp']))
    tp = os.path.join(bdir, 'v1_top_route_timing.rpt')
    if os.path.exists(tp):
        t = open(tp).read()
        m = re.search(r'Slack \(\w+\) :\s+(-?[\d.]+)ns.*?Source:\s+(\S+).*?Destination:\s+(\S+).*?'
                      r'Logic Levels:\s+(\d+)', t, re.S)
        if m:
            L += ['', 'Worst routed setup path: %s ns, `%s` -> `%s`, %s logic levels.' % m.groups()]
    L.append('')
    hp = os.path.join(bdir, 'v1_top_route_hier.rpt')
    if os.path.exists(hp):
        rows = hier(hp)
        L += ['### By function (routed)', '', '| Part | LUT | FF | BRAM36 | URAM |', '|---|---:|---:|---:|---:|']
        tot = [r for r in rows if r[0] == 0][0]
        for inst, text in GROUPS:
            r = [x for x in rows if x[0] == 1 and x[1] == inst]
            if r:
                r = r[0]
                L.append('| %s | %s | %s | %s | %d |' % (text, n(r[3]), n(r[4]), fmt_b(bram(r[5], r[6])), r[7]))
        L.append('| **total** | **%s** | **%s** | **%s** | **%d** |' % (n(tot[3]), n(tot[4]), fmt_b(bram(tot[5], tot[6])),
                                                                     tot[7]))
        L += ['', '### Inside the engine and the MAC glue (routed)', '',
              '| Block | Module | LUT | FF | BRAM36 | URAM |', '|---|---|---:|---:|---:|---:|']
        cur = None
        for r in rows:
            if r[0] == 1:
                cur = r[1]
            if r[0] == 2 and cur in ('u_core', 'u_mac', 'u_mem') and not r[1].startswith('('):
                L.append('| %s/%s | %s | %s | %s | %s | %d |' % (cur, r[1], re.sub(r'__parameterized\d+$', '', r[2]),
                                                                 n(r[3]), n(r[4]), fmt_b(bram(r[5], r[6])),
                                                                 r[7]))
        L.append('')
    L += ['## Build options (%s)' % ver, '',
          'Synthesis only (the routed v1 top is above). Differences are against the v1 top after synthesis.', '',
          '| Configuration | LUT | FF | BRAM36 | URAM | WNS (ns) | LUT vs v1 |', '|---|---:|---:|---:|---:|---|---:|']
    base = int(top['lut'])
    for name in ['v1_top', 'v1_core', 'var_reread', 'var_lossy', 'var_nohsb', 'var_nocnt', 'var_noicrc',
                 'var_lean', 'var_250mhz']:
        r = res.get(name)
        if not r or r['lut'] in ('ERROR', 'lint'):
            continue
        L.append('| %s | %s | %s | %s | %s | %s | %s |' % (VARIANT_TEXT[name], n(r['lut']), n(r['ff']), r['bram36'],
                                                         r['uram'], r['wns_synth'], '{:+,}'.format(int(r['lut']) - base)))
    L += ['', '## Against AMD\'s ERNIC IP', '',
          '| Design | LUT | BRAM36 | URAM | Scope |', '|---|---:|---:|---:|---|',
          '| **rocelet %s `rocelet_top`** (routed, OOC) | **%s** | **%s** | **%s** | engine + MAC glue + ARP/ICMP + register file + counters + AXI4 memory master |'
          % (ver, n(top['lut_impl']), top['bram_impl'], top['uram_impl'])]
    core = res.get('v1_core')
    if core:
        L.append('| rocelet %s `rocelet_core` (synthesis, OOC) | %s | %s | %s | engine only |' % (
            ver, n(core['lut']), core['bram36'], core['uram']))
    L += ['| AMD ERNIC v4.3, 8 QP (synthesis, OOC) | %s | 117 | 20 | engine only |' % n(ERNIC_LUT), '']
    if core:
        L += ['`rocelet_core` is %.0f %% of the ERNIC engine\'s LUTs (about a third); the whole `rocelet_top` '
              '(engine, MAC glue, ARP/ICMP, register file, counters and AXI4 memory master) is %.0f %% '
              '(about half).' % (100.0 * int(core['lut']) / ERNIC_LUT, 100.0 * int(top['lut_impl']) / ERNIC_LUT), '']
    L += [
          '## Reproducing', '', '```', 'make synth            # lint, v1 top (place and route), v1 core',
          'make synth-variants   # the build options',
          'python3 synth/report.py --version rtl   # this page, right after the runs above',
          'make synth-mac        # the MAC widths (also rewrites that section: report.py --mac)', '```', '',
          '`synth/run_synth.sh` waits while two or more Vivado processes run on the machine (`MAX_JOBS`). '
          'Reports: `synth/build/<job>_{synth,route}_{util,hier,timing}.rpt` (`synth/build_mac/` for the MAC '
          'widths). The Vivado linter '
          '(`synth_design -lint`, job `v1_lint`) reports no errors on the v1 top; its warnings are unused '
          'ports and signals of disabled options and width notes.', '']
    page = '\n'.join(L)
    if old_mac:
        i = page.index('## Build options')
        page = page[:i] + old_mac + '\n' + page[i:]
    else:
        print('warning: %s had no "%s" section; run report.py --mac to add it' % (
            os.path.relpath(out, ROOT), MAC_HEAD))
    open(out, 'w').write(page)
    print('wrote %s' % os.path.relpath(out, ROOT))


if __name__ == '__main__':
    main()
