#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_read_reissue.py - READ responder under response loss with a closed-loop requester
# model (tb_core_resp + the responder model of test_resp.py).
#
# The requester keeps READ_DEPTH READs outstanding per QP (max_rd_atomic = READ_DEPTH) and
# loses READ response packets at random. Two requester behaviours, both seen on hardware NICs:
#   cx6   (ConnectX-6 Dx): data placement out of order, completion in order. A gap in the
#         response stream is noticed when the next packet arrives; the requester re-issues
#         the oldest incomplete READ from the first missing PSN within a few microseconds
#         (a partial re-issue, answered as a continuation, READ_CONT = 1) plus some of the
#         later outstanding READs whole. The stale original responses still in flight
#         complete some of those, so the responder sees duplicate READs for READs the
#         requester has already finished ("orphans") while new READs keep arriving.
#   timeout (re-issue after a timeout): in-order acceptance; nothing is re-issued until
#         the responder is idle (a timeout), then the oldest incomplete READ is re-issued
#         from the first missing PSN plus every later outstanding READ.
# A tail loss with no later traffic is re-issued after the responder went idle in both
# modes. A new READ is sent only when the requester has fewer than READ_DEPTH outstanding,
# right after the response that completed one; the testbench releases each request only
# once the engine has sent the frame the model reacted to (sync = 2 + frames).
# Checks: every transmitted frame equals the model (no NAK, in particular no NAK invalid
# request 0x61 from the READ-depth check; READ data = memory pattern; continuation
# opcodes), every READ completes at the requester with the right data, no QP error, the
# continuation count. Duplicate READs must not take a READ_DEPTH slot.
# Usage: test_read_reissue.py [nreads per QP] [seed] [config...]
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
import test_resp as T  # noqa: E402

M24 = 0xFFFFFF

CONFIGS = {
    # the hardware case: max_rd_atomic 16 = READ_DEPTH 16, ConnectX-style fast re-issue
    'rd16_cx6':  dict(g=dict(NUM_QP=2, NUM_MR=2, PMTU_RUNTIME=1, IPV6_EN=0, READ_DEPTH=16), host='cx6', loss=0.03),
    'rd8_cx6':   dict(g=dict(NUM_QP=2, NUM_MR=2, PMTU_RUNTIME=1, IPV6_EN=0, READ_DEPTH=8), host='cx6', loss=0.03),
    'rd1_cx6':   dict(g=dict(NUM_QP=2, NUM_MR=2, PMTU_RUNTIME=1, IPV6_EN=0, READ_DEPTH=1), host='cx6', loss=0.05),
    # re-issue only after a timeout (responder idle), in-order acceptance
    'rd16_timeout': dict(g=dict(NUM_QP=2, NUM_MR=2, PMTU_RUNTIME=1, IPV6_EN=0, READ_DEPTH=16), host='timeout', loss=0.02),
}


class Rd:
    def __init__(self, psn, npk, va, L, laddr):
        self.psn, self.npk, self.va, self.L, self.laddr = psn, npk, va, L, laddr
        self.got = set()
        self.rs_tx = None          # model.tx index where the responses of our last re-issue start

    def complete(self):
        return len(self.got) == self.npk

    def first_missing(self):
        for i in range(self.npk):
            if i not in self.got:
                return i
        return None


