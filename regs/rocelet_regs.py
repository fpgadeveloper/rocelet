#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# rocelet_regs.py - the single source of the rocelet AXI-Lite register map.
#
# Generates (do not edit those files by hand):
#   rtl/ctl/rocelet_regs_pkg.sv   offsets, counter indices and reset values for the RTL
#   sw/rocelet_regs.h              the same for C firmware (MicroBlaze, Linux UIO, ...)
#   docs/registers.md              the human-readable register map
# Usage: python3 regs/rocelet_regs.py            (writes the three files)
#        python3 regs/rocelet_regs.py --check    (exit 1 if any generated file is stale)
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

VERSION = (0, 2, 2)

# ---------------------------------------------------------------------------
# registers: (offset, name, access, reset, description, [fields])
# access: RO read only, RW read/write, WO write only (reads return 0),
#         W1 write: a write performs an action (reads return 0)
# fields: (msb, lsb, name, description)
# ---------------------------------------------------------------------------
REGS = [
    # ---- identification and build parameters ----
    (0x000, 'ID', 'RO', 0x52434C54, 'Identification: ASCII "RCLT".', []),
    (0x004, 'VERSION', 'RO', None, 'IP version.', [
        (23, 16, 'MAJOR', ''), (15, 8, 'MINOR', ''), (7, 0, 'PATCH', '')]),
    (0x008, 'BUILD0', 'RO', None, 'Build parameters.', [
        (8, 0, 'NUM_QP', 'number of QPs'),
        (15, 9, 'NUM_MR', 'number of memory windows'),
        (20, 16, 'READ_DEPTH', 'outstanding READs per QP'),
        (22, 21, 'RTX_MODE', '0 RING, 1 REREAD, 2 LOSSY'),
        (23, 23, 'RX_ICRC_EN', ''), (24, 24, 'IPV6_EN', ''), (25, 25, 'HSB_EN', ''),
        (26, 26, 'VLAN_EN', ''), (27, 27, 'PAUSE_EN', ''), (28, 28, 'ARP_EN', ''),
        (29, 29, 'OTHER_EN', ''), (30, 30, 'PMTU_RUNTIME', ''), (31, 31, 'COUNTERS_EN', '')]),
    (0x00C, 'BUILD1', 'RO', None, 'Build parameters.', [
        (15, 0, 'RING_KB', 'retransmit ring size in KB (0 without a ring)'),
        (24, 16, 'MAX_WR', 'outstanding work requests'),
        (28, 25, 'PMTU_LOG2', 'largest (or fixed) PMTU, log2')]),
    (0x010, 'BUILD2', 'RO', None, 'Build parameters.', [
        (23, 0, 'QPN_BASE', 'local QPN of QP index 0')]),
    (0x014, 'BUILD3', 'RO', None, 'Build parameters.', [
        (15, 0, 'RX_FIFO_DEPTH', 'RX frame FIFO, 64-byte beats'),
        (31, 16, 'TX_FIFO_DEPTH', 'TX frame FIFO, 64-byte beats')]),

    # ---- global control ----
    (0x020, 'CTRL', 'RW', None, 'Global control. Reset value 0x1AA6 + 8 x READ_CONT_DEFAULT (0x1AAE).', [
        (0, 0, 'RESET', 'hold the engine and the MAC glue in reset (register values are kept). Reset value 0'),
        (1, 1, 'RX_EN', 'accept frames from the CMAC. Reset value 1'),
        (2, 2, 'TX_EN', 'start frames towards the CMAC. Reset value 1'),
        (3, 3, 'READ_CONT', 'answer a partial duplicate READ as a continuation (MIDDLE/LAST) of the original '
                            'response instead of a new FIRST/ONLY response. Reset value READ_CONT_DEFAULT'),
        (4, 4, 'LOSS_FATAL', 'requester: a NAK-sequence or a timeout puts the QP into the error state instead '
                             'of recovering. Reset value 0'),
        (5, 5, 'VLAN_RX_STRIP', 'remove 802.1Q VID-0 priority tags on receive. Reset value 1'),
        (6, 6, 'VLAN_TX_TAG', 'tag every RoCE frame sent with VLAN_TCI. Reset value 0'),
        (7, 7, 'ARP_INT', 'answer ARP requests and ICMP echo requests internally (else they go to the '
                          'other-traffic port). Reset value 1'),
        (8, 8, 'OTHER_RX_EN', 'forward frames that are not RoCE (and not handled internally) to the '
                              'other-traffic port; 0 = drop them. Reset value 0'),
        (9, 9, 'PAUSE_RX_EN', 'honour received 802.3x PAUSE frames (no new frame starts while paused). '
                              'Reset value 1'),
        (10, 10, 'PAUSE_RX_LEVEL', 'also hold TX while the CMAC holds stat_rx_pause_req[8]. Reset value 0'),
        (11, 11, 'PAUSE_TX_EN', 'request 802.3x PAUSE (ctl_tx_pause_req[8]) from the RX FIFO level. '
                                'Reset value 1'),
        (12, 12, 'IRQ_EN', 'drive irq while a QP error is latched (STATUS.ERR). Reset value 1')]),
    (0x024, 'STATUS', 'RO', None, 'Global status.', [
        (0, 0, 'IN_RESET', 'engine held in reset'),
        (1, 1, 'MAC_ALIGNED', 'mac_rx_aligned input'),
        (2, 2, 'PAUSE_GATE', 'TX held by a received PAUSE'),
        (3, 3, 'PAUSE_REQ', 'PAUSE requested from the CMAC'),
        (4, 4, 'ERR', 'a QP error is latched (see QP_ERR_MAP, LAST_REQ_ERR, LAST_RESP_ERR); cleared by CMD.CLR_ERR'),
        (5, 5, 'LINK_UP', 'link_up input (synchronised)'),
        (6, 6, 'TIMER_HOLD', 'requester ACK timeouts held: link_up low, or LINK_GRACE running after it rose '
                             '(only once link_up has been seen high since reset)')]),
    (0x028, 'CMD', 'W1', None, 'Commands (write 1).', [
        (0, 0, 'CLR_COUNTERS', 'clear every counter and the RX FIFO maximum level'),
        (1, 1, 'CLR_ERR', 'clear the error latch (STATUS.ERR, LAST_*_ERR); QP error states are not changed')]),
    (0x030, 'MAC_LO', 'RW', 0, 'Local MAC address [31:0].', []),
    (0x034, 'MAC_HI', 'RW', 0, 'Local MAC address [47:32] in [15:0].', []),
    (0x038, 'IP4', 'RW', 0, 'Local IPv4 address.', []),
    (0x03C, 'IP_HDR', 'RW', 0x00004000, 'IP header fields of every frame sent.', [
        (7, 0, 'TOS', 'DSCP and ECN (keep ECN = 00). Reset 0'),
        (15, 8, 'TTL', 'IPv4 TTL / IPv6 hop limit. Reset 64')]),
    (0x040, 'TICK_DIV', 'RW', None, 'Clock cycles per microsecond (timer tick). Reset value CLK_MHZ.', []),
    (0x044, 'ACK_TIMEOUT', 'RW', 5000, 'Requester ACK timeout in microseconds (20 bits). Reset 5000 = 5 ms: '
                                    'covers a host that stops answering before the FPGA loses alignment '
                                    '(see docs/host-setup.md, link flaps).', []),
    (0x048, 'RNR_MIN', 'RW', 10, 'Floor of the RNR wait decoded from a received RNR NAK, microseconds (20 bits).', []),
    (0x04C, 'RNR_MAX', 'RW', 655360, 'Cap of the RNR wait decoded from a received RNR NAK, microseconds (20 bits).', []),
    (0x050, 'RNR_NAK_TIMER', 'RW', 10, 'Timer code (5 bits, IBTA table) sent in the RNR NAKs of this responder.', []),
    (0x054, 'ACKREQ_N', 'RW', 16, 'Requester: AckReq every N packets inside a message (0 = only on the last '
                                  'packet of each message).', []),
    (0x058, 'VLAN_TCI', 'RW', 0, 'TCI of the 802.1Q tag sent when CTRL.VLAN_TX_TAG = 1 ([15:13] PCP, [11:0] VID).', []),
    (0x05C, 'PAUSE_WM', 'RW', 0x00400080, 'RX FIFO levels (64-byte beats) for PAUSE requests.', [
        (15, 0, 'XOFF', 'request PAUSE at fill >= XOFF. Reset 128'),
        (31, 16, 'XON', 'release at fill <= XON. Reset 64')]),
    (0x060, 'QP_ERR_CMD', 'W1', None, 'Write a QP index: put that QP into the error state (its outstanding work '
                                       'requests complete with status FLUSHED).', [
        (7, 0, 'QP', 'QP index')]),
    (0x064, 'RETRY', 'RW', 0x00000077, 'Requester retry limits (as the IBTA retry_cnt / rnr_retry).', [
        (2, 0, 'RETRY_CNT', 'retransmissions after a timeout or NAK-sequence error before the QP fails. Reset 7'),
        (6, 4, 'RNR_RETRY', 'RNR NAKs before the QP fails; 7 = retry for ever. Reset 7')]),
    (0x068, 'PACE_RATE', 'RW', 0, 'Requester rate limit (token bucket over all QPs): credit added per clock, in '
                                  '1/256 byte (wire bytes: payload + 98). 0 = no limit. 100 Gb/s at 322.27 MHz = '
                                  '9930; 50 Gb/s = 4965.', [
        (19, 0, 'INC', '')]),
    (0x06C, 'PACE_BURST', 'RW', 16384, 'Requester rate limit: bucket size in bytes (the largest burst at line rate).', [
        (15, 0, 'BYTES', '')]),
    (0x070, 'LINK_GRACE', 'RW', 2000000, 'Requester: timer ticks (microseconds at the default TICK_DIV; 24 bits, '
                                         'max 16.7 s) after link_up rises during which the ACK timeouts stay held, '
                                         'for a link partner whose port is up before it answers. With link_up = '
                                         'aligned & no local / remote fault the grace starts at the partner\'s own '
                                         'link-up (see docs/host-setup.md, link flaps). Reset 2,000,000 = 2 s. 0 = no grace. While link_up is low the ACK '
                                         'timeouts are held anyway; an ACK that became overdue meanwhile times out at '
                                         'once when the hold ends.', [
        (23, 0, 'TICKS', '')]),

    # ---- QP configuration (staged; QP_COMMIT applies) ----
    (0x100, 'QP_INDEX', 'RW', 0, 'QP index for QP_COMMIT and QP_STATUS.', []),
    (0x104, 'QP_FLAGS', 'RW', 0, 'Staged QP flags.', [
        (0, 0, 'VALID', '1 = the QP is in use (RTS); 0 = disabled'),
        (2, 1, 'TYPE', '0 RC, 1 UC, 2 UC in HSB mode (requester only; needs HSB_EN)')]),
    (0x108, 'QP_SQ_PSN', 'RW', 0, 'Staged first PSN of the requester (send queue PSN).', []),
    (0x10C, 'QP_RQ_PSN', 'RW', 0, 'Staged expected PSN of the responder (the peer\'s first PSN).', []),
    (0x110, 'QP_PMTU', 'RW', 12, 'Staged path MTU, log2 (8 = 256 ... 12 = 4096).', []),
    (0x114, 'QP_DMAC_LO', 'RW', 0, 'Staged peer MAC [31:0].', []),
    (0x118, 'QP_DMAC_HI', 'RW', 0, 'Staged peer MAC [47:32] in [15:0].', []),
    (0x11C, 'QP_DIP0', 'RW', 0, 'Staged peer IPv4 address (IPv6: bits [31:0]).', []),
    (0x120, 'QP_DIP1', 'RW', 0, 'Staged peer IPv6 address [63:32] (IPV6_EN only).', []),
    (0x124, 'QP_DIP2', 'RW', 0, 'Staged peer IPv6 address [95:64] (IPV6_EN only).', []),
    (0x128, 'QP_DIP3', 'RW', 0, 'Staged peer IPv6 address [127:96] (IPV6_EN only).', []),
    (0x12C, 'QP_DQPN', 'RW', 0, 'Staged peer QPN [23:0].', []),
    (0x130, 'QP_UDP', 'RW', 0, 'Staged UDP ports.', [
        (15, 0, 'SPORT', 'UDP source port of the frames sent on this QP'),
        (31, 16, 'DPORT', 'UDP destination port (0 = 4791; another value only for HSB Linux-UDP receivers)')]),
    (0x134, 'QP_IPV6', 'RW', 0, 'Staged: [0] = the peer is IPv6 (IPV6_EN only).', []),
    (0x138, 'QP_COMMIT', 'W1', None, 'Any write: apply the staged configuration to QP QP_INDEX (resets all of '
                                     'its state, clears its error state). Only while the QP has no outstanding '
                                     'work requests.', []),
    (0x13C, 'QP_STATUS', 'RO', None, 'State of QP QP_INDEX.', [
        (0, 0, 'VALID', 'configured'),
        (1, 1, 'REQ_ERR', 'requester in error'),
        (2, 2, 'RESP_ERR', 'responder in error'),
        (15, 8, 'REQ_CODE', 'requester error cause: received NAK syndrome, 0xFF timeout/retry exceeded, '
                            '0xFE RNR retry exceeded, 0xFD forced by QP_ERR_CMD, 0xFC loss with LOSS_FATAL'),
        (23, 16, 'RESP_CODE', 'responder error cause: NAK syndrome sent (0x61 invalid request, 0x62 remote access)')]),

    # ---- memory windows (staged; MR_COMMIT applies) ----
    (0x140, 'MR_INDEX', 'RW', 0, 'Memory window index; the window is selected by R_Key[log2(NUM_MR)-1:0].', []),
    (0x144, 'MR_FLAGS', 'RW', 0, 'Staged window flags.', [
        (0, 0, 'VALID', ''), (1, 1, 'REMOTE_WRITE', 'allow RDMA WRITE'), (2, 2, 'REMOTE_READ', 'allow RDMA READ')]),
    (0x148, 'MR_RKEY', 'RW', 0, 'Staged R_Key (full 32-bit compare; the low bits must equal MR_INDEX).', []),
    (0x14C, 'MR_VA_LO', 'RW', 0, 'Staged remote virtual address [31:0] (64-byte aligned).', []),
    (0x150, 'MR_VA_HI', 'RW', 0, 'Staged remote virtual address [63:32].', []),
    (0x154, 'MR_LEN', 'RW', 0, 'Staged window length in bytes.', []),
    (0x158, 'MR_LADDR_LO', 'RW', 0, 'Staged local (AXI) address [31:0] (64-byte aligned).', []),
    (0x15C, 'MR_LADDR_HI', 'RW', 0, 'Staged local (AXI) address [63:32].', []),
    (0x160, 'MR_COMMIT', 'W1', None, 'Any write: apply the staged window to MR_INDEX.', []),

    (0x170, 'IP6_0', 'RW', 0, 'Local IPv6 address [31:0] (IPV6_EN only).', []),
    (0x174, 'IP6_1', 'RW', 0, 'Local IPv6 address [63:32].', []),
    (0x178, 'IP6_2', 'RW', 0, 'Local IPv6 address [95:64].', []),
    (0x17C, 'IP6_3', 'RW', 0, 'Local IPv6 address [127:96].', []),
]

