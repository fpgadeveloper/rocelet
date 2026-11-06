#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_pair.py - end-to-end RC test: rocelet_core A (requester) -> lossy link -> rocelet_core
# B (responder) -> lossy link -> A, in xsim (tb_core_pair). Checks that
#   go-back-N (RTX_MODE RING: payload from the on-chip ring; REREAD: re-read from memory):
#     every WR completes once, in order, with status OK; B's memory holds every WRITE
#     exactly; B's SEND stream (committed packets) equals the SEND data per QP; B's
#     receive completions (immediates, message lengths) match; no QP errors; with
#     receive-buffer stalls (send_rnr) the RNR NAKs are recovered;
#   UC / HSB QPs on A complete when sent (B, an RC responder, drops them);
#   a forced QP error flushes that QP's later WRs (status FLUSHED) without disturbing the
#     other QPs;
#   lossy resume (RTX_MODE LOSSY, single-packet WRITEs): no QP errors, every WR completes,
#     every WRITE region in B is either complete and correct or untouched, losses counted;
#   link loss (link_down, separate configurations): a WRITE-with-immediate stream in flight,
#     the link down for 1.2 M timer ticks (scaled "15 s": 1200 x the 1000-tick ACK timeout,
#     longer than the 20-bit tick counter wraps), A's link_up low meanwhile, then the partner
#     silent for 250 k ticks of a 300 k-tick LINK_GRACE: no timeout while held, exactly one
#     timeout per QP when the grace ends, every WR completes OK, B's memory and receive
#     completions exact (nothing lost, nothing twice); the control (link_up left high, v0.1
#     behaviour) must fail the QPs with retry exceeded (0xFF).
# With --top the same traffic runs between two complete IPs (tb_top_pair: rocelet_top with
# the MAC glue, AXI-Lite configuration, AXI4 memory, 802.3x PAUSE between the sides, VID-0
# tags from A, plus ARP / ICMP towards A and a frame through the other-traffic ports).
# --mac-width 64 / 128 / 256 (with --top): both IPs at that MAC width, the link one MAC beat
# per clock with random tvalid gaps inside received frames, PAUSE as the receiving MAC's
# hold level (CTRL.PAUSE_RX_LEVEL, as omac) instead of quanta pulses.
# Usage: test_pair.py [--top] [--mac-width N] [nwr] [seed] [drop per mille] [config...]
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import random
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import simlib as S  # noqa: E402

FILES = S.files(*S.CORE, 'tb_core_pair.sv')
FILES_TOP = S.top_files('tb_top_pair.sv')

# name: (generics, options)
CONFIGS = {
    'gbn_ring':   (dict(NUM_QP=4, RTX_MODE='RING', RING_BYTES=65536, MAX_WR=32), dict()),
    'gbn_reread': (dict(NUM_QP=4, RTX_MODE='REREAD', RING_BYTES=65536, MAX_WR=32), dict()),
    'gbn_rnr':    (dict(NUM_QP=4, RTX_MODE='RING', RING_BYTES=65536, MAX_WR=32), dict(rnr=300)),
    'mixed_uc':   (dict(NUM_QP=4, RTX_MODE='RING', RING_BYTES=65536, MAX_WR=32), dict(types=[0, 1, 0, 2])),
    'flush':      (dict(NUM_QP=4, RTX_MODE='RING', RING_BYTES=65536, MAX_WR=32), dict(ferr_qp=2)),
    'lossy':      (dict(NUM_QP=4, RTX_MODE='LOSSY', RING_BYTES=65536, MAX_WR=32), dict()),
    'paced':      (dict(NUM_QP=4, RTX_MODE='RING', RING_BYTES=65536, MAX_WR=32), dict(pace=2560, core_only=1)),
    # RNR wait from the AETH timer code: code 3 = 30 us; code 0 = 655 ms clamped to RNR_MAX 200 us
    'rnr_code3':  (dict(NUM_QP=4, RTX_MODE='RING', RING_BYTES=65536, MAX_WR=32),
                   dict(rnr=400, rnr_code=3, rnr_max=2000, rnr_us=30, nodrop=1, core_only=1)),
    'rnr_clamp':  (dict(NUM_QP=4, RTX_MODE='RING', RING_BYTES=65536, MAX_WR=32),
                   dict(rnr=400, rnr_code=0, rnr_max=200, rnr_us=200, nodrop=1, core_only=1)),
    'lossy_flush': (dict(NUM_QP=4, RTX_MODE='LOSSY', RING_BYTES=65536, MAX_WR=32), dict(ferr_qp=1, core_only=1)),
    # link loss (run by name: run_tests.py link_down): 1 tick = 1 clock, ACK timeout 1000 ticks
    'link_down':  (dict(NUM_QP=2, RTX_MODE='RING', RING_BYTES=65536, MAX_WR=32),
                   dict(classes=[1], nodrop=1, core_only=1, separate=1,
                        ld=dict(clk=1200000, silent=250000, hold=1, tick=1, to=1000, grace=300000))),
    'link_nohold': (dict(NUM_QP=2, RTX_MODE='RING', RING_BYTES=65536, MAX_WR=32),
                    dict(classes=[1], nodrop=1, core_only=1, separate=1, expect_fatal=1,
                         ld=dict(clk=100000, silent=0, hold=0, tick=1, to=1000, grace=300000))),
}


