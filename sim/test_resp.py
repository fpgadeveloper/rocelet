#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_resp.py - responder test: a remote requester (Python, frames built with roce_ref)
# sends WRITE / SEND / READ traffic to rocelet_core (xsim, tb_core_resp) on several QPs,
# interleaved, with injected duplicates, out-of-sequence packets, bad ICRCs, bad R_Keys,
# incoming ACKs, CNPs and non-RoCE frames, plus:
#   * partial READ re-issues (the requester re-reads the tail of an earlier READ from a
#     later PSN, as hardware NICs (mlx5 among them) do after a lost response packet), answered as
#     a continuation (MIDDLE ... LAST) with read_cont = 1, as a new response with 0;
#   * receive-buffer stalls: send_rnr set for a QP while a SEND arrives -> RNR NAK with
#     the configured timer code, the rest of the message dropped silently, then the
#     requester retries the message;
#   * duplicate READs outside the memory window (dropped).
# A Python model of the RC responder rules (IBTA ch. 9.7) predicts the memory writes,
# SEND stream, receive completions (with message lengths), received ACKs, QP errors and
# every transmitted ACK / NAK / READ response frame; all are compared.
# With --top the same traffic goes through the complete IP (tb_top_resp: rocelet_top with
# its MAC glue, AXI-Lite configuration and AXI4 memory master into a memory model); the
# memory check then compares the final memory image.
# Usage: test_resp.py [--top] [nops] [seed] [config...]
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import roce_ref as R  # noqa: E402
import simlib as S  # noqa: E402

FILES = S.files(*S.CORE, 'tb_core_resp.sv')
FILES_TOP = S.top_files('tb_top_resp.sv')

MY_MAC, MY_IP4 = 0x020000000001, 0xC0A80201
MY_IP6 = (0xFE80 << 112) | 0xC0A80201
QPN_BASE = 0x100
SYN_ACK, NAK_SEQ, NAK_INV, NAK_ACC = 0x1F, 0x60, 0x61, 0x62
RNR_TIMER = 14
M24 = 0xFFFFFF

CONFIGS = {
    'qp8_mr4_cont':   dict(g=dict(NUM_QP=8, NUM_MR=4, PMTU_RUNTIME=1, IPV6_EN=0, READ_DEPTH=4), read_cont=1),
    'qp8_mr4_ibta':   dict(g=dict(NUM_QP=8, NUM_MR=4, PMTU_RUNTIME=1, IPV6_EN=0, READ_DEPTH=4), read_cont=0),
    'qp1_mr1_v6':     dict(g=dict(NUM_QP=1, NUM_MR=1, PMTU_RUNTIME=0, IPV6_EN=1, READ_DEPTH=16), read_cont=1),
    'qp2_mr2_ibta':   dict(g=dict(NUM_QP=2, NUM_MR=2, PMTU_RUNTIME=1, IPV6_EN=0, READ_DEPTH=8), read_cont=0),
    'qp64_mr16':      dict(g=dict(NUM_QP=64, NUM_MR=16, PMTU_RUNTIME=1, IPV6_EN=0, READ_DEPTH=1), read_cont=1),
    'qp2_rd1_cont':   dict(g=dict(NUM_QP=2, NUM_MR=2, PMTU_RUNTIME=1, IPV6_EN=0, READ_DEPTH=1), read_cont=1),
}


def pat(a):
    return (a ^ (a >> 8) ^ 0x5A) & 0xFF