# per-QP error bitmap, 8 words (256 QPs)
for i in range(8):
    REGS.append((0x180 + 4 * i, 'QP_ERR_MAP%d' % i, 'RO', None,
                 'QPs %d-%d in the error state (requester or responder), one bit per QP.' % (32 * i, 32 * i + 31), []))

REGS += [
    (0x1C0, 'RX_FIFO_LEVEL', 'RO', None, 'RX frame FIFO level, 64-byte beats.', [
        (15, 0, 'NOW', ''), (31, 16, 'MAX', 'maximum since CMD.CLR_COUNTERS')]),
    (0x1C4, 'WR_OUTSTANDING', 'RO', None, 'Work requests in flight (accepted, not yet completed).', []),
    (0x1C8, 'RING_USED', 'RO', None, 'Retransmit ring occupancy in 64-byte beats (RTX_MODE RING).', []),
    (0x1CC, 'LAST_REQ_ERR', 'RO', None, 'Last requester QP error.', [
        (7, 0, 'CODE', 'as QP_STATUS.REQ_CODE'), (15, 8, 'QP', ''), (31, 31, 'VALID', '')]),
    (0x1D0, 'LAST_RESP_ERR', 'RO', None, 'Last responder QP error.', [
        (7, 0, 'CODE', 'as QP_STATUS.RESP_CODE'), (15, 8, 'QP', ''), (31, 31, 'VALID', '')]),
    (0x1D4, 'PAUSE_STATUS', 'RO', None, 'PAUSE state.', [
        (15, 0, 'QUANTA', 'quanta of the last received PAUSE'), (16, 16, 'GATE', ''), (17, 17, 'REQ', '')]),
    (0x1D8, 'VLAN_LAST_TCI', 'RO', None, 'TCI of the last VID-0 tag removed on receive.', []),
]