def mm_pat(a, top):
    if top:
        return (a ^ (a >> 8) ^ 0x5A) & 0xFF            # axi_slave_model
    return (a & 0xFF) ^ ((a >> 16) & 0xFF) ^ 0x3C      # tb_core_pair


def run(name, nwr, seed, drop, top=False, mac_w=512):
    g, opt = CONFIGS[name]
    if mac_w != 512:
        g = dict(g, MAC_WIDTH=mac_w, PAUSE_LEVEL=1)
    rng = random.Random(seed)
    d = os.path.join(S.BUILD, ('top_pair_' if top else 'pair_') + ('w%d_' % mac_w if mac_w != 512 else '') + name)
    os.makedirs(d, exist_ok=True)
    nq = g['NUM_QP']
    lossy = g['RTX_MODE'] == 'LOSSY'
    types = opt.get('types', [0] * nq)
    cfg = {q: dict(psn=rng.choice([rng.getrandbits(24), 0xFFFFFF - rng.randrange(4)]),
                   pmtu=rng.randint(8, 11), type=types[q]) for q in range(nq)}
    with open(os.path.join(d, 'cfg.txt'), 'w') as f:
        for q, c in cfg.items():
            f.write('%x %x %x %x\n' % (q, c['psn'], c['pmtu'], c['type']))
    mr = dict(rkey=0x5A5A0000 | rng.getrandbits(16), va=0x7F0000000000, len=1 << 24, laddr=0x40000000)
    with open(os.path.join(d, 'mr.txt'), 'w') as f:
        f.write('%x %x %x %x\n' % (mr['rkey'], mr['va'], mr['len'], mr['laddr']))
    wrs = []
    for i in range(nwr):
        q = rng.randrange(nq)
        pm = 1 << cfg[q]['pmtu']
        if lossy:
            cls, L = rng.choice([0, 1]), rng.randint(1, pm)
        else:
            cls = rng.choice(opt.get('classes', [0, 0, 1, 2, 3]))
            L = rng.choice([rng.randint(1, 200), pm, rng.randint(1, 3 * pm)])
            if rng.random() < 0.05:
                L = 0
        if g['RTX_MODE'] == 'REREAD':
            la = 0x100000000000 + i * 0x10000
            data = bytes(mm_pat(la + j, top) for j in range(L))
        else:
            data = bytes(rng.getrandbits(8) for _ in range(L))
        wrs.append(dict(qp=q, cls=cls, va=mr['va'] + i * 0x10000, rkey=mr['rkey'], len=L,
                        imm=rng.getrandbits(32), id=i, data=data, flags=rng.getrandbits(1)))
    with open(os.path.join(d, 'wr.txt'), 'w') as f:
        for w in wrs:
            f.write('%x %x %x %x %x %x %x %x\n' % (w['qp'], w['cls'], w['va'], w['rkey'], w['len'], w['imm'],
                                                  w['id'], w['flags']))
    with open(os.path.join(d, 'pay.txt'), 'w') as f:
        if g['RTX_MODE'] != 'REREAD':
            for w in wrs:
                n = (len(w['data']) + 63) // 64
                for k in range(n):
                    ch = w['data'][64 * k:64 * k + 64]
                    ch = ch + b'\0' * (64 - len(ch))
                    f.write('%d %s\n' % (int(k == n - 1), ch[::-1].hex()))
    ferr_qp = opt.get('ferr_qp', -1)
    ferr_at = nwr // 3
    plus = ['dir=' + d, 'seed=%d' % seed, 'drop=%d' % drop, 'nwr=%d' % nwr, 'rnr=%d' % opt.get('rnr', 0),
            'ferr_qp=%d' % ferr_qp, 'ferr_at=%d' % ferr_at, 'pace=%d' % opt.get('pace', 0),
            'rnr_code=%d' % opt.get('rnr_code', 1), 'rnr_max=%d' % opt.get('rnr_max', 2000),
            'igap=%d' % (100 if mac_w != 512 else 0)]
    if opt.get('nodrop'):
        plus[2] = 'drop=0'
    ld = opt.get('ld')
    if ld:
        plus += ['ld_at=%d' % (nwr // 3), 'ld_clk=%d' % ld['clk'], 'ld_silent=%d' % ld['silent'],
                 'ld_hold=%d' % ld['hold'], 'tick=%d' % ld['tick'], 'to=%d' % ld['to'], 'grace=%d' % ld['grace']]
    out, log = S.xsim(d, 'tb_top_pair' if top else 'tb_core_pair', g, FILES_TOP if top else FILES, plus)
    print('[%s] %s' % (name, out.replace('\n', ' | ')))
    if 'TB_DONE' not in out:
        return 1
    bad = 0
    if ld:
        m = re.search(r'TB_LINK phase=(\d+) lost=(\d+) timeouts_held=(\d+) timeouts_after=(\d+) hold_seen=(\d+) '
                      r'link_down_ev=(\d+) to_lat=(-?\d+)', out)
        ph, lost_f, to_h, to_a, hs, lde, lat = map(int, m.groups()) if m else (0,) * 7
        aerr = [x for x in open(os.path.join(d, 'a_err.txt')).read().split('\n') if x.strip()]
        if opt.get('expect_fatal'):
            # v0.1 behaviour: the retry budget (8 x 1000 ticks) runs out during the outage
            ok = m and ph == 3 and aerr and all(x.endswith(' ff') for x in aerr) and to_h >= 8 and hs == 0
            print('  link down %d ticks with link_up left high: QP errors %s, %d timeouts during the outage: %s' % (
                ld['clk'], aerr, to_h, 'as expected' if ok else 'UNEXPECTED'))
            return 0 if ok else 1
        # the overdue ACK times out at once when the grace ends (within a scan of the QPs,
        # far below one ACK timeout), not one timeout later
        if not m or ph != 3 or to_h != 0 or not (1 <= to_a <= g['NUM_QP']) or hs != 1 or lde != 1 or \
                not (0 <= lat < 100):
            print('  link loss: %s (expected phase 3, 0 timeouts while held, 1..%d after, hold seen, 1 link-down '
                  'event, first timeout < 100 clocks after the grace)' % (m.groups() if m else '-', g['NUM_QP']))
            bad += 1
        else:
            print('  link loss: %d frames lost, 0 timeouts while held, %d after the grace (one per QP with data '
                  'in flight), the first %d clocks after the grace ended, 1 link-down event' % (lost_f, to_a, lat))
    cpl = [tuple(map(int, l.split())) for l in open(os.path.join(d, 'a_cpl.txt'))]
    st = {c[1]: c[2] for c in cpl}
    nlost = sum(1 for c in cpl if c[2] == 1)
    nflush = sum(1 for c in cpl if c[2] == 2)
    if [c[1] for c in cpl] != list(range(nwr)) or any(c[0] != wrs[c[1]]['qp'] for c in cpl):
        print('  A completions: %d, ids %s...' % (len(cpl), [c[1] for c in cpl][:20]))
        bad += 1
    # statuses: OK, except LOST (lossy) and FLUSHED (forced error, that QP only)
    flushed_qp = set()
    for c in cpl:
        q, i, s = c
        if s == 0:
            continue
        if s == 1 and lossy:
            continue
        if s == 2 and q == ferr_qp:
            flushed_qp.add(q)
            continue
        bad += 1
        if bad < 5:
            print('  WR %d (qp %d) completed with status %d' % (i, q, s))
    aerr = [x for x in open(os.path.join(d, 'a_err.txt')).read().split('\n') if x.strip()]
    berr = [x for x in open(os.path.join(d, 'b_err.txt')).read().split('\n') if x.strip()]
    exp_aerr = ['%d fd' % ferr_qp] if ferr_qp >= 0 else []
    if aerr != exp_aerr or berr:
        print('  QP errors: A %s (expected %s) B %s' % (aerr, exp_aerr, berr))
        bad += 1
    # memory image of B
    mem = {}
    if top:
        for line in open(os.path.join(d, 'mem.txt')):
            a, h = line.split()
            for j, b in enumerate(bytes.fromhex(h)):
                mem[int(a, 16) + j] = b
    else:
        cur = None
        for line in open(os.path.join(d, 'b_wr.txt')):
            t = line.split()
            if t[0] == 'C':
                cur = [int(t[1], 16), 0]
            else:
                data = bytes.fromhex(t[3])[::-1][:int(t[2])]
                for j, b in enumerate(data):
                    mem[cur[0] + cur[1] + j] = b
                cur[1] += len(data)
    lost = 0
    for w in wrs:
        if w['cls'] >= 2 or w['len'] == 0:
            continue
        base = mr['laddr'] + (w['va'] - mr['va'])
        present = [(base + j) in mem for j in range(w['len'])]
        got = bytes(mem.get(base + j, 0) for j in range(w['len']))
        if cfg[w['qp']]['type'] != 0:
            if any(present):
                bad += 1
                print('  WR %d on a UC QP reached B' % w['id'])
            continue
        if all(present) and got == w['data']:
            continue
        if (lossy and st.get(w['id']) == 1) or st.get(w['id']) == 2:
            if not any(present) or lossy:
                lost += 1
                continue
        if st.get(w['id']) == 2 and all(got[j] == w['data'][j] for j in range(w['len']) if present[j]):
            continue                          # flushed: whatever arrived is correct
        bad += 1
        if bad < 8:
            print('  WR %d (qp %d, %d B, status %s): %d/%d bytes present, data %s' % (
                w['id'], w['qp'], w['len'], st.get(w['id']), sum(present), w['len'],
                'ok' if got == w['data'] else 'BAD'))
    # SEND stream (committed packets only) and receive completions, per QP
    pk, sends = [], {q: [] for q in range(nq)}
    curp = bytearray()
    msg = {q: bytearray() for q in range(nq)}
    for line in open(os.path.join(d, 'b_send.txt')):
        t = line.split()
        if t[0] == 'E':
            q, som, eom, data = pk.pop(0)
            if int(t[1]):
                if som:
                    msg[q] = bytearray()
                msg[q] += data
                if eom:
                    sends[q].append(bytes(msg[q]))
            continue
        curp += bytes.fromhex(t[2])[::-1][:int(t[1])]
        if int(t[0]):
            pk.append((int(t[3]), int(t[4]), int(t[5]), bytes(curp)))
            curp = bytearray()
    bcpl = {q: [] for q in range(nq)}
    for line in open(os.path.join(d, 'b_cpl.txt')):
        q, snd, hi, im, ln = line.split()
        bcpl[int(q)].append((int(snd), int(hi), int(im, 16) if int(hi) else None, int(ln)))
    if not lossy:
        for q in range(nq):
            if cfg[q]['type'] != 0:
                if sends[q] or bcpl[q]:
                    bad += 1
                    print('  QP %d (UC) produced SENDs / completions at B' % q)
                continue
            if q in flushed_qp:
                continue
            exp_s = [w['data'] for w in wrs if w['qp'] == q and w['cls'] >= 2 and w['len'] > 0]
            got_s = [s for s in sends[q] if s]
            if exp_s != got_s:
                print('  QP %d SEND: %d msgs (%d expected)' % (q, len(got_s), len(exp_s)))
                bad += 1
            exp_c = [(int(w['cls'] >= 2), w['cls'] & 1, w['imm'] if w['cls'] & 1 else None, w['len'])
                     for w in wrs if w['qp'] == q and (w['cls'] >= 2 or w['cls'] & 1)]
            if exp_c != bcpl[q]:
                print('  QP %d receive completions: %d (%d expected)' % (q, len(bcpl[q]), len(exp_c)))
                for a, b in zip(bcpl[q], exp_c):
                    if a != b:
                        print('    got %s exp %s' % (a, b))
                        break
                bad += 1
    if top:
        if 'TB_ERROR' in out:
            print('  %s' % [l for l in out.splitlines() if 'TB_ERROR' in l][:4])
            bad += 1
        bad += check_top(d, log, out, mac_w)
    if opt.get('rnr_us'):
        # the requester waits the decoded (clamped) RNR time: tick = 16 clocks per us in the
        # testbench; allow the timer granularity and the scanner's latency
        m = re.search(r'rnr_wait=(\d+)\.\.(\d+)', out)
        lo, hi = (opt['rnr_us'] - 1) * 16, opt['rnr_us'] * 16 + 120      # +-1 us timer granularity
        if not m or int(m.group(1)) < lo or int(m.group(2)) > hi:
            print('  RNR wait: %s clocks, expected %d..%d' % (m.groups() if m else '-', lo, hi))
            bad += 1
        else:
            print('  RNR wait %s..%s clocks (expected %d..%d)' % (m.group(1), m.group(2), lo, hi))
    if opt.get('pace'):
        # the requester's wire rate (frame bytes per clock) must stay at the configured rate
        # (credit per clock / 256 counts payload + 98; a frame is payload + ~74 bytes)
        m = re.search(r'rate_x100=(\d+)', out)
        lim = opt['pace'] / 256.0
        if not m or int(m.group(1)) / 100.0 > lim * 1.05:
            print('  pacing: %s bytes/clock, limit %.2f' % (int(m.group(1)) / 100.0 if m else '-', lim))
            bad += 1
        else:
            print('  pacing: %.2f bytes/clock (limit %.2f)' % (int(m.group(1)) / 100.0, lim))
    if opt.get('rnr'):
        m = re.search(r'rnr_sent=(\d+) rnr_rx=(\d+)', out)
        if not m or int(m.group(1)) == 0 or int(m.group(2)) == 0:
            print('  RNR: expected RNR NAKs sent and received (%s)' % (str(m.groups()) if m else 'none'))
            bad += 1
    print('  %d WRs, %d completions (%d lost, %d flushed), %d WRITE regions lost/flushed, %d errors' % (
        nwr, len(cpl), nlost, nflush, lost, bad))
    return bad


MAC_A, IP_A = 0x02000000000A, 0xC0A8020A
CNT = None


def check_top(d, log, out, mac_w=512):
    """The extra system checks of tb_top_pair."""
    import roce_ref as R
    global CNT
    if CNT is None:
        sys.path.insert(0, os.path.join(S.ROOT, 'regs'))
        import rocelet_regs as G
        CNT = [n for n, _ in G.COUNTERS]
    bad = 0
    cnt = {}
    for line in log.splitlines():
        if line.startswith('TB_CNT'):
            _, i, a, b = line.split()
            cnt[CNT[int(i)]] = (int(a), int(b))
    # ARP and ICMP replies of A
    ctl = [fr for fr, _ in R.read_beats(os.path.join(d, 'a_ctl.txt'))]
    arp = [f for f in ctl if f[12:14] == b'\x08\x06']
    icmp = [f for f in ctl if f[12:14] == b'\x08\x00' and f[23] == 1]
    if len(arp) != 1 or arp[0][0:6] != bytes(range(0x10, 0x16)) or arp[0][20:22] != b'\x00\x02' or \
            int.from_bytes(arp[0][22:28], 'big') != MAC_A or int.from_bytes(arp[0][28:32], 'big') != IP_A:
        print('  ARP reply wrong or missing: %s' % [f[:42].hex() for f in arp])
        bad += 1
    if len(icmp) != 1:
        print('  ICMP echo reply missing (%d)' % len(icmp))
        bad += 1
    else:
        f = icmp[0]
        ok = (f[34] == 0 and int.from_bytes(f[26:30], 'big') == IP_A and f[30:34] == bytes([192, 168, 2, 1]) and
              R.ip4_checksum(f[14:34]) == 0 and len(f) == 98 and
              f[42:98] == bytes((i * 7) & 0xFF for i in range(42, 98)))
        s = sum(struct.unpack('!%dH' % ((len(f) - 34) // 2), f[34:34 + ((len(f) - 34) // 2) * 2]))
        while s >> 16:
            s = (s & 0xFFFF) + (s >> 16)
        if not ok or s != 0xFFFF:
            print('  ICMP echo reply wrong: %s' % f.hex())
            bad += 1
    # the other-traffic frame
    oth = [fr for fr, _ in R.read_beats(os.path.join(d, 'b_other.txt'))]
    exp = bytearray((b * 64 + j + 3) & 0xFF for b in range(4) for j in range(64))[:200]
    exp[0:6] = (0x02000000000B).to_bytes(6, 'big')
    exp[6:12] = MAC_A.to_bytes(6, 'big')
    exp[12:14] = b'\x88\xb5'
    # B forwards every frame it does not handle: the 200-byte frame and A's ICMP echo reply
    # (addressed to the host, not to B)
    mine = [f for f in oth if f[12:14] == b'\x88\xb5']
    if mine != [bytes(exp)] or len(oth) != 2:
        print('  other-traffic frames at B: %d (%d with EtherType 0x88B5), expected the 200-byte frame' % (
            len(oth), len(mine)))
        bad += 1
    # counters
    exp_cnt = [('TX_UNDERRUN', 0, 0), ('RX_FIFO_DROP', 0, 0), ('RX_FCS_ERR', 0, 0), ('AXI_WR_ERR', 0, 0),
               ('AXI_RD_ERR', 0, 0), ('WR_DATA_ERR', 0, None)]
    for n, ea, eb in exp_cnt:
        a, b = cnt.get(n, (-1, -1))
        if (ea is not None and a != ea) or (eb is not None and b != eb):
            print('  counter %s = %d / %d' % (n, a, b))
            bad += 1
    if cnt.get('TX_VLAN_TAG', (0, 0))[0] == 0 or cnt.get('RX_VLAN_STRIP', (0, 0))[1] == 0 or \
            cnt.get('RX_OTHER', (0, 0))[1] != 2 or cnt.get('TX_ARP_ICMP', (0, 0))[0] != 2 or \
            cnt.get('REQ_WC', (0, 0))[0] != cnt.get('REQ_WR', (0, 0))[0]:
        print('  counters: %s' % {k: cnt.get(k) for k in ('TX_VLAN_TAG', 'RX_VLAN_STRIP', 'RX_OTHER', 'TX_ARP_ICMP',
                                                           'REQ_WR', 'REQ_WC')})
        bad += 1
    m = re.search(r'axi_err=(\d+)', out)
    if not m or int(m.group(1)):
        bad += 1
    if mac_w != 512 and cnt['PAUSE_GATE'][0] + cnt['PAUSE_GATE'][1] == 0:
        print('  PAUSE (MAC hold level) never in force at a %d-bit MAC' % mac_w)
        bad += 1
    print('  system: ARP + ICMP replies, other-traffic frame, VLAN %d/%d, PAUSE loads %d/%d, counters %s' % (
        cnt['TX_VLAN_TAG'][0], cnt['RX_VLAN_STRIP'][1], cnt['PAUSE_GATE'][0], cnt['PAUSE_GATE'][1],
        'ok' if bad == 0 else 'BAD'))
    return bad


def main():
    args = sys.argv[1:]
    top = '--top' in args
    args = [a for a in args if a != '--top']
    mac_w = 512
    if '--mac-width' in args:
        i = args.index('--mac-width')
        mac_w = int(args[i + 1])
        del args[i:i + 2]
        if not top:
            print('--mac-width needs --top')
            return 1
    nwr = int(args[0]) if len(args) > 0 else 40
    seed = int(args[1]) if len(args) > 1 else 1
    drop = int(args[2]) if len(args) > 2 else 20
    names = args[3:] or [n for n in CONFIGS if not (top and CONFIGS[n][1].get('core_only')) and
                         not CONFIGS[n][1].get('separate')]
    fails = sum(run(n, nwr, seed, drop, top, mac_w) for n in names)
    print('%sPAIR TEST%s %s (%d failures)' % ('TOP ' if top else '', ' (%d-bit MAC)' % mac_w if mac_w != 512 else '',
                                             'PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
