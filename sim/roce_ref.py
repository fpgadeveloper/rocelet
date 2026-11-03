#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# roce_ref.py - RoCE v2 reference model for the rocelet testbenches:
#   * ICRC (hand-written from IBTA Vol 1 sec 7.8.1 + Annex A17, cross-checked
#     against scapy.contrib.roce for IPv4 and against Linux rxe_icrc.c rules)
#   * RoCE v2 frame builder (Ethernet / IPv4 or IPv6 / UDP 4791 / BTH / RETH /
#     AETH / ImmDt / payload / pad / ICRC), no FCS (the CMAC adds/strips it)
#   * beat-file I/O shared with the xsim testbenches: one line per 512-bit beat,
#     "<last> <nbytes> <data hex, byte 63 first ... byte 0 last>"
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import random
import struct
import zlib

ROCE_PORT = 4791

# --- BTH opcodes (RC) ---
OP = dict(
    SEND_FIRST=0x00, SEND_MIDDLE=0x01, SEND_LAST=0x02, SEND_LAST_IMM=0x03,
    SEND_ONLY=0x04, SEND_ONLY_IMM=0x05,
    WRITE_FIRST=0x06, WRITE_MIDDLE=0x07, WRITE_LAST=0x08, WRITE_LAST_IMM=0x09,
    WRITE_ONLY=0x0A, WRITE_ONLY_IMM=0x0B,
    READ_REQ=0x0C, READ_RESP_FIRST=0x0D, READ_RESP_MIDDLE=0x0E,
    READ_RESP_LAST=0x0F, READ_RESP_ONLY=0x10, ACK=0x11,
)
OPNAME = {v: k for k, v in OP.items()}
HAS_RETH = {OP['WRITE_FIRST'], OP['WRITE_ONLY'], OP['WRITE_ONLY_IMM'], OP['READ_REQ']}
HAS_IMM = {OP['SEND_LAST_IMM'], OP['SEND_ONLY_IMM'], OP['WRITE_LAST_IMM'], OP['WRITE_ONLY_IMM']}
HAS_AETH = {OP['READ_RESP_FIRST'], OP['READ_RESP_LAST'], OP['READ_RESP_ONLY'], OP['ACK']}


def crc32_bitwise(data, reg=0xFFFFFFFF):
    """Reflected CRC-32 register update, no final inversion (independent of zlib)."""
    for b in data:
        reg ^= b
        for _ in range(8):
            reg = (reg >> 1) ^ (0xEDB88320 if reg & 1 else 0)
    return reg


def icrc_coverage(frame, off=14):
    """Bytes covered by the ICRC (frame = Ethernet frame without ICRC/FCS, IP
    header at byte off), variant fields set to all-ones, preceded by the 8-byte
    all-ones pseudo LRH."""
    et = struct.unpack('!H', frame[off - 2:off])[0]
    f = bytearray(frame[off:])
    if et == 0x0800:
        ihl = (f[0] & 0xF) * 4
        f[1] = 0xFF                    # ToS (DSCP + ECN)
        f[8] = 0xFF                    # TTL
        f[10:12] = b'\xff\xff'         # header checksum
        u = ihl
    elif et == 0x86DD:
        f[0] |= 0x0F                   # traffic class high nibble
        f[1:4] = b'\xff\xff\xff'       # traffic class low nibble + flow label
        f[7] = 0xFF                    # hop limit
        u = 40
    else:
        raise ValueError('not IP')
    f[u + 6:u + 8] = b'\xff\xff'       # UDP checksum
    f[u + 8 + 4] = 0xFF                # BTH resv8a (FECN, BECN, resv6)
    return b'\xff' * 8 + bytes(f)


def icrc_value(frame_wo_icrc, off=14):
    """ICRC as a 32-bit value (the inverted CRC register)."""
    return zlib.crc32(icrc_coverage(frame_wo_icrc, off)) & 0xFFFFFFFF


def icrc_bytes(frame_wo_icrc, off=14):
    """ICRC as transmitted: LSB byte first (like the Ethernet FCS)."""
    return struct.pack('<I', icrc_value(frame_wo_icrc, off))