# ---- counters: 32-bit, wrapping, cleared by CMD.CLR_COUNTERS ----
COUNTERS = [
    ('RX_FRAMES', 'frames received from the CMAC (each tlast)'),
    ('RX_FCS_ERR', 'frames the CMAC flagged bad (tuser), dropped'),
    ('RX_FIFO_DROP', 'frames dropped by the RX FIFO (full, oversize, reset)'),
    ('RX_ROCE', 'frames to the engine (UDP port 4791)'),
    ('RX_ARP', 'ARP frames'),
    ('RX_ICMP', 'ICMP frames to the local IP'),
    ('RX_OTHER', 'other frames forwarded to the other-traffic port'),
    ('RX_OTHER_DROP', 'other frames dropped (CTRL.OTHER_RX_EN = 0)'),
    ('RX_VLAN_STRIP', 'VID-0 tags removed'),
    ('RX_VLAN_OTHER', 'tagged frames with VID != 0 (not stripped)'),
    ('RX_ICRC_BAD', 'RoCE frames with a bad ICRC (dropped)'),
    ('RX_PARSE_DROP', 'UDP-4791 frames the parser rejected (IP, opcode, TVer, ...)'),
    ('RX_CNP', 'CNPs (opcode 0x81) received and dropped'),
    ('RX_ACK', 'ACKs received (requester)'),
    ('RX_NAK_SEQ', 'NAK PSN-sequence-error received'),
    ('RX_RNR_NAK', 'RNR NAKs received'),
    ('RX_NAK_FATAL', 'NAK invalid request / remote access / remote operational received'),
    ('RX_REQ', 'request packets executed by the responder (new PSN)'),
    ('RX_DUP', 'duplicate request packets (re-ACKed / READ re-executed)'),
    ('RX_OOS', 'out-of-sequence request packets (NAK-seq sent or suppressed)'),
    ('RX_QP_DROP', 'packets for an unknown, unconfigured or failed QP'),
    ('RX_READ', 'READ requests executed (incl. duplicates)'),
    ('RX_READ_CONT', 'duplicate READs answered as a continuation'),
    ('RX_RNR_SENT', 'RNR NAKs sent (send_rnr)'),
    ('RX_CPL', 'receive completions (SEND, WRITE with immediate)'),
    ('TX_FRAMES', 'frames sent to the CMAC'),
    ('TX_REQ', 'requester packets sent (incl. retransmissions)'),
    ('TX_ACK', 'ACKs sent'),
    ('TX_NAK', 'NAKs sent (sequence, RNR, fatal)'),
    ('TX_READ_RESP', 'READ response packets sent'),
    ('TX_ARP_ICMP', 'ARP / ICMP replies sent'),
    ('TX_OTHER', 'frames sent from the other-traffic port'),
    ('TX_UNDERRUN', 'clock cycles with tvalid low inside a frame towards the CMAC (must stay 0)'),
    ('TX_VLAN_TAG', 'frames tagged'),
    ('REQ_WR', 'work requests accepted'),
    ('REQ_WC', 'work completions emitted'),
    ('REQ_WC_ERR', 'work completions with a non-zero status'),
    ('REQ_RTX', 'retransmission episodes (NAK-sequence, timeout or RNR wait)'),
    ('REQ_TIMEOUT', 'ACK timeouts'),
    ('REQ_REX', 'work requests re-issued by go-back-N'),
    ('PAUSE_RX', 'PAUSE frames received (stat_rx_pause)'),
    ('PAUSE_TX', 'PAUSE frames sent (stat_tx_pause)'),
    ('PAUSE_GATE', 'PAUSE timer loads (received PAUSE in force)'),
    ('PAUSE_XOFF', 'PAUSE requests raised (RX FIFO above XOFF)'),
    ('RSFEC_CORR', 'RS-FEC corrected codewords'),
    ('RSFEC_UNCORR', 'RS-FEC uncorrectable codewords'),
    ('AXI_WR_ERR', 'memory writes answered with BRESP != OKAY'),
    ('AXI_RD_ERR', 'memory read beats answered with RRESP != OKAY'),
    ('WR_DATA_ERR', 'work-request payload with tlast not on the last beat of the WR length'),
    ('LINK_DOWN', 'link_up falling edges (counted once link_up has been seen high since reset)'),
]
CNT_BASE = 0x200

