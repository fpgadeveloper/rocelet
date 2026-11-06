# Holoscan Sensor Bridge (HSB) compatibility

**Goal:** a host running NVIDIA's holoscan-sensor-bridge software receives sensor frames from a
rocelet design exactly as it does from an NVIDIA HSB device. rocelet provides the **data plane**
in RTL (the HSB builder mode, QP type 2). The **control plane** (enumeration, register protocol,
the device's register map) and the frame producer belong to the design around the engine; the
qsfp28-fmc-rocelet reference design implements them (see "Done in the design" below).

The formats below were read from NVIDIA's repository (holoscan-sensor-bridge 3.0.0, Apache-2.0):
`fpga/nv_hsb_ip/dp_pkt/dp_pkt_top.sv` (packet headers, immediate, metadata),
`src/hololink/core/frame_metadata_parser.hpp` (`parse_frame_metadata`, which
`Hololink::deserialize_metadata` in `src/hololink/core/hololink.cpp` calls) and
`src/hololink/operators/roce_receiver/roce_receiver.cpp` (`page_from_imm`, `psn_from_imm`,
`same_psn`). No NVIDIA code is used in rocelet.

## What the host expects (the data plane)

| Item | HSB | rocelet HSB mode |
|---|---|---|
| Transport | UC; the host QP has `path_mtu` 4096, `rq_psn` 0, MR at IOVA 0 | QP type 2 (UC). Start the FPGA QP at `QP_SQ_PSN` = 0 |
| Data packets | every packet a **RDMA WRITE Only (0x2A) with its own RETH**: VA = page base + offset, DMA length = this packet | every packet of a WRITE WR is a WRITE Only with RETH (VA = WR VA + offset, length = packet) |
| End of frame | a **WRITE Only with Immediate (0x2B)** carrying a 128-byte metadata record, written after the frame on the same page | the last packet of a WRITE-with-immediate WR is 0x2B |
| Immediate | **{PSN[19:0], page[11:0]}** (the host takes the page from bits 11:0 and the PSN from 31:12) | rocelet inserts PSN[19:0]; the WR's `imm[11:0]` is the page |
| Metadata PSN | the record's PSN field (bytes 4..7, {0x00, PSN}) must equal the immediate's PSN, or the host logs "Metadata psn=... but received_psn=..." | WR flag `hsb_md`: rocelet writes the PSN of the packet carrying the immediate into payload bytes 4..7 |
| BTH | SE 0, MigReq 0, PadCnt 0, TVer 0, P_Key 0xFFFF, AckReq 0, PSN +1 per packet | the same (PadCnt follows the payload length; HSB payloads are multiples of 64 bytes, so 0) |
| IPv4 / UDP | DSCP 0, ECN 0, ID 0, DF, TTL 0x40, UDP checksum 0; source port = the device's data-plane port (HSB default 12288); destination port = the host's (`DP_HOST_UDP_PORT`: 4791 for RoCE, another port for the Linux-UDP receiver) | `IP_HDR` (keep ToS 0, TTL 64), `QP_UDP.SPORT`, `QP_UDP.DPORT` (0 = 4791) |
| Retransmission | none (UC) | UC QPs complete a WR when sent |

The simulation (`sim/test_req_tx.py`, configuration `hsb`) compares rocelet's HSB packets byte
for byte with a re-implementation of NVIDIA's header builder (`sim/hsb_ref.py`), and decodes
each metadata record as the host does (PSN in the record = PSN in the immediate, page = the
WR's page).

## The metadata record

128 bytes, big-endian: `flags` u32, `psn` u32 ({0x00, PSN[23:0]}), `crc` u32 (CRC-32 of the
frame, may be 0), `timestamp_s` u64 + `timestamp_ns` u32 (PTP time of the first data),
`bytes_written` u64, (reserved) u16, `frame_number` u16, `metadata_s` u64 + `metadata_ns` u32
(PTP time of the metadata), then zeros to 128 bytes. rocelet fills only the PSN; the producer
fills the rest.

## Producing frames

For each sensor frame, with the page ring the host programmed (`DP_PAGE_LSB/MSB`,
`DP_PAGE_INC`, `DP_MAX_BUFF`, `DP_BUFFER_LENGTH`):

1. WRITE WRs for the frame data at `page_base(page) + offset`. Any WR size works (every packet
   is self-describing); WRs of a few KB to the ring's limit. The packet size is the QP's PMTU
   (at most the host MTU allows; 4096 with MTU 4200, 1024 with MTU 1500).
2. One WRITE-with-immediate WR of 128 bytes (the metadata record), VA = page base + frame size
   rounded up to 128 bytes, `imm[11:0]` = page, flag `hsb_md` = 1.
3. Next page: (page + 1) mod (`DP_MAX_BUFF` + 1).

A small producer module (frame splitter, page counter, metadata builder with a free-running
timestamp and byte/frame counters) in the design does this; it is not part of the engine. The
qsfp28-fmc-rocelet design's producer is about 1.7k LUT.

## The control plane (firmware, behind the other-traffic port)

| HSB function | What the firmware does |
|---|---|
| Enumeration | a BOOTP broadcast every second from UDP 12267 (vendor field: 'NVDA', data-plane index, enumeration version 2, compat id, the device **UUID**, serial number, HSB IP version >= 0x2602); handle the host's reply on UDP 12268 (`hololink-set-ip`) |
| Register access | the Ethernet Control Bus (ECB) on UDP 8192: READ/WRITE DWORD/BLOCK, 14-byte header, big-endian address/data pairs, responses with command + 0x80 and a status |
| Device registers | answer `HSB_IP_VERSION` (0x80), `FPGA_DATE` (0x84); accept the PTP, event and reset registers (as NVIDIA's emulator does: stored, no effect); translate the `DP_*` writes (QP, R_Key, page ring, packet size, host MAC/IP/UDP port, `DP_VP_MASK` start) into rocelet's `QP_*` registers and the producer's settings |

NVIDIA's HSB Emulator (in the same repository) is the reference for the minimum a device must
answer.

## Done in the design

The [qsfp28-fmc-rocelet](https://qsfp28-rocelet.ethernetfmc.com/en/latest/hsb.html) reference design
implements everything above the data plane: the firmware control plane (BOOTP enumeration with
an Opsero device UUID, 98183d0f-18ee-4719-a3b4-ca69e9b94c97, compat-id and HSB IP version
0x2603, the register protocol on UDP 8192, the `DP_*` register layout that the HSB 3.0.0 host
programs for that compat-id), the frame producer, an Opsero `hololink_module` for the module
API (the classic API needs no module), and a stub for the PTP registers. It is tested against
HSB 3.0.0 on a ConnectX-6 Dx host, with the RoCE receiver into GPU memory and the Linux-UDP
receiver. UC is needed, so the host NIC must accept UC QPs (NVIDIA ConnectX does; many other
RDMA NICs do not).

## Future work

1. **PTP**: many HSB applications call `ptp_synchronize`. The design stores the PTP registers,
   reports "not synchronised" and stamps the metadata from a free-running counter, so those
   applications wait for their timeout and continue. Real IEEE 1588 with hardware timestamps is
   a project of its own.
2. **Frame CRC**: the producer writes 0 in the metadata's CRC field and HSB 3.0.0 accepts it;
   whether any stock application checks the CRC is unanswered (a second 512-bit CRC-32 in the
   producer, about 2.6-3.3k LUT, if one does).
3. **Version tracking**: claiming HSB IP version 0x2603 is a promise to follow NVIDIA's
   register layout for that compat-id as the HSB software evolves.