class Model:
    def __init__(self, qps, mrs, g, read_cont):
        self.g = g
        self.qps = qps
        self.mrs = mrs
        self.read_cont = read_cont
        self.st = {q: dict(epsn=c['epsn'], msn=0, opst=0, cur=0, resid=0, mlen=0, nak=0, err=0, rd=0, hist=[])
                   for q, c in qps.items()}
        self.tx, self.wr, self.send, self.cpl, self.ack, self.err = [], [], [], [], [], []
        self.n_cont = 0
        self.n_rnr = 0

    def pmtu(self, q):
        return 1 << (self.qps[q]['pmtu'] if self.g['PMTU_RUNTIME'] else 12)

    def rsp(self, q, op, psn, syn=None, msn=None, payload=b''):
        self.tx.append(dict(opcode=op, psn=psn & M24, dqpn=self.qps[q]['dqpn'], syndrome=syn,
                            msn=msn, payload=payload))

    def read_resp(self, q, laddr, L, psn, msn, cont=False):
        pm = self.pmtu(q)
        n = max(1, -(-L // pm))
        for i in range(n):
            ln = min(pm, L - i * pm) if L else 0
            first, last = i == 0 and not cont, i == n - 1
            op = 0x10 if first and last else 0x0D if first else 0x0F if last else 0x0E
            data = bytes(pat(laddr + i * pm + j) for j in range(ln))
            e = dict(opcode=op, psn=(psn + i) & M24, dqpn=self.qps[q]['dqpn'], payload=data)
            if op != 0x0E:
                e.update(syndrome=SYN_ACK, msn=msn)
            self.tx.append(e)

    def mr_check(self, f, c_rd):
        mr = self.mrs.get(f['rkey'] & (self.g['NUM_MR'] - 1)) if self.g['NUM_MR'] > 1 else self.mrs[0]
        off = f['va'] - mr['va']
        ok = (mr['valid'] and mr['rkey'] == f['rkey'] and (mr['acc'] & (2 if c_rd else 1)) and
              off >= 0 and off + f['dmalen'] <= mr['len'] and (f['va'] & 63) == 0)
        return ok, (mr['laddr'] + off) & ((1 << 64) - 1)

    def frame(self, f, good, rnr_mask):
        """Apply one received RoCE frame (parsed dict f)."""
        q = f['dqpn'] - QPN_BASE
        if q < 0 or q >= self.g['NUM_QP']:
            return
        s = self.st[q]
        if s['err']:
            return
        op = f['opcode']
        o5 = op & 0x1F
        pm = self.pmtu(q)
        if o5 == 0x11:
            if good:
                self.ack.append((q, f['psn'], f['syndrome'], f['msn']))
            return
        diff = (f['psn'] - s['epsn']) & M24
        c_send, c_wr, c_rd = o5 <= 5, 6 <= o5 <= 0xB, o5 == 0xC
        first, mid = o5 in (0, 6), o5 in (1, 7)
        last, only = o5 in (2, 3, 8, 9), o5 in (4, 5, 0xA, 0xB)
        imm = o5 in (3, 5, 9, 0xB)
        pl = len(f['payload'])
        if diff & 0x800000:
            if not good:
                return
            if c_rd:
                ok, laddr = self.mr_check(f, True)
                if f['dmalen'] and not ok:
                    return                          # bad duplicate READ: dropped
                cont = False
                if self.read_cont:
                    for (fp, npk) in s['hist']:
                        dd = (f['psn'] - fp) & M24
                        if 0 < dd <= npk - 1:
                            cont = True
                if cont:
                    self.n_cont += 1
                self.read_resp(q, laddr, f['dmalen'], f['psn'], s['msn'], cont)
            elif f['ackreq']:
                self.rsp(q, 0x11, s['epsn'] - 1, SYN_ACK, s['msn'])
            return
        if diff:
            if good and not s['nak']:
                self.rsp(q, 0x11, s['epsn'], NAK_SEQ, s['msn'])
                s['nak'] = 1
            return
        bad_inv = (((mid or last) and s['opst'] != (2 if c_send else 1)) or
                   ((first or only or c_rd) and s['opst'] != 0) or
                   ((first or mid) and pl != pm) or ((last or only) and pl > pm) or
                   (c_rd and s['rd'] >= self.g['READ_DEPTH']) or
                   (c_wr and last and s['resid'] != pl) or
                   (c_wr and only and f.get('dmalen') != pl) or not (c_send or c_wr or c_rd))
        act, addr = None, None
        if bad_inv:
            act = 'NAK_INV'
        elif (c_wr and (first or only) and f['dmalen']) or (c_rd and f['dmalen']):
            ok, addr = self.mr_check(f, c_rd)
            act = ('READ' if c_rd else ('WRITE' if pl else 'NOPAY')) if ok else 'NAK_ACC'
        elif c_send and (first or only) and (rnr_mask >> q) & 1:
            act = 'RNR'
        else:
            addr = s['cur']
            act = 'READ' if c_rd else ('NOPAY' if pl == 0 else ('SEND' if c_send else 'WRITE'))
        # cut-through side effects (before the ICRC verdict)
        if act == 'WRITE':
            self.wr.append((addr, f['payload']))
        if act == 'SEND':
            self.send.append((q, int(first or only), int(last or only), f['payload'], int(good)))
        if not good:
            return
        if act in ('WRITE', 'SEND', 'NOPAY', 'READ'):
            npk = max(1, -(-f['dmalen'] // pm)) if c_rd else 1
            done = last or only or c_rd
            s['epsn'] = (s['epsn'] + npk) & M24
            s['msn'] = (s['msn'] + (1 if done else 0)) & M24
            s['nak'] = 0
            s['opst'] = (2 if c_send else 1) if first else (s['opst'] if mid else 0)
            s['resid'] = (f.get('dmalen', 0) - pl) if first else (s['resid'] - pl)
            if c_wr:
                s['mlen'] = f['dmalen'] if (first or only) else s['mlen']
            else:
                s['mlen'] = (0 if (first or only) else s['mlen']) + pl
            s['cur'] = addr + pl
            if (last or only) and (c_send or imm):
                self.cpl.append((q, int(c_send), int(imm), f.get('imm', 0) if imm else None, s['mlen']))
            if act == 'READ':
                s['rd'] += 1
                s['hist'].append((f['psn'], npk))
                s['hist'] = s['hist'][-self.g['READ_DEPTH']:]
                self.read_resp(q, addr, f['dmalen'], f['psn'], s['msn'])
            elif f['ackreq']:
                self.rsp(q, 0x11, f['psn'], SYN_ACK, s['msn'])
        elif act == 'RNR':
            self.rsp(q, 0x11, f['psn'], 0x20 | RNR_TIMER, s['msn'])
            s['nak'] = 1
            self.n_rnr += 1
        else:
            self.rsp(q, 0x11, f['psn'], NAK_INV if act == 'NAK_INV' else NAK_ACC, s['msn'])
            s['err'] = 1
            self.err.append((q, NAK_INV if act == 'NAK_INV' else NAK_ACC))


def run(name, nops, seed, top=False):
    C = CONFIGS[name]
    g = C['g']
    rng = random.Random(seed)
    d = os.path.join(S.BUILD, ('top_resp_' if top else 'resp_') + name)
    os.makedirs(d, exist_ok=True)
    NQ, NM = g['NUM_QP'], g['NUM_MR']
    qps = {}
    for q in range(NQ):
        qps[q] = dict(epsn=rng.choice([rng.getrandbits(24), M24 - rng.randrange(8)]),
                      pmtu=rng.randint(8, 12), ipv6=int(g['IPV6_EN'] and rng.random() < 0.5),
                      dmac=rng.getrandbits(48), dip=rng.getrandbits(128 if g['IPV6_EN'] else 32),
                      dqpn=rng.getrandbits(24), sport=rng.getrandbits(16))
    mrs = {}
    for i in range(NM):
        mrs[i] = dict(valid=1, rkey=(rng.getrandbits(32) & ~(NM - 1)) | i if NM > 1 else rng.getrandbits(32),
                      va=rng.getrandbits(48) & ~63, len=rng.choice([1 << 16, 1 << 18, 1 << 20]),
                      laddr=rng.getrandbits(40) & ~63, acc=3 if i == 0 else rng.choice([3, 3, 1, 2]))
    with open(os.path.join(d, 'cfg_qp.txt'), 'w') as f:
        for q, c in qps.items():
            f.write('%x 1 %x %x %x %x %x %x %x\n' % (q, c['epsn'], c['pmtu'], c['ipv6'], c['dmac'],
                                                   c['dip'], c['dqpn'], c['sport']))
    with open(os.path.join(d, 'cfg_mr.txt'), 'w') as f:
        for i, m in mrs.items():
            f.write('%x 1 %x %x %x %x %x\n' % (i, m['rkey'], m['va'], m['len'], m['laddr'], m['acc']))
    model = Model(qps, mrs, g, C['read_cont'])
    peer = {q: dict(psn=c['epsn'], hist=[], reads=0, rd=[]) for q, c in qps.items()}
    frames = []        # (bytes, rnr_mask, sync)
    mask = [0]
    sync = [0]

    def emit(q, op, payload=b'', psn=None, good=True, **kw):
        c = qps[q]
        p = peer[q]
        if psn is None:
            psn = p['psn']
        ip = dict(ipv6=bool(c['ipv6']), dmac=MY_MAC, smac=c['dmac'], sport=c['sport'])
        if c['ipv6']:
            ip.update(sip6=c['dip'], dip6=MY_IP6)
        else:
            ip.update(sip=c['dip'] & 0xFFFFFFFF, dip=MY_IP4)
        fr = R.build_frame(op, payload, dqpn=QPN_BASE + q, psn=psn, **ip, **kw)
        pf = R.parse_frame(fr)
        if not good:
            fr = fr[:-1] + bytes([fr[-1] ^ 0x01])
        frames.append((fr, mask[0], sync[0]))
        sync[0] = 0
        model.frame(pf, good, mask[0])
        return fr, pf

    def read_slot(q):
        # a READ needs a free READ resource; when the requester used them all, it waits
        # until the responder is idle (every response sent) and starts over
        if peer[q]['reads'] >= g['READ_DEPTH']:
            sync[0] = 1
            for x in peer.values():
                x['reads'] = 0
            for x in model.st.values():
                x['rd'] = 0
        peer[q]['reads'] += 1

    def mr_for(acc, L):
        cand = [i for i, m in mrs.items() if m['acc'] & acc and m['len'] >= L + 64]
        if not cand:
            return None
        i = rng.choice(cand)
        m = mrs[i]
        if top:
            # with real memory behind the IP, READs use the upper half of a window and WRITEs
            # the lower half, so that READ data is the memory's initial pattern
            half = m['len'] // 2
            if L + 64 > half:
                return None
            off = rng.randrange(0, (half - L) // 64 + 1) * 64 + (half if acc == 2 else 0)
        else:
            off = rng.randrange(0, (m['len'] - L) // 64 + 1) * 64
        return m, m['va'] + off

    def send_msg(q, L=None, rnr=False):
        pm = model.pmtu(q)
        p = peer[q]
        if L is None:
            L = rng.choice([0, rng.randint(1, 100), pm, rng.randint(pm + 1, 3 * pm)])
        imm = rng.random() < 0.3
        n = max(1, -(-L // pm))
        data = bytes(rng.getrandbits(8) for _ in range(L))
        immv = rng.getrandbits(32)
        start = p['psn']
        pkts = []
        for i in range(n):
            first, last = i == 0, i == n - 1
            if first and last:
                op = R.OP['SEND_ONLY_IMM' if imm else 'SEND_ONLY']
            elif first:
                op = R.OP['SEND_FIRST']
            elif last:
                op = R.OP['SEND_LAST_IMM' if imm else 'SEND_LAST']
            else:
                op = R.OP['SEND_MIDDLE']
            pkts.append((op, data[i * pm:(i + 1) * pm], dict(imm=immv, ackreq=int(last))))
        if rnr:
            # the receiver has no buffer: RNR NAK for the first packet, the packets already
            # in flight are dropped silently; the requester retries the whole message
            mask[0] |= 1 << q
            for i, (op, ch, kw) in enumerate(pkts[:2]):
                emit(q, op, ch, psn=(start + i) & M24, **kw)
            mask[0] &= ~(1 << q)
        for i, (op, ch, kw) in enumerate(pkts):
            if rng.random() < 0.06:
                emit(q, op, ch, psn=(start + i) & M24, good=False, **kw)
            emit(q, op, ch, psn=(start + i) & M24, **kw)
            p['hist'].append((op, ch, (start + i) & M24, kw))
        p['psn'] = (start + n) & M24

    def message(q, kind):
        pm = model.pmtu(q)
        p = peer[q]
        if kind == 'WRITE':
            L = rng.choice([0, rng.randint(1, 200), pm, 2 * pm + rng.randint(1, pm), rng.randint(1, 3 * pm)])
            r = mr_for(1, L)
            if r is None:
                return
            m, va = r
            imm = rng.random() < 0.3
            n = max(1, -(-L // pm))
            data = bytes(rng.getrandbits(8) for _ in range(L))
            for i in range(n):
                first, last = i == 0, i == n - 1
                if first and last:
                    op = R.OP['WRITE_ONLY_IMM' if imm else 'WRITE_ONLY']
                elif first:
                    op = R.OP['WRITE_FIRST']
                elif last:
                    op = R.OP['WRITE_LAST_IMM' if imm else 'WRITE_LAST']
                else:
                    op = R.OP['WRITE_MIDDLE']
                ch = data[i * pm:(i + 1) * pm]
                ack = int(last or rng.random() < 0.1)
                kw = dict(va=va, rkey=m['rkey'], dmalen=L, imm=rng.getrandbits(32), ackreq=ack)
                if rng.random() < 0.06:
                    emit(q, op, ch, good=False, **kw)
                emit(q, op, ch, **kw)
                p['hist'].append((op, ch, p['psn'], kw))
                p['psn'] = (p['psn'] + 1) & M24
        elif kind == 'SEND':
            send_msg(q)
        elif kind == 'RNR':
            send_msg(q, L=rng.choice([rng.randint(1, 100), 2 * pm + 5]), rnr=True)
        elif kind == 'READ':
            L = rng.choice([0, rng.randint(1, 100), pm, rng.randint(pm + 1, 4 * pm), rng.randint(pm + 1, 4 * pm)])
            r = mr_for(2, L)
            if r is None:
                return
            m, va = r
            read_slot(q)
            kw = dict(va=va, rkey=m['rkey'], dmalen=L)
            emit(q, R.OP['READ_REQ'], b'', **kw)
            p['hist'].append((R.OP['READ_REQ'], b'', p['psn'], kw))
            p['rd'].append((p['psn'], kw))
            p['psn'] = (p['psn'] + max(1, -(-L // pm))) & M24
        elif kind == 'PREAD':
            # re-issue the tail of an earlier multi-packet READ from packet k
            cands = [(ps, kw) for ps, kw in p['rd'][-g['READ_DEPTH'] - 1:] if kw['dmalen'] > pm]
            if not cands:
                return
            ps, kw = rng.choice(cands)
            npk = -(-kw['dmalen'] // pm)
            k = 0 if rng.random() < 0.2 else rng.randrange(1, npk)      # 0 = whole re-issue
            read_slot(q)
            kw2 = dict(va=kw['va'] + k * pm, rkey=kw['rkey'], dmalen=kw['dmalen'] - k * pm, ackreq=1)
            emit(q, R.OP['READ_REQ'], b'', psn=(ps + k) & M24, **kw2)

    live = list(range(NQ))
    killed = set()
    for i in range(nops):
        q = rng.choice(live)
        k = rng.random()
        if (i == (3 * nops) // 4 and len(live) > 1) or (i == nops - 1 and len(live) == 1):
            k = 0.89          # one bad R_Key per run
        if k < 0.30:
            message(q, 'WRITE')
        elif k < 0.45:
            message(q, 'SEND')
        elif k < 0.50:
            message(q, 'RNR')
        elif k < 0.57:
            message(q, 'READ')
        elif k < 0.64:
            message(q, 'PREAD')
        elif k < 0.70 and peer[q]['hist']:
            # duplicate of an earlier, accepted packet (re-ACK / re-read)
            op, ch, psn, kw = rng.choice(peer[q]['hist'][-6:])
            if op == R.OP['READ_REQ']:
                read_slot(q)
                if rng.random() < 0.15:
                    kw = dict(kw)
                    kw['rkey'] ^= 0x40000000        # bad duplicate READ: dropped
            kw = dict(kw)
            kw['ackreq'] = 1
            emit(q, op, ch, psn=psn, **kw)
        elif k < 0.76:
            # out of sequence (a lost packet): twice, only one NAK expected
            emit(q, R.OP['SEND_ONLY'], b'oos', psn=(peer[q]['psn'] + 1) & M24, ackreq=1)
            emit(q, R.OP['SEND_ONLY'], b'oos2', psn=(peer[q]['psn'] + 2) & M24, ackreq=1)
        elif k < 0.82:
            emit(q, R.OP['ACK'], b'', psn=rng.getrandbits(24), syndrome=rng.choice([0x1F, 0x60, 0x20]),
                 msn=rng.getrandbits(24))
        elif k < 0.88:
            # CNP and a non-RoCE UDP frame: dropped
            c = qps[q]
            fr = R.build_frame(R.OP['SEND_ONLY'], b'', dqpn=QPN_BASE + q, sip=c['dip'] & 0xFFFFFFFF, dip=MY_IP4,
                               dmac=MY_MAC)
            cnp = bytearray(fr)
            cnp[42] = 0x81
            frames.append((bytes(cnp), mask[0], 0))
            udp = bytearray(fr)
            udp[36:38] = b'\x12\x34'
            frames.append((bytes(udp), mask[0], 0))
        elif k < 0.90 and (i > nops // 2 and len(live) > 1 or k == 0.89):
            # bad R_Key on a WRITE ONLY: NAK remote access, QP error
            m = mrs[0]
            emit(q, R.OP['WRITE_ONLY'], b'x' * 8, va=m['va'], rkey=m['rkey'] ^ 0x80000000,
                 dmalen=8, ackreq=1)
            if len(live) > 1:
                live.remove(q)
            killed.add(q)
            emit(q, R.OP['SEND_ONLY'], b'after-error', psn=(peer[q]['psn'] + 1) & M24)
    with open(os.path.join(d, 'rx.txt'), 'w') as f:
        for fr, m, sy in frames:
            for last, n, ch in R.frame_to_beats(fr):
                f.write(R.beat_line(last, n, ch) + ' %x %d\n' % (m, sy))
    plus = ['dir=' + d, 'seed=%d' % seed, 'gap=%s' % os.environ.get('GAP', '15'),
            'bp=%s' % os.environ.get('BP', '25'), 'read_cont=%d' % C['read_cont']]
    out, log = S.xsim(d, 'tb_top_resp' if top else 'tb_core_resp', g, FILES_TOP if top else FILES, plus)
    print('[%s] %d frames in: %s' % (name, len(frames), out.replace('\n', ' | ')))
    if 'TB_DONE' not in out:
        return 1
    bad = 0
    # --- transmitted frames ---
    got = [fr for fr, _ in R.read_beats(os.path.join(d, 'tx.txt'))]
    if len(got) != len(model.tx):
        print('  TX: %d frames, expected %d' % (len(got), len(model.tx)))
        bad += 1
    for i, (fr, e) in enumerate(zip(got, model.tx)):
        p = R.parse_frame(fr)
        errs = [k for k, v in e.items() if v is not None and p.get(k) != v]
        if not p['icrc_ok'] or not p['frame_len_ok'] or (not p['ipv6'] and not p['ip_csum_ok']):
            errs.append('icrc/len/csum')
        if errs:
            bad += 1
            if bad < 8:
                print('  TX frame %d: %s got %s exp %s' % (
                    i, errs, {k: p.get(k) for k in errs if k in p and k != 'payload'},
                    {k: e.get(k) for k in errs if k in e and k != 'payload'}))
    # --- memory writes ---
    wr = []
    if top:
        # final memory image: every byte the model wrote, and nothing else
        img = {}
        for a, data in model.wr:
            for j, b in enumerate(data):
                img[a + j] = b
        got_img = {}
        for line in open(os.path.join(d, 'mem.txt')):
            a, h = line.split()
            for j, b in enumerate(bytes.fromhex(h)):
                got_img[int(a, 16) + j] = b
        wbad = sum(1 for a, b in img.items() if got_img.get(a) != b) + sum(1 for a in got_img if a not in img)
        if wbad:
            print('  memory: %d bytes written, %d expected, %d mismatches' % (len(got_img), len(img), wbad))
        wr = model.wr
    else:
        cur = None
        for line in open(os.path.join(d, 'wr.txt')):
            t = line.split()
            if t[0] == 'C':
                cur = [int(t[1], 16), int(t[2], 16), bytearray()]
                wr.append(cur)
            else:
                cur[2] += bytes.fromhex(t[3])[::-1][:int(t[2])]
        wexp = model.wr
        wbad = sum(1 for a, b in zip(wr, wexp) if (a[0], bytes(a[2])) != b or a[1] != len(b[1]))
        wbad += abs(len(wr) - len(wexp))
        if wbad:
            print('  WR: %d writes (%d expected), %d mismatches' % (len(wr), len(wexp), wbad))
    bad += wbad
    if top:
        mm = re.search(r'fifo_drop=(\d+) underrun=(\d+) axi_err=(\d+)', out)
        if not mm or any(int(x) for x in mm.groups()):
            print('  RX FIFO drops / TX underruns / AXI errors: %s' % (str(mm.groups()) if mm else '-'))
            bad += 1
    # --- SEND stream ---
    sends, curp = [], bytearray()
    for line in open(os.path.join(d, 'send.txt')):
        t = line.split()
        if t[0] == 'E':
            sends[-1][4] = int(t[1]) if sends and sends[-1][4] is None else sends[-1][4]
            continue
        curp += bytes.fromhex(t[2])[::-1][:int(t[1])]
        if int(t[0]):
            sends.append([int(t[3]), int(t[4]), int(t[5]), bytes(curp), None])
            curp = bytearray()
    sexp = [list(x) for x in model.send]
    sbad = sum(1 for a, b in zip(sends, sexp) if a != b) + abs(len(sends) - len(sexp))
    if sbad:
        print('  SEND: %d packets (%d expected), %d mismatches' % (len(sends), len(sexp), sbad))
    bad += sbad
    # --- completions, ACKs in, errors ---
    cpl = []
    for line in open(os.path.join(d, 'cpl.txt')):
        q, snd, hi, im, ln = line.split()
        cpl.append((int(q), int(snd), int(hi), int(im, 16) if int(hi) else None, int(ln)))
    cbad = sum(1 for a, b in zip(cpl, model.cpl) if a != b) + abs(len(cpl) - len(model.cpl))
    acks = [tuple(int(x, 16) if i else int(x) for i, x in enumerate(l.split()))
            for l in open(os.path.join(d, 'ack.txt'))]
    abad = sum(1 for a, b in zip(acks, model.ack) if a != b) + abs(len(acks) - len(model.ack))
    errs = [(int(l.split()[0]), int(l.split()[1], 16)) for l in open(os.path.join(d, 'err.txt'))]
    ebad = int(errs != model.err)
    if cbad or abad or ebad:
        print('  CPL %d/%d bad %d, ACK-in %d/%d bad %d, ERR %s vs %s' % (
            len(cpl), len(model.cpl), cbad, len(acks), len(model.ack), abad, errs, model.err))
        for a, b in zip(cpl, model.cpl):
            if a != b:
                print('    cpl got %s exp %s' % (a, b))
                break
    bad += cbad + abad + ebad
    m = re.search(r'cont=(\d+) rnr=(\d+)', out)
    if not m or int(m.group(1)) != model.n_cont or int(m.group(2)) != model.n_rnr:
        print('  continuations / RNR NAKs: got %s, expected %d / %d' % (
            str(m.groups()) if m else '-', model.n_cont, model.n_rnr))
        bad += 1
    print('  TX %d frames (%d READ resp), %d writes, %d SEND pkts, %d cpl, %d ACK-in, %d QP errors, '
          '%d continuations, %d RNR NAKs: %d errors' % (
              len(got), sum(1 for e in model.tx if e['opcode'] != 0x11), len(wr), len(sends), len(cpl),
              len(acks), len(errs), model.n_cont, model.n_rnr, bad))
    return bad


def main():
    args = sys.argv[1:]
    top = '--top' in args
    args = [a for a in args if a != '--top']
    nops = int(args[0]) if len(args) > 0 else 60
    seed = int(args[1]) if len(args) > 1 else 1
    names = args[2:] or list(CONFIGS)
    fails = sum(run(n, nops, seed, top) for n in names)
    print('%sRESP TEST %s (%d failures)' % ('TOP ' if top else '', 'PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