# 64-bit counters (read LO first: that latches HI)
COUNTERS64 = [
    ('CYCLES', 'clock cycles since CMD.CLR_COUNTERS'),
    ('RX_BYTES', 'bytes received from the CMAC'),
    ('TX_BYTES', 'bytes sent to the CMAC'),
]
CNT64_BASE = 0x300

assert len(COUNTERS) <= 64


def regs_all():
    out = list(REGS)
    for i, (n, d) in enumerate(COUNTERS):
        out.append((CNT_BASE + 4 * i, 'CNT_' + n, 'RO', None, d + ' (counter %d)' % i, []))
    for i, (n, d) in enumerate(COUNTERS64):
        out.append((CNT64_BASE + 8 * i, n + '_LO', 'RO', None, d + ' [31:0]; reading it latches _HI', []))
        out.append((CNT64_BASE + 8 * i + 4, n + '_HI', 'RO', None, d + ' [63:32] (latched)', []))
    out.sort(key=lambda r: r[0])
    offs = [r[0] for r in out]
    assert len(offs) == len(set(offs)), 'duplicate offset'
    return out


def gen_sv():
    L = ['// SPDX-License-Identifier: MIT',
         '//',
         '// rocelet_regs_pkg - AXI-Lite register map of rocelet (GENERATED by regs/rocelet_regs.py,',
         '// do not edit). Byte offsets; see docs/registers.md.',
         '//',
         '// Copyright (c) 2026 Opsero Electronic Design Inc.',
         '',
         '`resetall',
         '`timescale 1ns / 1ps',
         '`default_nettype none',
         '',
         'package rocelet_regs_pkg;',
         '',
         'localparam logic [7:0] VER_MAJOR = 8\'d%d;' % VERSION[0],
         'localparam logic [7:0] VER_MINOR = 8\'d%d;' % VERSION[1],
         'localparam logic [7:0] VER_PATCH = 8\'d%d;' % VERSION[2],
         '']
    for off, name, acc, rst, desc, fields in regs_all():
        L.append('localparam logic [15:0] R_%-18s = 16\'h%03X;   // %s' % (name, off, acc))
    L.append('')
    for off, name, acc, rst, desc, fields in REGS:
        if rst is not None and acc in ('RW',):
            L.append('localparam logic [31:0] RST_%-16s = 32\'h%08X;' % (name, rst))
    L.append('')
    L.append('localparam int NCNT = %d;' % len(COUNTERS))
    L.append('localparam logic [15:0] R_CNT_BASE = 16\'h%03X;' % CNT_BASE)
    for i, (n, d) in enumerate(COUNTERS):
        L.append('localparam int C_%-16s = %d;' % (n, i))
    L.append('')
    L.append('localparam int NCNT64 = %d;' % len(COUNTERS64))
    L.append('localparam logic [15:0] R_CNT64_BASE = 16\'h%03X;' % CNT64_BASE)
    for i, (n, d) in enumerate(COUNTERS64):
        L.append('localparam int C64_%-14s = %d;' % (n, i))
    L += ['', 'endpackage', '', '`resetall', '']
    return '\n'.join(L)


