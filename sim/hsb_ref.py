#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# hsb_ref.py - reference of the NVIDIA Holoscan Sensor Bridge (HSB) RoCE data-plane format,
# for checking rocelet's HSB builder mode. Written from the HSB sources (Apache-2.0,
# github.com/nvidia-holoscan/holoscan-sensor-bridge, v2.7.0 commit 0ee5101):
#   fpga/nv_hsb_ip/dp_pkt/dp_pkt_top.sv  (frame headers, immediate, metadata record)
#   src/hololink/core/hololink.cpp        (Hololink::deserialize_metadata)
#   src/hololink/operators/roce_receiver/roce_receiver.cpp (page_from_imm, psn_from_imm,
#                                          same_psn)
# No code is copied; the formats are re-expressed in Python.
#
# Data packet (dp_pkt_top.sv hdr_roce): Ethernet / IPv4 (version 4, IHL 5, DSCP 0, ECN 0,
# ID 0, flags DF, TTL 0x40, protocol 17) / UDP (source = the device's port, destination =
# the host's port, checksum 0) / BTH (opcode 0x2A RDMA WRITE Only, or 0x2B with immediate;
# SE 0, MigReq 0, PadCnt 0, TVer 0; P_Key 0xFFFF; FECN/BECN/resv 0; dest QP; AckReq 0;
# PSN) / RETH (VA, R_Key, DMA length = this packet's payload) / [ImmDt] / payload / ICRC.
# Immediate (BUFFER_4K_REG): {PSN[19:0], buffer[11:0]}.
# Metadata record (128 bytes, the payload of the WRITE-with-immediate, big-endian):
#   flags u32, psn u32 ({0x00, PSN}), crc u32, timestamp_s u64, timestamp_ns u32,
#   bytes_written u64, (ignored) u16, frame_number u16, metadata_s u64, metadata_ns u32.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import struct

import roce_ref as R

OP_WRITE_ONLY = 0x2A
OP_WRITE_ONLY_IMM = 0x2B
METADATA_SIZE = 128
META_FMT = '!IIIQIQHHQI'          # 48 bytes


def imm(psn, page):
    return ((psn & 0xFFFFF) << 12) | (page & 0xFFF)


def page_from_imm(v):
    return v & 0xFFF


def psn_from_imm(v):
    return (v >> 12) & 0xFFFFF


def same_psn(meta_psn, received_psn):
    return (meta_psn & 0xFFFFF) == received_psn


def metadata(flags=0, psn=0, crc=0, ts_s=0, ts_ns=0, bytes_written=0, frame_number=0, md_s=0, md_ns=0):
    m = struct.pack(META_FMT, flags, psn & 0xFFFFFF, crc, ts_s, ts_ns, bytes_written, 0, frame_number,
                    md_s, md_ns)
    return m + b'\0' * (METADATA_SIZE - len(m))


def parse_metadata(b):
    t = struct.unpack(META_FMT, b[:struct.calcsize(META_FMT)])
    return dict(flags=t[0], psn=t[1], crc=t[2], timestamp_s=t[3], timestamp_ns=t[4], bytes_written=t[5],
                frame_number=t[7], metadata_s=t[8], metadata_ns=t[9])


def packet(dmac, smac, sip, dip, sport, dport, dqpn, psn, va, rkey, payload, immediate=None, ttl=0x40):
    """The frame NVIDIA's HSB IP sends for one data packet (no FCS)."""
    has_imm = immediate is not None
    ln = len(payload)
    ip_len = ln + (64 if has_imm else 60)
    udp_len = ln + (44 if has_imm else 40)
    ip = bytearray(struct.pack('!BBHHHBBH4s4s', 0x45, 0x00, ip_len, 0x0000, 0x4000, ttl, 17, 0,
                               sip.to_bytes(4, 'big'), dip.to_bytes(4, 'big')))
    ip[10:12] = struct.pack('!H', R.ip4_checksum(ip))
    udp = struct.pack('!HHHH', sport, dport, udp_len, 0)
    bth = struct.pack('!BBHB', OP_WRITE_ONLY_IMM if has_imm else OP_WRITE_ONLY, 0x00, 0xFFFF, 0x00)
    bth += dqpn.to_bytes(3, 'big') + b'\x00' + (psn & 0xFFFFFF).to_bytes(3, 'big')
    reth = struct.pack('!QIHH', va, rkey, 0, ln & 0xFFFF)
    ext = reth + (struct.pack('!I', immediate) if has_imm else b'')
    eth = dmac.to_bytes(6, 'big') + smac.to_bytes(6, 'big') + b'\x08\x00'
    frame = eth + bytes(ip) + udp + bth + ext + payload
    return frame + R.icrc_bytes(frame)