def icrc_ok(frame, off=14):
    """Check a received frame (ICRC = last 4 bytes, no padding)."""
    return icrc_bytes(frame[:-4], off) == frame[-4:]


def add_l2(frame, extra):
    """Insert extra L2 bytes before the EtherType (e.g. b'\\x81\\x00' + TCI for a VLAN
    tag). The IP header then starts at 14 + len(extra); the ICRC is unchanged."""
    return frame[:12] + extra + frame[12:]


def residue(frame):
    """CRC register after the masked coverage INCLUDING the ICRC (good -> 0xDEBB20E3)."""
    cov = icrc_coverage(frame[:-4]) + frame[-4:]
    return crc32_bitwise(cov)


def ip4_checksum(hdr):
    s = 0
    for i in range(0, len(hdr), 2):
        s += (hdr[i] << 8) | hdr[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def build_frame(opcode, payload=b'', ipv6=False, dmac=0x020000000002, smac=0x020000000001,
                sip=0xC0A80201, dip=0xC0A80202, sip6=None, dip6=None, sport=0xC000,
                tos=0, ttl=64, ipid=0, flowlabel=0, hoplim=64, tclass=0,
                pkey=0xFFFF, dqpn=0x11, psn=0, ackreq=0, se=0, migreq=0, fecn=0, becn=0,
                va=0, rkey=0, dmalen=0, imm=0, syndrome=0, msn=0, udp_csum=0,
                with_icrc=True, pad_payload=True):
    """Build a RoCE v2 frame (bytes, no FCS)."""
    padcnt = (-len(payload)) % 4 if pad_payload else 0
    op5 = opcode & 0x1F if opcode < 0x40 else opcode
    bth = struct.pack('!BBHB', opcode, (se << 7) | (migreq << 6) | (padcnt << 4), pkey,
                      (fecn << 7) | (becn << 6))
    bth += struct.pack('!I', dqpn & 0xFFFFFF)[1:]
    bth += struct.pack('!I', ((ackreq & 1) << 31) | (psn & 0xFFFFFF))
    ext = b''
    if op5 in HAS_RETH:
        ext += struct.pack('!QII', va, rkey, dmalen)
    if op5 in HAS_AETH:
        ext += struct.pack('!I', (syndrome << 24) | (msn & 0xFFFFFF))
    if op5 in HAS_IMM:
        ext += struct.pack('!I', imm)
    l4 = bth + ext + payload + b'\x00' * padcnt
    udp_len = 8 + len(l4) + 4
    udp = struct.pack('!HHHH', sport, ROCE_PORT, udp_len, udp_csum)
    if not ipv6:
        tot = 20 + udp_len
        ip = bytearray(struct.pack('!BBHHHBBH4s4s', 0x45, tos, tot, ipid, 0x4000, ttl, 17, 0,
                                   sip.to_bytes(4, 'big'), dip.to_bytes(4, 'big')))
        ip[10:12] = struct.pack('!H', ip4_checksum(ip))
        et = 0x0800
    else:
        sip6 = sip6 if sip6 is not None else (0xfe80 << 112) | sip
        dip6 = dip6 if dip6 is not None else (0xfe80 << 112) | dip
        ip = struct.pack('!IHBB', (6 << 28) | (tclass << 20) | flowlabel, udp_len, 17, hoplim)
        ip += sip6.to_bytes(16, 'big') + dip6.to_bytes(16, 'big')
        et = 0x86DD
    eth = dmac.to_bytes(6, 'big') + smac.to_bytes(6, 'big') + struct.pack('!H', et)
    frame = eth + bytes(ip) + udp + l4
    if with_icrc:
        frame += icrc_bytes(frame)
    return frame


def parse_frame(frame):
    """Parse a RoCE v2 frame (with ICRC) into a dict. Raises on non-RoCE."""
    et = struct.unpack('!H', frame[12:14])[0]
    d = {}
    if et == 0x0800:
        ihl = (frame[14] & 0xF) * 4
        d['ipv6'] = False
        d['tot_len'] = struct.unpack('!H', frame[16:18])[0]
        d['ip_csum_ok'] = ip4_checksum(frame[14:14 + ihl]) == 0
        d['sip'] = int.from_bytes(frame[26:30], 'big')
        d['dip'] = int.from_bytes(frame[30:34], 'big')
        u = 14 + ihl
        end = 14 + d['tot_len']
    elif et == 0x86DD:
        d['ipv6'] = True
        pl = struct.unpack('!H', frame[18:20])[0]
        d['sip'] = int.from_bytes(frame[22:38], 'big')
        d['dip'] = int.from_bytes(frame[38:54], 'big')
        u = 54
        end = 54 + pl
    else:
        raise ValueError('not IP')
    d['dmac'] = int.from_bytes(frame[0:6], 'big')
    d['smac'] = int.from_bytes(frame[6:12], 'big')
    sport, dport, ulen, ucs = struct.unpack('!HHHH', frame[u:u + 8])
    d.update(sport=sport, dport=dport, udp_len=ulen, udp_csum=ucs)
    b = u + 8
    op, fl, pkey = struct.unpack('!BBH', frame[b:b + 4])
    d.update(opcode=op, se=fl >> 7, padcnt=(fl >> 4) & 3, pkey=pkey,
             dqpn=int.from_bytes(frame[b + 5:b + 8], 'big'),
             ackreq=frame[b + 8] >> 7, psn=int.from_bytes(frame[b + 9:b + 12], 'big'))
    p = b + 12
    op5 = op & 0x1F if op < 0x40 else op      # RC (0x0_) and UC (0x2_) share the layout
    if op5 in HAS_RETH:
        d['va'], d['rkey'], d['dmalen'] = struct.unpack('!QII', frame[p:p + 16])
        p += 16
    if op5 in HAS_AETH:
        a = struct.unpack('!I', frame[p:p + 4])[0]
        d['syndrome'], d['msn'] = a >> 24, a & 0xFFFFFF
        p += 4
    if op5 in HAS_IMM:
        d['imm'] = struct.unpack('!I', frame[p:p + 4])[0]
        p += 4
    d['payload'] = frame[p:end - 4 - d['padcnt']]
    d['icrc_ok'] = icrc_ok(frame[:end])
    d['frame_len_ok'] = (end == len(frame))
    return d


# ---------------- beat files ----------------
def frame_to_beats(frame, W=64):
    beats = []
    for i in range(0, len(frame), W):
        chunk = frame[i:i + W]
        beats.append((i + W >= len(frame), len(chunk), chunk))
    return beats


def beat_line(last, n, chunk, W=64):
    data = bytes(chunk) + b'\x00' * (W - len(chunk))
    return '%d %d %s' % (int(last), n, data[::-1].hex())


def write_beats(path, frames, W=64, offs=None):
    """offs: optional per-frame value appended to each frame's first beat line."""
    with open(path, 'w') as f:
        for i, fr in enumerate(frames):
            for k, (last, n, ch) in enumerate(frame_to_beats(fr, W)):
                extra = ' %d' % offs[i] if offs is not None else ''
                f.write(beat_line(last, n, ch, W) + extra + '\n')


def read_beats(path):
    """Read an output beat file back into a list of frames. Lines: last n hex [extra...]."""
    frames, cur, extras = [], bytearray(), []
    with open(path) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            last, n, h = int(t[0]), int(t[1]), t[2]
            data = bytes.fromhex(h)[::-1]
            cur += data[:n]
            if last:
                frames.append((bytes(cur), t[3:]))
                cur = bytearray()
    return frames


def random_roce_frame(rng, ipv6=None, max_payload=4096):
    if ipv6 is None:
        ipv6 = rng.random() < 0.3
    op = rng.choice(list(OP.values()))
    if op in (OP['ACK'], OP['READ_REQ']):
        plen = 0
    elif rng.random() < 0.15:
        plen = rng.randint(0, 3)
    else:
        plen = rng.randint(0, max_payload)
    payload = bytes(rng.getrandbits(8) for _ in range(plen))
    kw = dict(
        dqpn=rng.getrandbits(24), psn=rng.getrandbits(24), ackreq=rng.getrandbits(1),
        se=rng.getrandbits(1), pkey=rng.choice([0xFFFF, 0x7FFF, rng.getrandbits(16)]),
        va=rng.getrandbits(64), rkey=rng.getrandbits(32), dmalen=rng.getrandbits(32),
        imm=rng.getrandbits(32), syndrome=rng.choice([0, 0x1F, 0x60, 0x63]),
        msn=rng.getrandbits(24), sport=rng.getrandbits(16), ipid=rng.getrandbits(16),
        dmac=rng.getrandbits(48), smac=rng.getrandbits(48),
        sip=rng.getrandbits(32), dip=rng.getrandbits(32),
        tos=rng.getrandbits(8), ttl=rng.getrandbits(8), fecn=rng.getrandbits(1),
        becn=rng.getrandbits(1), flowlabel=rng.getrandbits(20), tclass=rng.getrandbits(8),
        hoplim=rng.getrandbits(8),
    )
    if ipv6:
        kw['sip6'] = rng.getrandbits(128)
        kw['dip6'] = rng.getrandbits(128)
    return build_frame(op, payload, ipv6=ipv6, **kw)


def mutate_variant_fields(frame, rng):
    """Change only ICRC-masked fields (frame stays ICRC-valid): ToS/ECN, TTL, IP
    checksum, UDP checksum, BTH FECN/BECN; IPv6 TC, flow label, hop limit."""
    f = bytearray(frame)
    et = struct.unpack('!H', f[12:14])[0]
    if et == 0x0800:
        f[15] = rng.getrandbits(8)
        f[22] = rng.getrandbits(8)
        f[24:26] = struct.pack('!H', rng.getrandbits(16))
        u = 34
    else:
        f[14] = (f[14] & 0xF0) | rng.getrandbits(4)
        f[15:18] = bytes(rng.getrandbits(8) for _ in range(3))
        f[21] = rng.getrandbits(8)
        u = 54
    f[u + 6:u + 8] = struct.pack('!H', rng.getrandbits(16))
    f[u + 12] = rng.getrandbits(8)
    return bytes(f)


# golden vectors of the research study (scapy + an independent zlib model of IBTA A17, 2026-10-20)
GOLDEN = [
    bytes.fromhex('0c42a1000001000a350621a008004502004c000040004011914bc0a81402c0a81401c12312b700380000'
                  '0a00ffff000001238000001000000000000010001234567800000010000102030405060708090a0b0c0d0e0f'
                  'a94b580d'),
    bytes.fromhex('0c42a1000001000a350621a00800450200300000400040119167c0a81402c0a81401c12312b7001c0000'
                  '1100ffff00000123800000101f00000105b80dfb'),
]


def selftest():
    """Cross-check the hand-written ICRC against scapy (IPv4) and the residue."""
    for g in GOLDEN:
        assert icrc_ok(g) and residue(g) == 0xDEBB20E3
    from scapy.all import Ether, IP, UDP, Raw  # noqa
    from scapy.contrib.roce import BTH
    rng = random.Random(1)
    n = 0
    for i in range(400):
        fr = random_roce_frame(rng, ipv6=False)
        assert icrc_ok(fr)
        assert residue(fr) == 0xDEBB20E3, hex(residue(fr))
        # scapy rebuild of the same frame with icrc=None (scapy computes it)
        bth = BTH(fr[42:54] + b'\0\0\0\0')
        bth.remove_payload()
        bth.icrc = None
        built = bytes(Ether(fr[:14]) / IP(fr[14:34]) / UDP(fr[34:42]) / bth / Raw(fr[54:-4]))
        assert built == fr, (i, built[-4:].hex(), fr[-4:].hex())
        # invariance under masked-field mutation
        m = mutate_variant_fields(fr, rng)
        assert icrc_ok(m)
        n += 1
    for i in range(200):
        fr = random_roce_frame(rng, ipv6=True)
        assert icrc_ok(fr) and residue(fr) == 0xDEBB20E3
        assert icrc_ok(mutate_variant_fields(fr, rng))
    print('roce_ref selftest: %d IPv4 frames match scapy, 200 IPv6 frames, residue ok' % n)


if __name__ == '__main__':
    selftest()