def cname(n):
    return 'ROCELET_' + n


def gen_h():
    L = ['/* SPDX-License-Identifier: MIT */',
         '/*',
         ' * rocelet_regs.h - AXI-Lite register map of the rocelet RoCE v2 engine',
         ' * (GENERATED by regs/rocelet_regs.py, do not edit). Byte offsets from the base address.',
         ' *',
         ' * Copyright (c) 2026 Opsero Electronic Design Inc.',
         ' */',
         '',
         '#ifndef ROCELET_REGS_H',
         '#define ROCELET_REGS_H',
         '',
         '#define ROCELET_ID_VALUE 0x%08XU' % 0x52434C54,
         '#define ROCELET_VERSION_MAJOR %d' % VERSION[0],
         '#define ROCELET_VERSION_MINOR %d' % VERSION[1],
         '#define ROCELET_VERSION_PATCH %d' % VERSION[2],
         '']
    for off, name, acc, rst, desc, fields in regs_all():
        L.append('#define %-36s 0x%03XU /* %s */' % (cname(name), off, acc))
        for msb, lsb, fn, fd in fields:
            w = msb - lsb + 1
            mask = ((1 << w) - 1) << lsb
            L.append('#define %-36s %d' % (cname(name + '_' + fn + '_SHIFT'), lsb))
            L.append('#define %-36s 0x%08XU' % (cname(name + '_' + fn + '_MASK'), mask))
    L.append('')
    L.append('#define ROCELET_NUM_COUNTERS %d' % len(COUNTERS))
    L.append('#define ROCELET_CNT_BASE 0x%03XU' % CNT_BASE)
    L.append('/* counter names, in index order (counter i at ROCELET_CNT_BASE + 4 * i) */')
    L.append('#define ROCELET_COUNTER_NAMES \\')
    for i, (n, d) in enumerate(COUNTERS):
        L.append('    "%s"%s' % (n.lower(), ', \\' if i < len(COUNTERS) - 1 else ''))
    L.append('')
    L.append('/* QP types (ROCELET_QP_FLAGS_TYPE) */')
    L.append('#define ROCELET_QP_TYPE_RC  0U')
    L.append('#define ROCELET_QP_TYPE_UC  1U')
    L.append('#define ROCELET_QP_TYPE_HSB 2U')
    L += ['', '#endif /* ROCELET_REGS_H */', '']
    return '\n'.join(L)


