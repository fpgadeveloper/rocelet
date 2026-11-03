#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_req_tx.py - random work requests through the requester TX path (rocelet_req_ctrl ->
# rocelet_tx_builder -> rocelet_icrc_tx, xsim tb_req_tx); every output frame is parsed and
# checked against a Python model of RoCE v2 segmentation: opcode sequence, PSN, AckReq
# (last packet and every N packets), SE, MigReq, dest QPN, RETH / ImmDt, payload, pad
# count, MAC / IP / UDP fields and lengths, IPv4 header checksum, ICRC (roce_ref), and
# every IPv4 frame is re-built by scapy.contrib.roce (ICRC computed by scapy) and must be
# identical. QP types RC, UC and HSB; the HSB frames (payload a multiple of 4 bytes) must
# be byte-identical to the frame NVIDIA's HSB IP builds (hsb_ref.packet), and every HSB
# metadata record must decode (hsb_ref.parse_metadata) with the PSN the host's
# RoceReceiver compares against the immediate.
# Usage: test_req_tx.py [nwr] [seed] [config...]
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hsb_ref as H  # noqa: E402
import roce_ref as R  # noqa: E402
import simlib as S  # noqa: E402

FILES = S.files('rocelet_pkg.sv', 'common/rocelet_crc32_xor.sv', 'common/rocelet_crc32_inv.sv',
                'common/rocelet_keep2n.sv', 'common/rocelet_fifo.sv', 'common/rocelet_crc32_core.sv',
                'common/rocelet_byte_shift.sv', 'common/rocelet_ram_sdp.sv', 'icrc/rocelet_icrc_mask.sv',
                'icrc/rocelet_icrc_tx.sv', 'tx/rocelet_tx_builder.sv', 'tx/rocelet_req_ctrl.sv', 'tb_req_tx.sv')

MY_MAC, MY_IP4 = 0x020000000001, 0xC0A80201
MY_IP6 = (0xFE80 << 112) | 0xC0A80201
RC, UC, HSB = 0, 1, 2

CONFIGS = {
    # name: generics, QP types (cycled), AckReq interval
    'qp8_rt_v6':      (dict(NUM_QP=8, PMTU_RUNTIME=1, IPV6_EN=1, SHIFT_GENERIC=0, ICRC_GRAN=4, OPSET=1), [RC, UC], 4),
    'qp1_fix_v4':     (dict(NUM_QP=1, PMTU_RUNTIME=0, IPV6_EN=0, SHIFT_GENERIC=0, ICRC_GRAN=4, OPSET=2), [RC], 0),
    'qp64_fix_v4_uc': (dict(NUM_QP=64, PMTU_RUNTIME=0, IPV6_EN=0, SHIFT_GENERIC=1, ICRC_GRAN=1, OPSET=1), [UC], 0),
    'qp8_fixfmt_v6':  (dict(NUM_QP=8, PMTU_RUNTIME=1, IPV6_EN=1, SHIFT_GENERIC=0, ICRC_GRAN=4, OPSET=0), [RC], 0),
    'hsb':            (dict(NUM_QP=4, PMTU_RUNTIME=1, IPV6_EN=0, SHIFT_GENERIC=0, ICRC_GRAN=4, OPSET=2),
                       [HSB, RC, HSB, UC], 16),
}