def run(name, nreads, seed):
    C = CONFIGS[name]
    g = C['g']
    D = g['READ_DEPTH']
    rng = random.Random(seed)
    d = os.path.join(S.BUILD, 'rdre_' + name)
    os.makedirs(d, exist_ok=True)
    NQ, NM = g['NUM_QP'], g['NUM_MR']
    qps = {q: dict(epsn=rng.choice([rng.getrandbits(24), M24 - rng.randrange(40)]), pmtu=rng.randint(8, 12), ipv6=0,
                   dmac=rng.getrandbits(48), dip=rng.getrandbits(32), dqpn=rng.getrandbits(24),
                   sport=rng.getrandbits(16)) for q in range(NQ)}
    mrs = {i: dict(valid=1, rkey=(rng.getrandbits(32) & ~(NM - 1)) | i, va=rng.getrandbits(48) & ~63,
                   len=1 << 20, laddr=rng.getrandbits(40) & ~63, acc=3) for i in range(NM)}
    with open(os.path.join(d, 'cfg_qp.txt'), 'w') as f:
        for q, c in qps.items():
            f.write('%x 1 %x %x %x %x %x %x %x\n' % (q, c['epsn'], c['pmtu'], c['ipv6'], c['dmac'],
                                                   c['dip'], c['dqpn'], c['sport']))
    with open(os.path.join(d, 'cfg_mr.txt'), 'w') as f:
        for i, m in mrs.items():
            f.write('%x 1 %x %x %x %x %x\n' % (i, m['rkey'], m['va'], m['len'], m['laddr'], m['acc']))
    model = T.Model(qps, mrs, g, 1)
    by_dqpn = {c['dqpn']: q for q, c in qps.items()}
    frames = []                    # (frame, sync)
    host = {q: dict(psn=c['epsn'], out=[], issued=0, done=0) for q, c in qps.items()}
    st = dict(lost=0, partial=0, whole=0, orphan=0, timeout=0, peak=0, oldcnt_peak=0)

    def emit(q, kw, psn, sync):
        c = qps[q]
        fr = R.build_frame(R.OP['READ_REQ'], b'', dqpn=T.QPN_BASE + q, psn=psn, dmac=T.MY_MAC, smac=c['dmac'],
                           sport=c['sport'], sip=c['dip'], dip=T.MY_IP4, **kw)
        frames.append((fr, sync))
        model.frame(R.parse_frame(fr), True, 0)

    def new_read(q, sync):
        h = host[q]
        pm = model.pmtu(q)
        L = rng.choice([rng.randint(1, pm), rng.randint(pm + 1, 4 * pm), rng.randint(2 * pm, 8 * pm)])
        m = mrs[rng.randrange(NM)]
        off = rng.randrange(0, (m['len'] - L) // 64) * 64
        npk = max(1, -(-L // pm))
        # the requester never has more than READ_DEPTH READs outstanding: the model's
        # depth check sees the requester's count (the RTL must not NAK either)
        model.st[q]['rd'] = len(h['out'])
        assert len(h['out']) < D
        r = Rd(h['psn'], npk, m['va'] + off, L, m['laddr'] + off)
        r.kw = dict(va=m['va'] + off, rkey=m['rkey'], dmalen=L)
        h['out'].append(r)
        emit(q, r.kw, h['psn'], sync)
        h['psn'] = (h['psn'] + npk) & M24
        h['issued'] += 1
        st['peak'] = max(st['peak'], len(h['out']))

    def reissue(q, r, k, sync):
        pm = model.pmtu(q)
        r.rs_tx = len(model.tx)
        kw = dict(va=r.kw['va'] + k * pm, rkey=r.kw['rkey'], dmalen=r.L - k * pm, ackreq=1)
        st['partial' if k else 'whole'] += 1
        emit(q, kw, (r.psn + k) & M24, sync)

    def complete_in_order(q, sync):
        h = host[q]
        while h['out'] and h['out'][0].complete():
            h['out'].pop(0)
            h['done'] += 1
            if h['issued'] < nreads:
                new_read(q, sync)

    # start: READ_DEPTH READs per QP
    for q in range(NQ):
        for _ in range(min(D, nreads)):
            new_read(q, 0)
    pos = 0
    while True:
        while pos < len(model.tx):
            e = model.tx[pos]
            pos += 1
            q = by_dqpn[e['dqpn']]
            if e['opcode'] == 0x11:
                st['bad_ack'] = st.get('bad_ack', 0) + 1
                continue
            if rng.random() < C['loss']:
                st['lost'] += 1
                continue
            h = host[q]
            pm = model.pmtu(q)
            rr = [r for r in h['out'] if ((e['psn'] - r.psn) & M24) < r.npk]
            if not rr:
                st['orphan'] += 1            # response to a READ already complete
                continue
            r = rr[0]
            k = (e['psn'] - r.psn) & M24
            ln = min(pm, r.L - k * pm)
            exp = bytes(T.pat(r.laddr + k * pm + j) for j in range(ln))
            if e['payload'] != exp:
                st['data_err'] = st.get('data_err', 0) + 1
            o = h['out'][0]
            inorder = (r is o and k == o.first_missing())
            if C['host'] == 'timeout' and not inorder:
                continue                     # in-order acceptance only
            r.got.add(k)
            sync = 2 + pos
            if C['host'] == 'cx6' and not o.complete():
                fm = o.first_missing()
                behind = (r is not o) or (k > fm)
                fresh = o.rs_tx is None or pos - 1 >= o.rs_tx
                if behind and fresh:
                    # gap: re-issue the oldest incomplete READ from the first missing packet,
                    # and some of the later outstanding READs whole, a few us later
                    dl = min(sync + rng.randint(0, 2), 2 + len(model.tx))   # only frames already due
                    reissue(q, o, fm, dl)
                    later = h['out'][1:]
                    for x in later[:rng.randint(0, min(5, len(later)))]:
                        reissue(q, x, 0, dl)
            complete_in_order(q, sync)
        # nothing more on the wire: a timeout re-issues what is still missing
        pend = [q for q in range(NQ) if host[q]['out']]
        if not pend:
            break
        st['timeout'] += 1
        assert st['timeout'] < 100000
        for q in pend:
            h = host[q]
            o = h['out'][0]
            reissue(q, o, o.first_missing(), 1)
            for x in h['out'][1:]:
                if C['host'] == 'timeout' or not x.complete():
                    if C['host'] == 'timeout':
                        x.got = set()
                    reissue(q, x, 0, 1)
    with open(os.path.join(d, 'rx.txt'), 'w') as f:
        for fr, sy in frames:
            for last, n, ch in R.frame_to_beats(fr):
                f.write(R.beat_line(last, n, ch) + ' 0 %d\n' % sy)
    plus = ['dir=' + d, 'seed=%d' % seed, 'gap=%s' % os.environ.get('GAP', '10'),
            'bp=%s' % os.environ.get('BP', '20'), 'read_cont=1']
    out, log = S.xsim(d, 'tb_core_resp', g, T.FILES, plus)
    nstall = log.count('TB_SYNC_STALL')
    out = '\n'.join(l for l in log.splitlines() if l.startswith('TB_') and 'SYNC_STALL' not in l)
    print('[%s] %d requests: %s' % (name, len(frames), out.replace('\n', ' | ')))
    if 'TB_DONE' not in out:
        return 1
    bad = 0
    if nstall:
        print('  the engine stopped answering: %d requests released after a stall' % nstall)
        bad += 1
    got = [fr for fr, _ in R.read_beats(os.path.join(d, 'tx.txt'))]
    if len(got) != len(model.tx):
        print('  TX: %d frames, expected %d' % (len(got), len(model.tx)))
        bad += 1
    nnak = 0
    for i, (fr, e) in enumerate(zip(got, model.tx)):
        p = R.parse_frame(fr)
        if p.get('opcode') == 0x11:
            nnak += 1
            if nnak < 4:
                print('  TX frame %d: ACK/NAK syndrome 0x%02x psn %06x' % (i, p.get('syndrome', 0), p.get('psn', 0)))
        errs = [k for k, v in e.items() if v is not None and p.get(k) != v]
        if not p['icrc_ok'] or not p['frame_len_ok'] or not p['ip_csum_ok']:
            errs.append('icrc/len/csum')
        if errs:
            bad += 1
            if bad < 6:
                print('  TX frame %d: %s got %s exp %s' % (
                    i, errs, {k: p.get(k) for k in errs if k in p and k != 'payload'},
                    {k: e.get(k) for k in errs if k in e and k != 'payload'}))
    errs = [l.split() for l in open(os.path.join(d, 'err.txt')) if l.strip()]
    if errs or nnak or st.get('bad_ack') or st.get('data_err'):
        print('  QP errors %s, NAKs sent %d, model ACKs %d, data errors %d' % (
            errs, nnak, st.get('bad_ack', 0), st.get('data_err', 0)))
        bad += 1
    m = re.search(r'cont=(\d+)', out)
    if not m or int(m.group(1)) != model.n_cont:
        print('  continuations: got %s, expected %d' % (m.group(1) if m else '-', model.n_cont))
        bad += 1
    done = sum(h['done'] for h in host.values())
    if done != nreads * NQ:
        print('  READs completed at the requester: %d of %d' % (done, nreads * NQ))
        bad += 1
    print('  %d READs completed, %d response packets lost, re-issues %d partial / %d whole (%d after a timeout), '
          '%d orphan responses, %d continuations, peak outstanding %d of %d: %d errors' % (
              done, st['lost'], st['partial'], st['whole'], st['timeout'], st['orphan'], model.n_cont,
              st['peak'], D, bad))
    return bad


def main():
    args = sys.argv[1:]
    nreads = int(args[0]) if len(args) > 0 else 200
    seed = int(args[1]) if len(args) > 1 else 1
    names = args[2:] or list(CONFIGS)
    fails = sum(run(n, nreads, seed) for n in names)
    print('READ RE-ISSUE TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