def gen_md():
    L = ['# rocelet register map',
         '',
         '*Generated by `regs/rocelet_regs.py` (version %d.%d.%d); do not edit by hand.*' % VERSION,
         '',
         'One AXI4-Lite slave (`s_axil_*`), 32-bit data, byte addresses, 64 KB window (offsets below',
         '0x400 are decoded, the rest read 0). It runs in the engine clock (`clk`, the CMAC user clock):',
         'put a clock converter in front of it when the CPU is in another domain. Writes take effect',
         'in the clock after the write response; reads are answered in a fixed number of clocks.',
         'Unused bits read 0 and should be written 0.',
         '',
         'Access: **RO** read only; **RW** read/write; **W1** a write performs an action (reads return 0).',
         '',
         '## Configuration model',
         '',
         '- Global registers (MAC, IP, timers) are written once after reset, before any QP is committed.',
         '- A QP is configured by writing the `QP_*` staging registers and then `QP_COMMIT`. The commit',
         '  writes every per-QP table of the engine for `QP_INDEX` in one step and resets all of the',
         '  QP\'s state (PSNs, retry counters, error state, READ resources). Commit only a QP that has no',
         '  outstanding work requests (`WR_OUTSTANDING` = 0, or after `QP_ERR_CMD` flushed them).',
         '- Memory windows are written the same way (`MR_*`, then `MR_COMMIT`). Window *i* serves the',
         '  R_Keys whose low log2(NUM_MR) bits equal *i*; the full 32-bit key is compared.',
         '- The QP-error flow: an error stops the QP (requester: further work requests complete with',
         '  status FLUSHED; responder: requests are dropped), sets its bit in `QP_ERR_MAP*`, latches',
         '  `LAST_REQ_ERR` / `LAST_RESP_ERR` and `STATUS.ERR` (and `irq` when `CTRL.IRQ_EN`). Recover by',
         '  exchanging new parameters with the host and committing the QP again.',
         '',
         '## Registers',
         '',
         '| Offset | Name | Access | Reset | Description |',
         '|---|---|---|---|---|']
    for off, name, acc, rst, desc, fields in regs_all():
        r = ('0x%X' % rst) if rst is not None else '-'
        L.append('| 0x%03X | %s | %s | %s | %s |' % (off, name, acc, r, desc))
    L.append('')
    L.append('## Fields')
    L.append('')
    for off, name, acc, rst, desc, fields in regs_all():
        if not fields:
            continue
        L.append('### 0x%03X %s' % (off, name))
        L.append('')
        L.append('| Bits | Field | Description |')
        L.append('|---|---|---|')
        for msb, lsb, fn, fd in fields:
            b = '[%d]' % msb if msb == lsb else '[%d:%d]' % (msb, lsb)
            L.append('| %s | %s | %s |' % (b, fn, fd))
        L.append('')
    L.append('## Counters')
    L.append('')
    L.append('32-bit, wrapping, at 0x%03X + 4 x index; `CMD.CLR_COUNTERS` clears them. Built when' % CNT_BASE)
    L.append('`COUNTERS_EN` = 1 (otherwise they read 0). 64-bit counters at 0x%03X: read `_LO` first,' % CNT64_BASE)
    L.append('which latches `_HI`.')
    L.append('')
    L.append('| Index | Offset | Name | Counts |')
    L.append('|---|---|---|---|')
    for i, (n, d) in enumerate(COUNTERS):
        L.append('| %d | 0x%03X | CNT_%s | %s |' % (i, CNT_BASE + 4 * i, n, d))
    for i, (n, d) in enumerate(COUNTERS64):
        L.append('| 64-bit | 0x%03X | %s_LO/_HI | %s |' % (CNT64_BASE + 8 * i, n, d))
    L.append('')
    return '\n'.join(L)


def main():
    outs = {
        os.path.join(ROOT, 'rtl', 'ctl', 'rocelet_regs_pkg.sv'): gen_sv(),
        os.path.join(ROOT, 'sw', 'rocelet_regs.h'): gen_h(),
        os.path.join(ROOT, 'docs', 'registers.md'): gen_md(),
    }
    if '--check' in sys.argv:
        stale = [p for p, t in outs.items() if not os.path.exists(p) or open(p).read() != t]
        for p in stale:
            print('stale: %s' % os.path.relpath(p, ROOT))
        return 1 if stale else 0
    for p, t in outs.items():
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w') as f:
            f.write(t)
        print('wrote %s' % os.path.relpath(p, ROOT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
