#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""roce_check.py - independent referee for RoCE v2 framing and ICRC.

Reads a packet capture (pcap / pcapng from tcpdump or dumpcap) or a text hex
dump of frames (e.g. the FPGA's RX capture buffer printed on its console), and
checks every RoCE v2 frame:

  * Ethernet / 802.1Q, IPv4 (IHL, total length, DF, fragments, TTL, DSCP/ECN,
    header checksum), UDP (port, length, checksum = 0, source port constant
    per flow), BTH (opcode, SE, MigReq, PadCnt, TVer, P_Key, reserved bits,
    DestQP, AckReq, PSN), RETH / AETH / ImmDt / IETH, payload length rules
    (FIRST/MIDDLE = PMTU, LAST 1..PMTU, ONLY 0..PMTU).
  * ICRC, computed twice: with scapy.contrib.roce (BTH.compute_icrc) and with an
    independent zlib model of the IBTA A17 masks; both must agree with the
    frame. (scapy 2.5's ICRC is IPv4 only, as is rocelet v1.)
  * Per flow (src IP, dst IP, DestQP): PSN sequence (gaps, go-back-N
    retransmissions), opcode sequence, AckReq spacing, ACK/NAK syndromes and
    MSN, READ responses.
  * Optionally the rocelet payload pattern (--seed): WRITE payload must be
    pattern(VA of the packet), SEND payload self-describing.

Exit status: 0 = no error in the checked frames, 1 = errors, 2 = usage /
nothing to check.

Examples:
  roce_check.py cap.pcap --src 192.168.20.2              # FPGA packets only
  roce_check.py cap.pcap --src 192.168.20.2 --pmtu 4096 --seed 0x5eed1234 -v
  roce_check.py --hex fpga_cap.txt                        # FPGA-captured host frames
  roce_check.py cap.pcap --expect-bad-ipcsum              # capture-mode frames (see README)

Note: a host's RDMA NIC consumes RoCE v2 frames in hardware, so `tcpdump -i
<netdev>` normally sees none of them (many NICs offer no RoCE sniffer). See README
for the capture modes used in the rocelet interop tests.
"""
import argparse
import collections
import re
import struct
import sys
import zlib

try:
    from scapy.all import rdpcap, Ether, IP, UDP, Raw, bind_layers  # noqa: F401
    from scapy.contrib.roce import BTH
    HAVE_SCAPY = True
except Exception:  # pragma: no cover
    HAVE_SCAPY = False

ROCE_PORT = 4791

# opcode -> (name, ext headers, payload rule) ; payload rule: F = PMTU exactly,
# L = 1..PMTU, O = 0..PMTU, N = none
OPS = {
    0x00: ("SEND_FIRST", "", "F"), 0x01: ("SEND_MIDDLE", "", "F"), 0x02: ("SEND_LAST", "", "L"),
    0x03: ("SEND_LAST_IMM", "I", "L"), 0x04: ("SEND_ONLY", "", "O"), 0x05: ("SEND_ONLY_IMM", "I", "O"),
    0x06: ("WRITE_FIRST", "R", "F"), 0x07: ("WRITE_MIDDLE", "", "F"), 0x08: ("WRITE_LAST", "", "L"),
    0x09: ("WRITE_LAST_IMM", "I", "L"), 0x0A: ("WRITE_ONLY", "R", "O"),
    0x0B: ("WRITE_ONLY_IMM", "RI", "O"), 0x0C: ("READ_REQ", "R", "N"),
    0x0D: ("READ_RESP_FIRST", "A", "F"), 0x0E: ("READ_RESP_MIDDLE", "", "F"),
    0x0F: ("READ_RESP_LAST", "A", "L"), 0x10: ("READ_RESP_ONLY", "A", "O"),
    0x11: ("ACK", "A", "N"), 0x12: ("ATOMIC_ACK", "AX", "N"), 0x13: ("CMP_SWAP", "T", "N"),
    0x14: ("FETCH_ADD", "T", "N"), 0x16: ("SEND_LAST_INV", "V", "L"), 0x17: ("SEND_ONLY_INV", "V", "O"),
}
EXT_LEN = {"R": 16, "A": 4, "I": 4, "V": 4, "X": 8, "T": 28}
# message position: F first, M middle, L last, O only
POS = {0x00: "F", 0x01: "M", 0x02: "L", 0x03: "L", 0x04: "O", 0x05: "O", 0x06: "F", 0x07: "M",
       0x08: "L", 0x09: "L", 0x0A: "O", 0x0B: "O", 0x16: "L", 0x17: "O"}
FAMILY = {0x00: "S", 0x01: "S", 0x02: "S", 0x03: "S", 0x04: "S", 0x05: "S", 0x16: "S", 0x17: "S",
          0x06: "W", 0x07: "W", 0x08: "W", 0x09: "W", 0x0A: "W", 0x0B: "W"}
NAK_CODES = {0: "PSN sequence error", 1: "invalid request", 2: "remote access error",
             3: "remote operational error", 4: "invalid RD request"}

PAT_K = [0x0000000000000000, 0x9E3779B97F4A7C15, 0x3C6EF372FE94F82A, 0xDAA66D2C7DDF743F,
         0x78DDE6E5FD29F054, 0x1715609F7C746C69, 0xB54CDA58FBBEE87E, 0x538454127B096493]
M64 = (1 << 64) - 1


def pat_beat(a, seed):
    x = a ^ (((seed & 0xFFFFFFFF) << 32) | (~seed & 0xFFFFFFFF))
    return b"".join(struct.pack("<Q", w) for w in [a & M64] + [(x + PAT_K[i]) & M64 for i in range(1, 8)])


def pattern(addr, length, seed):
    out = bytearray()
    off = 0
    while off < length:
        out += pat_beat(addr + off, seed)[: min(64, length - off)]
        off += 64
    return bytes(out)


def ip_checksum(hdr):
    s = 0
    for i in range(0, len(hdr), 2):
        s += (hdr[i] << 8) | hdr[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def icrc_model(ip_udp_bth_rest):
    """IBTA A17 ICRC over IPv4|UDP|BTH|ext|payload|pad (no ICRC): 8 x 0xFF
    pseudo-LRH, IPv4 ToS, TTL, checksum, UDP checksum and BTH byte 4 masked to
    ones; zlib CRC-32; transmitted little endian."""
    b = bytearray(ip_udp_bth_rest)
    b[1] = 0xFF          # ToS (DSCP + ECN)
    b[8] = 0xFF          # TTL
    b[10] = b[11] = 0xFF  # header checksum
    b[26] = b[27] = 0xFF  # UDP checksum (20 + 6)
    b[32] = 0xFF         # BTH byte 4: FECN/BECN/resv6 (20 + 8 + 4)
    crc = zlib.crc32(b"\xff" * 8 + bytes(b)) & 0xFFFFFFFF
    return struct.pack("<I", crc)


def icrc_scapy(frame, port):
    """ICRC via scapy.contrib.roce on the dissected frame; None if unavailable."""
    if not HAVE_SCAPY:
        return None
    if port != ROCE_PORT:
        bind_layers(UDP, BTH, dport=port)
    p = Ether(frame)
    if BTH not in p:
        return None
    return p[BTH].compute_icrc(None)


def psn_diff(a, b):
    """signed 24-bit a - b"""
    d = (a - b) & 0xFFFFFF
    return d - 0x1000000 if d & 0x800000 else d


class Flow:
    def __init__(self, key):
        self.key = key
        self.n = 0
        self.ops = collections.Counter()
        self.first_psn = None
        self.next_psn = None
        self.max_psn = None
        self.gaps = 0
        self.retx = 0
        self.retx_events = []
        self.pos = None          # last request message position for opcode sequencing
        self.fam = None
        self.seq_errors = 0
        self.ackreq = 0
        self.ackreq_last_of_msg = 0
        self.ackreq_gaps = collections.Counter()
        self.since_ackreq = 0
        self.sports = set()
        self.migreq = collections.Counter()
        self.msn_last = None
        self.msn_back = 0
        self.naks = collections.Counter()
        self.rnr = 0
        self.va = None
        self.pat_bad = 0
        self.pat_ok = 0
        self.send_next = None
        self.last_retx_idx = None
        self.prev_next = None
        self.resent = 0


def parse_hex_dump(text):
    """Frames from a text dump. Accepted: one frame per line of hex; or blocks
    started by a line containing 'CAPF' (optionally 'len=N'), made of lines
    with an optional 'offset:' prefix, ended by 'CAPE', a blank line or the
    next CAPF. Returns [(bytes, declared_len_or_None)]."""
    frames = []
    cur, cur_len, in_block = None, None, False
    hexre = re.compile(r"^[0-9a-fA-F\s]+$")

    def flush():
        nonlocal cur, cur_len, in_block
        if cur:
            frames.append((bytes(cur), cur_len))
        cur, cur_len, in_block = None, None, False

    for raw in text.splitlines():
        line = raw.strip()
        if "CAPF" in line:
            flush()
            m = re.search(r"len=(\d+|0x[0-9a-fA-F]+)", line)
            cur, cur_len, in_block = bytearray(), int(m.group(1), 0) if m else None, True
            rest = line.split("CAPF", 1)[1]
            rest = re.sub(r"len=\S+", "", rest).strip()
            if rest and hexre.match(rest):
                cur += bytes.fromhex(rest.replace(" ", ""))
            continue
        if "CAPE" in line:
            flush()
            continue
        if not line:
            if in_block:
                flush()
            continue
        m = re.match(r"^(?:0x)?[0-9a-fA-F]+:\s*(.*)$", line)
        body = m.group(1) if m else line
        body = body.split("|")[0].strip()
        if not hexre.match(body):
            continue
        data = bytes.fromhex(body.replace(" ", "")) if len(body.replace(" ", "")) % 2 == 0 else None
        if data is None:
            continue
        if in_block:
            cur += data
        else:
            frames.append((data, None))
    flush()
    return frames


def read_frames(args):
    if args.hex:
        with open(args.hex) as f:
            return parse_hex_dump(f.read())
    if not HAVE_SCAPY:
        sys.exit("scapy is required to read pcap files (apt install python3-scapy)")
    return [(bytes(p), None) for p in rdpcap(args.pcap)]


def check_frame(fr, idx, args, flows, stats, out):
    """Check one frame. Returns list of (severity, message)."""
    issues = []
    frame, declared = fr
    if declared is not None and declared > len(frame):
        issues.append(("note", "truncated capture: %d of %d bytes (ICRC not checkable)" % (len(frame), declared)))
    if len(frame) < 14:
        return None, issues
    eth_type = struct.unpack("!H", frame[12:14])[0]
    off = 14
    vlan = None
    if eth_type == 0x8100:
        tci, eth_type = struct.unpack("!HH", frame[14:18])
        vlan = (tci >> 13, tci & 0xFFF)
        off = 18
    if eth_type != 0x0800 or len(frame) < off + 20:
        return None, issues
    ip = frame[off:off + 20]
    ver_ihl, tos, totlen, ident, flags_frag, ttl, proto, csum = struct.unpack("!BBHHHBBH", ip[:12])
    if proto != 17 or len(frame) < off + 28:
        return None, issues
    ihl = (ver_ihl & 0xF) * 4
    udp_off = off + ihl
    sport, dport, ulen, ucsum = struct.unpack("!HHHH", frame[udp_off:udp_off + 8])
    if dport != args.port:
        return None, issues
    src = ".".join(str(b) for b in ip[12:16])
    dst = ".".join(str(b) for b in ip[16:20])
    if args.src and src not in args.src:
        return None, issues
    if args.dst and dst not in args.dst:
        return None, issues
    stats["roce"] += 1
    err = lambda m: issues.append(("ERROR", m))   # noqa: E731
    warn = lambda m: issues.append(("warn", m))   # noqa: E731

    if vlan is not None:
        warn("802.1Q tag: PCP %d VID %d (some NICs add a VID-0 priority tag, e.g. with DCB and >1 TC)" % vlan)
    # ---- IPv4
    if ver_ihl != 0x45:
        err("IPv4 version/IHL 0x%02x (must be 0x45, no options)" % ver_ihl)
    if flags_frag != 0x4000:
        (err if (flags_frag & 0x3FFF) else warn)("IPv4 flags/fragment 0x%04x (expect DF=1, MF=0, offset 0 = 0x4000)" % flags_frag)
    ecn = tos & 3
    if ecn == 3:
        warn("ECN = CE (11)")
    elif ecn == 1:
        warn("ECN = ECT(1) (01): never sent by RoCE v2 senders")
    if ttl == 0:
        err("TTL 0")
    ipc = ip_checksum(ip[:10] + b"\0\0" + ip[12:20])
    if ipc != csum:
        if args.expect_bad_ipcsum:
            stats["bad_ipcsum_expected"] += 1
        else:
            err("IPv4 header checksum 0x%04x, expected 0x%04x" % (csum, ipc))
    ip_end = off + totlen
    pad_eth = len(frame) - ip_end
    if pad_eth < 0:
        if declared is None or declared <= len(frame):
            err("IPv4 total length %d exceeds the frame (%d bytes after the Ethernet header)" % (totlen, len(frame) - off))
        return None, issues
    if pad_eth > 0 and len(frame) > 60:
        if pad_eth == 4 and not args.fcs:
            warn("4 bytes after the IP datagram: FCS included in the capture? (use --fcs)")
        elif not args.fcs or pad_eth != 4:
            err("%d unexpected bytes after the IP datagram" % pad_eth)
    # ---- UDP
    if ulen != totlen - ihl:
        err("UDP length %d, expected IPv4 total length - IHL = %d" % (ulen, totlen - ihl))
    if ucsum != 0:
        warn("UDP checksum 0x%04x (RoCE v2 senders transmit 0)" % ucsum)
    # ---- BTH
    bth_off = udp_off + 8
    seg = frame[off:ip_end]          # IP .. ICRC
    if len(seg) < ihl + 8 + 12 + 4:
        err("too short for BTH + ICRC")
        return None, issues
    bth = frame[bth_off:bth_off + 12]
    opcode = bth[0]
    se, mig, pad, tver = bth[1] >> 7, (bth[1] >> 6) & 1, (bth[1] >> 4) & 3, bth[1] & 0xF
    pkey = struct.unpack("!H", bth[2:4])[0]
    b4 = bth[4]
    dqpn = int.from_bytes(bth[5:8], "big")
    ackreq, resv7 = bth[8] >> 7, bth[8] & 0x7F
    psn = int.from_bytes(bth[9:12], "big")
    transport = opcode >> 5
    op = opcode & 0x1F
    name = OPS.get(op, ("?", "", "N"))[0] if transport in (0, 1) else ("CNP" if opcode in (0x80, 0x81) else "?")
    if transport == 1:
        name = "UC_" + name
    stats["opcodes"][name] += 1
    if tver != 0:
        err("BTH TVer %d" % tver)
    if pkey != 0xFFFF:
        err("BTH P_Key 0x%04x (expect 0xFFFF)" % pkey)
    if resv7 != 0:
        err("BTH Resv7 0x%02x" % resv7)
    if b4 != 0 and opcode not in (0x80, 0x81):
        warn("BTH byte 4 (FECN/BECN/resv6) = 0x%02x" % b4)
    cnp = opcode in (0x80, 0x81)
    if not cnp and (transport not in (0, 1) or op not in OPS):
        err("opcode 0x%02x not supported by rocelet (RC/UC only)" % opcode)
        return None, issues
    # ---- ext headers + payload
    _, exts, rule = ("CNP", "", "N") if cnp else OPS[op]
    p = bth_off + 12
    reth = aeth = imm = None
    for e in exts:
        n = EXT_LEN[e]
        h = frame[p:p + n]
        if e == "R":
            reth = struct.unpack("!QII", h)
        elif e == "A":
            aeth = struct.unpack("!I", h)[0]
        elif e == "I":
            imm = struct.unpack("!I", h)[0]
        p += n
    if cnp:
        p += 16
    pay_end = ip_end - 4
    paylen = pay_end - p
    if paylen < 0:
        err("frame shorter than its headers")
        return None, issues
    payload = frame[p:pay_end]
    data_len = paylen - pad
    if (paylen % 4) != 0:
        err("payload + pad (%d) is not a multiple of 4" % paylen)
    if pad and POS.get(op) in ("F", "M"):
        err("PadCnt %d on a FIRST/MIDDLE packet" % pad)
    if rule == "N" and paylen != 0:
        err("%d payload bytes on %s" % (paylen, name))
    if args.pmtu and rule in ("F", "L", "O"):
        if rule == "F" and data_len != args.pmtu:
            err("%s payload %d, must equal PMTU %d" % (name, data_len, args.pmtu))
        if rule == "L" and not (1 <= data_len <= args.pmtu):
            err("%s payload %d, must be 1..PMTU" % (name, data_len))
        if rule == "O" and data_len > args.pmtu:
            err("%s payload %d exceeds PMTU %d" % (name, data_len, args.pmtu))
    # ---- ICRC
    icrc = frame[pay_end:ip_end]
    exp_model = icrc_model(seg[:-4])
    icrc_ok = exp_model == icrc
    exp_scapy = None
    if not args.no_scapy:
        try:
            exp_scapy = icrc_scapy(frame[:ip_end], args.port)
        except Exception as ex:  # pragma: no cover
            warn("scapy ICRC failed: %s" % ex)
    if exp_scapy is not None and exp_scapy != exp_model:
        err("TOOL: scapy ICRC %s != model ICRC %s" % (exp_scapy.hex(), exp_model.hex()))
    if declared is not None and declared > len(frame):
        stats["icrc_unchecked"] += 1
    elif icrc_ok:
        stats["icrc_ok"] += 1
    else:
        stats["icrc_bad"] += 1
        err("ICRC %s, expected %s%s" % (icrc.hex(), exp_model.hex(), " (scapy agrees)" if exp_scapy == exp_model else ""))

    # ---- flow / sequence analysis
    key = (src, dst, dqpn)
    fl = flows.setdefault(key, Flow(key))
    fl.n += 1
    fl.ops[name] += 1
    fl.sports.add(sport)
    fl.migreq[mig] += 1
    if args.expect_migreq is not None and mig != args.expect_migreq:
        warn("MigReq %d (expected %d)" % (mig, args.expect_migreq))
    is_req = not cnp and (op <= 0x0C or op in (0x13, 0x14, 0x16, 0x17))
    info = ""
    if is_req:
        # next_psn: highest new PSN + 1; prev_next: PSN following the previous packet
        if fl.first_psn is None:
            fl.first_psn = psn
        elif fl.next_psn is not None:
            d = psn_diff(psn, fl.next_psn)
            if d > 0:
                fl.gaps += 1
                err("PSN gap: 0x%06x after expected 0x%06x (%d missing)" % (psn, fl.next_psn, d))
            elif d < 0:
                fl.resent += 1
                if psn != fl.prev_next:
                    fl.retx += 1
                    fl.last_retx_idx = idx
                    if len(fl.retx_events) < 20:
                        fl.retx_events.append((idx, psn, fl.next_psn))
                    issues.append(("note", "PSN 0x%06x goes back %d (go-back-N retransmission)" % (psn, -d)))
        npsn = (psn + 1) & 0xFFFFFF
        if op == 0x0C and reth:  # READ request reserves ceil(len/PMTU) PSNs
            if args.pmtu:
                npsn = (psn + max(1, -(-reth[2] // args.pmtu))) & 0xFFFFFF
        fl.prev_next = npsn
        if fl.next_psn is None or psn_diff(npsn, fl.next_psn) > 0:
            fl.next_psn = npsn
        # opcode sequence (requests only; a retransmission restarts at a message boundary or mid-message)
        pos, fam = POS.get(op), FAMILY.get(op)
        if pos and fl.last_retx_idx == idx:
            fl.pos, fl.fam = pos, fam
        elif pos:
            prev = fl.pos
            ok = (prev in (None, "L", "O") and pos in ("F", "O")) or \
                 (prev in ("F", "M") and pos in ("M", "L") and fam == fl.fam)
            if not ok and prev is not None:
                fl.seq_errors += 1
                err("opcode sequence: %s after a %s packet" % (name, {"F": "FIRST", "M": "MIDDLE", "L": "LAST", "O": "ONLY"}[prev]))
            fl.pos, fl.fam = pos, fam
        fl.since_ackreq += 1
        if ackreq:
            fl.ackreq += 1
            fl.ackreq_gaps[fl.since_ackreq] += 1
            fl.since_ackreq = 0
            if pos in ("L", "O"):
                fl.ackreq_last_of_msg += 1
        elif pos in ("L", "O") and args.ackreq_last:
            warn("no AckReq on the last packet of a message (%s)" % name)
        # payload pattern
        if args.seed is not None and data_len > 0 and fam == "W":
            if reth is not None:
                fl.va = reth[0]
            if fl.va is not None:
                exp = pattern(fl.va, data_len, args.seed)
                if payload[:data_len] == exp:
                    fl.pat_ok += 1
                else:
                    fl.pat_bad += 1
                    err("payload != pattern(VA 0x%x, seed 0x%08x)" % (fl.va, args.seed))
                fl.va += data_len
        elif args.seed is not None and data_len >= 8 and fam == "S":
            a0 = struct.unpack("<Q", payload[:8])[0]
            if payload[:data_len] == pattern(a0, data_len, args.seed):
                fl.pat_ok += 1
                if fl.send_next is not None and a0 != fl.send_next:
                    info += " send-addr 0x%x (expected 0x%x)" % (a0, fl.send_next)
                fl.send_next = a0 + data_len
            else:
                fl.pat_bad += 1
                err("SEND payload is not a self-describing pattern (seed 0x%08x)" % args.seed)
    if aeth is not None:
        syn, msn = aeth >> 24, aeth & 0xFFFFFF
        t = (syn >> 5) & 3
        if syn & 0x80:
            err("AETH reserved bit 31 set")
        if t == 0:
            info += " ACK credits 0x%02x MSN %d" % (syn & 0x1F, msn)
        elif t == 1:
            fl.rnr += 1
            info += " RNR-NAK timer %d MSN %d" % (syn & 0x1F, msn)
        elif t == 3:
            fl.naks[NAK_CODES.get(syn & 0x1F, "reserved %d" % (syn & 0x1F))] += 1
            info += " NAK %s MSN %d" % (NAK_CODES.get(syn & 0x1F, "?"), msn)
        else:
            err("AETH type 10 (reserved)")
        if fl.msn_last is not None and psn_diff(msn, fl.msn_last) < 0:
            fl.msn_back += 1
            warn("MSN went back: %d after %d" % (msn, fl.msn_last))
        fl.msn_last = msn
    if reth:
        info += " RETH va=0x%x rkey=0x%x len=%d" % reth
    if imm is not None:
        info += " imm=0x%08x" % imm
    line = "#%-5d %s -> %s qp 0x%06x %-16s psn 0x%06x%s%s pay %4d%s sport 0x%04x icrc %s%s" % (
        idx, src, dst, dqpn, name, psn, " A" if ackreq else "  ", " M" if mig else "  ", data_len,
        " pad%d" % pad if pad else "", sport, "ok" if icrc_ok else "BAD", info)
    return line, issues


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcap", nargs="?", help="pcap/pcapng file")
    ap.add_argument("--hex", help="text hex dump of frames instead of a pcap")
    ap.add_argument("--src", action="append", help="only frames from this IPv4 source (repeatable)")
    ap.add_argument("--dst", action="append", help="only frames to this IPv4 destination (repeatable)")
    ap.add_argument("--port", type=lambda s: int(s, 0), default=ROCE_PORT, help="UDP destination port (4791)")
    ap.add_argument("--pmtu", type=int, choices=[256, 512, 1024, 2048, 4096], help="check payload lengths against this PMTU")
    ap.add_argument("--seed", type=lambda s: int(s, 0), help="check the rocelet payload pattern with this seed")
    ap.add_argument("--expect-migreq", type=int, choices=[0, 1], help="warn when MigReq differs (rocelet sends 1, some NICs send 0)")
    ap.add_argument("--ackreq-last", action="store_true", help="warn when the last packet of a message has no AckReq")
    ap.add_argument("--expect-bad-ipcsum", action="store_true",
                    help="capture mode: frames carry a deliberately wrong IPv4 header checksum (masked by the ICRC)")
    ap.add_argument("--fcs", action="store_true", help="frames include the 4-byte Ethernet FCS")
    ap.add_argument("--no-scapy", action="store_true", help="skip the scapy ICRC cross-check")
    ap.add_argument("-v", "--verbose", action="count", default=0, help="-v: one line per frame, -vv: notes too")
    ap.add_argument("--max-print", type=int, default=50, help="max error lines to print (50)")
    args = ap.parse_args()
    if not args.pcap and not args.hex:
        ap.error("give a pcap file or --hex FILE")

    frames = read_frames(args)
    flows = collections.OrderedDict()
    stats = collections.Counter()
    stats["opcodes"] = collections.Counter()
    nerr = nwarn = printed = 0
    for i, fr in enumerate(frames):
        line, issues = check_frame(fr, i, args, flows, stats, sys.stdout)
        errs = [m for s, m in issues if s == "ERROR"]
        warns = [m for s, m in issues if s == "warn"]
        nerr += len(errs)
        nwarn += len(warns)
        if line and (args.verbose or errs or warns):
            if printed < args.max_print or args.verbose:
                print(line)
                for s, m in issues:
                    if s != "note" or args.verbose > 1:
                        print("        %s: %s" % (s, m))
                printed += 1
        elif not line and issues and args.verbose > 1:
            for s, m in issues:
                print("#%-5d %s: %s" % (i, s, m))

    print("\n==== roce_check: %d frames read, %d RoCE v2 frames checked (UDP dport %d%s)" % (
        len(frames), stats["roce"], args.port,
        ", src " + ",".join(args.src) if args.src else ""))
    print("ICRC: %d ok, %d BAD, %d not checkable (truncated)%s" % (
        stats["icrc_ok"], stats["icrc_bad"], stats["icrc_unchecked"],
        "" if HAVE_SCAPY and not args.no_scapy else "  [scapy cross-check OFF]"))
    if args.expect_bad_ipcsum:
        print("capture mode: %d frames with the expected bad IPv4 checksum" % stats["bad_ipcsum_expected"])
    print("opcodes: " + ", ".join("%s %d" % kv for kv in sorted(stats["opcodes"].items())))
    for key, fl in flows.items():
        src, dst, q = key
        print("flow %s -> %s qp 0x%06x: %d frames, sport %s, MigReq %s" % (
            src, dst, q, fl.n, ",".join("0x%04x" % s for s in sorted(fl.sports)),
            dict(fl.migreq)))
        if len(fl.sports) > 1:
            print("    warn: UDP source port changed within the flow")
        if fl.first_psn is not None:
            print("    requests: PSN 0x%06x .. next 0x%06x, gaps %d, retransmissions %d (%d packets resent), "
                  "opcode-sequence errors %d" % (fl.first_psn, fl.next_psn, fl.gaps, fl.retx, fl.resent, fl.seq_errors))
            for idx, psn, exp in fl.retx_events[:5]:
                print("      retransmission at frame #%d: PSN 0x%06x while next new PSN was 0x%06x" % (idx, psn, exp))
            if fl.ackreq:
                spacing = ", ".join("%d:%d" % kv for kv in sorted(fl.ackreq_gaps.items())[:8])
                print("    AckReq: %d (%d on LAST/ONLY), spacing (packets:count) %s" % (fl.ackreq, fl.ackreq_last_of_msg, spacing))
        if fl.naks or fl.rnr or fl.msn_last is not None:
            print("    responses: last MSN %s, MSN went back %d, RNR NAKs %d, NAKs %s" % (
                fl.msn_last, fl.msn_back, fl.rnr, dict(fl.naks) or "none"))
        if fl.pat_ok or fl.pat_bad:
            print("    payload pattern: %d ok, %d BAD" % (fl.pat_ok, fl.pat_bad))
    verdict = "FAIL" if nerr else ("PASS" if stats["roce"] else "NO ROCE FRAMES")
    print("result: %s (%d errors, %d warnings)" % (verdict, nerr, nwarn))
    if not stats["roce"]:
        return 2
    return 1 if nerr else 0


if __name__ == "__main__":
    sys.exit(main())