def model(cfg, wrs, generics, ackreq_n):
    """Expected packets: list of dicts per frame in order."""
    exp = []
    psn = {q: c['psn'] for q, c in cfg.items()}
    for w in wrs:
        q = w['qp']
        c = cfg[q]
        ty = c['type']
        pm = 1 << (c['pmtu'] if generics['PMTU_RUNTIME'] else 12)
        L = w['len']
        n = max(1, -(-L // pm))
        is_send, is_imm = w['cls'] >> 1, w['cls'] & 1
        hsb_wr = ty == HSB and not is_send
        since = 0
        for i in range(n):
            first, last = i == 0, i == n - 1
            chunk = w['data'][i * pm:(i + 1) * pm]
            if hsb_wr:
                op = 'WRITE_ONLY_IMM' if (is_imm and last) else 'WRITE_ONLY'
            elif first and last:
                op = ('SEND_ONLY' if is_send else 'WRITE_ONLY') + ('_IMM' if is_imm else '')
            elif first:
                op = 'SEND_FIRST' if is_send else 'WRITE_FIRST'
            elif not last:
                op = 'SEND_MIDDLE' if is_send else 'WRITE_MIDDLE'
            else:
                op = ('SEND_LAST' if is_send else 'WRITE_LAST') + ('_IMM' if is_imm else '')
            opc = R.OP[op] | (0x20 if ty != RC else 0)
            ackreq = 0 if ty != RC else int(last or (ackreq_n and since == ackreq_n - 1))
            since = 0 if ackreq else since + 1
            if hsb_wr and is_imm and last and (w['flags'] & 2) and len(chunk) >= 8:
                chunk = chunk[:4] + bytes([0]) + psn[q].to_bytes(3, 'big') + chunk[8:]
            e = dict(opcode=opc, psn=psn[q], dqpn=c['dqpn'], ackreq=ackreq, payload=chunk,
                     ipv6=bool(c['ipv6']), dmac=c['dmac'], sport=c['sport'], dport=c['dport'] or 4791,
                     se=int(bool(w['flags'] & 1) and last and bool(is_send or is_imm)),
                     migreq=0 if ty == HSB else 1)
            if R.OP[op] in R.HAS_RETH:
                if hsb_wr:
                    e.update(va=(w['va'] + i * pm) & (2 ** 64 - 1), rkey=w['rkey'], dmalen=len(chunk))
                else:
                    e.update(va=w['va'], rkey=w['rkey'], dmalen=L)
            if R.OP[op] in R.HAS_IMM:
                e['imm'] = H.imm(psn[q], w['imm']) if hsb_wr else w['imm']
            e['_hsb'] = hsb_wr
            e['_qp'] = q
            e['_md'] = hsb_wr and is_imm and last and bool(w['flags'] & 2)
            exp.append(e)
            psn[q] = (psn[q] + 1) & 0xFFFFFF
    return exp


def run(name, nwr, seed):
    g, types, ackreq_n = CONFIGS[name]
    rng = random.Random(seed)
    d = os.path.join(S.BUILD, 'req_tx_' + name)
    os.makedirs(d, exist_ok=True)
    nq = g['NUM_QP']
    cfg = {}
    for q in range(nq):
        ty = types[q % len(types)]
        cfg[q] = dict(ipv6=(rng.random() < 0.5) if (g['IPV6_EN'] and ty != HSB) else 0, dmac=rng.getrandbits(48),
                      dip=rng.getrandbits(128) if g['IPV6_EN'] else rng.getrandbits(32),
                      dqpn=rng.getrandbits(24), sport=rng.getrandbits(16),
                      dport=rng.choice([0, 0, 12345]) if ty == HSB else 0,
                      psn=rng.choice([rng.getrandbits(24), 0xFFFFF0 + rng.randrange(16), 0]),
                      pmtu=rng.randint(8, 12), type=ty)
    with open(os.path.join(d, 'cfg.txt'), 'w') as f:
        for q, c in cfg.items():
            f.write('%x %x %x %x %x %x %x %x %x %x\n' % (q, c['ipv6'], c['dmac'], c['dip'], c['dqpn'],
                                                       c['sport'], c['dport'], c['psn'], c['pmtu'], c['type']))
    wrs = []
    for i in range(nwr):
        q = rng.randrange(nq)
        pm = 1 << (cfg[q]['pmtu'] if g['PMTU_RUNTIME'] else 12)
        kind = rng.random()
        if kind < 0.1:
            L = 0
        elif kind < 0.3:
            L = rng.randint(1, 70)
        elif kind < 0.6:
            L = rng.choice([pm, 2 * pm, pm - 1, pm + 1, 3 * pm + rng.randint(1, pm)])
        else:
            L = rng.randint(1, 3 * pm)
        L = min(L, 12000)
        cls = rng.randrange(4)
        flags = rng.getrandbits(1)
        data = bytes(rng.getrandbits(8) for _ in range(L))
        if g['OPSET'] == 0:          # fixed format: single-packet RDMA WRITE (no imm) only
            cls, L, flags = 0, min(L, pm), 0
            data = data[:L]
        if cfg[q]['type'] == HSB and rng.random() < 0.7:
            # an HSB frame: 128-byte units, then its metadata record (WRITE with immediate)
            cls, flags = 0, 0
            L = 128 * rng.randint(1, 40)
            data = bytes(rng.getrandbits(8) for _ in range(L))
            page = rng.randrange(4096)
            base = rng.getrandbits(40) << 12
            wrs.append(dict(qp=q, cls=cls, va=base, rkey=rng.getrandbits(32), len=L, imm=0, laddr=0,
                            id=len(wrs), data=data, flags=flags))
            md = H.metadata(flags=0, psn=0, crc=0, ts_s=rng.getrandbits(48), ts_ns=rng.getrandbits(30),
                            bytes_written=L, frame_number=rng.getrandbits(16))
            wrs.append(dict(qp=q, cls=1, va=base + ((L + 127) // 128) * 128, rkey=wrs[-1]['rkey'],
                            len=H.METADATA_SIZE, imm=page, laddr=0, id=len(wrs), data=md, flags=2))
            continue
        wrs.append(dict(qp=q, cls=cls, va=rng.getrandbits(64), rkey=rng.getrandbits(32),
                        len=L, imm=rng.getrandbits(32), laddr=rng.getrandbits(48), id=len(wrs),
                        data=data, flags=flags | (rng.getrandbits(1) << 1)))
    with open(os.path.join(d, 'wr.txt'), 'w') as f:
        for w in wrs:
            f.write('%x %x %x %x %x %x %x %x %x\n' % (w['qp'], w['cls'], w['va'], w['rkey'], w['len'],
                                                     w['imm'], w['laddr'], w['id'], w['flags']))
    with open(os.path.join(d, 'pay.txt'), 'w') as f:
        for w in wrs:
            data = w['data']
            for i in range(0, len(data), 64):
                ch = data[i:i + 64] + bytes(rng.getrandbits(8) for _ in range(64 - len(data[i:i + 64])))
                f.write(ch[::-1].hex() + '\n')
    exp = model(cfg, wrs, g, ackreq_n)
    plus = ['dir=' + d, 'seed=%d' % seed, 'gap=15', 'bp=25', 'nexp=%d' % len(exp), 'ackreq_n=%d' % ackreq_n]
    out, log = S.xsim(d, 'tb_req_tx', g, FILES, plus)
    print('[%s] %s' % (name, out.replace('\n', ' | ')))
    if 'TB_DONE' not in out:
        return 1
    got = [fr for fr, _ in R.read_beats(os.path.join(d, 'out.txt'))]
    bad = 0
    if len(got) != len(exp):
        print('  %d frames, expected %d' % (len(got), len(exp)))
        bad += 1
    nhsb = nmeta = 0
    for i, (fr, e) in enumerate(zip(got, exp)):
        p = R.parse_frame(fr)
        errs = []
        for k, v in e.items():
            if k.startswith('_'):
                continue
            if k == 'migreq':
                if ((fr[(62 if p['ipv6'] else 42) + 1] >> 6) & 1) != v:
                    errs.append('migreq')
                continue
            if p.get(k) != v:
                errs.append('%s: got %r exp %r' % (k, p.get(k) if k != 'payload' else len(p.get(k, b'')),
                                                     v if k != 'payload' else len(v)))
        if not p['icrc_ok']:
            errs.append('ICRC')
        if not p['frame_len_ok']:
            errs.append('frame length')
        if not p['ipv6'] and not p['ip_csum_ok']:
            errs.append('IPv4 checksum')
        if p['smac'] != MY_MAC or p['udp_csum'] != 0:
            errs.append('smac/udp csum')
        if p['sip'] != (MY_IP6 if p['ipv6'] else MY_IP4):
            errs.append('sip')
        if p['padcnt'] != (-len(e['payload'])) % 4:
            errs.append('padcnt')
        if e['_hsb'] and len(e['payload']) % 4 == 0:
            # byte-identical to NVIDIA's HSB IP
            ref = H.packet(e['dmac'], MY_MAC, MY_IP4, cfg[e['_qp']]['dip'] & 0xFFFFFFFF, e['sport'], e['dport'],
                           e['dqpn'], e['psn'], e['va'], e['rkey'], e['payload'], e.get('imm'))
            if ref != fr:
                k = next(j for j in range(min(len(ref), len(fr))) if ref[j] != fr[j]) if len(ref) == len(fr) else -1
                errs.append('HSB format differs at byte %d' % k)
            nhsb += 1
        if e['_md']:
            m = H.parse_metadata(p['payload'])
            if not H.same_psn(m['psn'], H.psn_from_imm(p['imm'])) or H.page_from_imm(p['imm']) != \
                    (e['imm'] & 0xFFF):
                errs.append('HSB metadata PSN / page')
            nmeta += 1
        if errs:
            bad += 1
            if bad < 6:
                print('  frame %d (%s): %s' % (i, R.OPNAME.get(p['opcode'] & 0x1F), '; '.join(errs)))
    # scapy: every IPv4 frame dissected by scapy.contrib.roce and re-built with scapy's ICRC
    from scapy.all import Ether, IP, UDP, Raw  # noqa
    from scapy.contrib.roce import BTH
    nsc = 0
    for fr, e in zip(got, exp):
        if fr[12:14] != b'\x08\x00' or e['dport'] != 4791:
            continue
        pk = Ether(fr)
        bth = pk[BTH]
        if (bth.opcode != e['opcode'] or bth.psn != e['psn'] or bth.ackreq != e['ackreq'] or
                bth.pkey != 0xFFFF or bth.migreq != e['migreq'] or bth.dqpn != e['dqpn'] or
                pk[IP].flags != 'DF' or pk[UDP].chksum != 0):
            bad += 1
            print('  scapy field check failed: %s' % pk.summary())
        b = BTH(fr[42:54] + b'\0\0\0\0')
        b.remove_payload()
        b.icrc = None
        built = bytes(Ether(fr[:14]) / IP(fr[14:34]) / UDP(fr[34:42]) / b / Raw(fr[54:-4]))
        if built != fr:
            bad += 1
        nsc += 1
    print('  %d frames (%d expected), %d HSB packets byte-identical to NVIDIA HSB, %d HSB metadata records, '
          '%d IPv4 frames checked by scapy, %d errors' % (len(got), len(exp), nhsb, nmeta, nsc, bad))
    return bad


def main():
    nwr = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    names = sys.argv[3:] or list(CONFIGS)
    fails = sum(run(n, nwr, seed) for n in names)
    print('REQ_TX TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
