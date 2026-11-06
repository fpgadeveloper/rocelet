# The RoCE v2 subset rocelet implements

rocelet implements the part of RoCE v2 (InfiniBand Architecture Specification Vol. 1, Annex
A17) that FPGA data movers need, and leaves out what only full host NICs need. The subset was
chosen by a measured study (per-feature resource cost against what each application class
loses and what each host NIC requires); this page is its summary.

## What is implemented

### Transport

| Feature | Notes |
|---|---|
| **RC requester** (FPGA -> host): RDMA WRITE, WRITE with immediate, SEND, SEND with immediate | single- and multi-packet messages (FIRST / MIDDLE / LAST / ONLY), PSN per packet, AckReq on the last packet of every message and every `ACKREQ_N` packets, SE on request |
| ACK / NAK processing | coalesced ACKs retire every WR they cover; NAK sequence error -> go-back-N; RNR NAK -> wait (decoded from the AETH timer code, clamped) and retry, never treated as an ACK; fatal NAKs (invalid request, remote access, remote operational) fail the QP |
| Retransmission | go-back-N from a 256 KB on-chip payload ring (`RTX_MODE` "RING", live sources) or by re-reading memory ("REREAD"); "LOSSY" lossy resume (experimental) |
| ACK timeout, retry and RNR retry counters | microsecond timer, IBTA retry_cnt / rnr_retry semantics (rnr_retry 7 = for ever); ACK timeouts held while `link_up` is low and for `LINK_GRACE` after |
| **UC requester** (per QP) | standard UC FIRST / MIDDLE / LAST / ONLY |
| **HSB mode** (per QP) | UC WRITE Only per packet with its own RETH, WRITE Only with Immediate {PSN[19:0], buffer[11:0]}, metadata PSN patch: the NVIDIA Holoscan Sensor Bridge data plane ([hsb.md](hsb.md)) |
| **RC responder** (host -> FPGA): RDMA WRITE, WRITE with immediate, SEND, SEND with immediate | WRITE into FPGA memory (cut-through, committed on a good ICRC); SEND to a stream with a per-packet commit/discard verdict; receive completions {QP, opcode, immediate, message length} |
| RC responder: RDMA READ | `READ_DEPTH` outstanding new READs per QP (a power of two: mlx5 rounds `max_rd_atomic` up); responses in PSN order with the ACKs; duplicate and partial duplicate READs re-executed without taking a READ slot; partial re-issues answered as a continuation (`CTRL.READ_CONT`, what the ConnectX-6 Dx requires) or as a new response (IBTA, rxe) |
| RC responder rules | ACK every AckReq at once; one NAK-sequence per gap, then silence until the expected PSN; duplicates re-ACKed with the latest PSN; MSN in every AETH; credits 0x1F; Class C errors (opcode sequence, R_Key, length, too many READs) -> NAK + QP error + error cause |
| RNR NAK generation | `send_rnr`: a SEND that cannot be received gets an RNR NAK (timer `RNR_NAK_TIMER`) |
| QP state | RESET (commit) / RTS / ERROR per QP; error causes captured; per-QP reset by a configuration commit (no bitstream reload); a forced error flushes a QP's work requests |
| Memory windows | `NUM_MR` windows {VA, length, local address, R_Key, read/write}, selected by the low R_Key bits with a full 32-bit key compare |
| QPs | `NUM_QP` (16 default, 1-256), local QPN = `QPN_BASE` + index |
| Path MTU | 256-4096 per QP. At 100G: WRITE and SEND at line rate at PMTU >= 1024 (the responder reaches 67 % / 89 % of 100 Gb/s at 256 / 512); host READs of FPGA memory measured 81 Gb/s at PMTU 1024 and 95.1 Gb/s at 2048 ([host-setup.md](host-setup.md) section 5). At 40G: host READs of FPGA memory at line rate at PMTU 4096, 1024 and 512 (38.7, 37.0 and 34.4 Gb/s of payload; PMTU 256 not measured). Every rate: [throughput.md](throughput.md) |

### Wire format and network

| Feature | Notes |
|---|---|
| IPv4 | IHL 5, DF set, ID 0, fragment offset 0, TTL and DSCP/ECN from `IP_HDR` (ECN 00), header checksum; IPv6 is a build option (`IPV6_EN`, simulation-verified only, not part of v1) |
| UDP | destination port 4791 (per-QP override for HSB Linux-UDP receivers), source port per QP, checksum 0 |
| BTH | P_Key 0xFFFF, TVer 0, PadCnt, MigReq 1 (ConnectX interop; 0 on HSB QPs, as NVIDIA's HSB IP); MigReq 0 accepted on receive (some NICs send 0) |
| ICRC | IBTA A17 masks (IPv4 ToS, TTL, checksum, UDP checksum, BTH byte 4, 8 bytes of 0xFF in front, pad covered); generated on every frame, checked on receive (`RX_ICRC_EN`, on) |
| CNP (opcode 0x81) | counted and dropped (a ConnectX sends them after losses even without ECN marking) |
| 802.1Q | VID-0 priority tags removed on receive (ConnectX in PCP mode, some NICs with several DCB traffic classes); optional tag on transmit (off by default: some NICs drop VID-0-tagged RoCE frames) |
| 802.3x PAUSE | honoured (TX gated at frame boundaries) and requested from the RX FIFO level |
| ARP / ICMP | ARP requests (unicast and broadcast) and ICMP echo answered: hosts need the FPGA's MAC to bring a QP to RTR, and a driver with its own hardware ARP table may kill a QP whose neighbour entry goes stale |
| Other traffic | non-RoCE frames to / from a CPU or NIC stack (e.g. the HSB control plane) |
| MAC width | 512-bit engine; MAC AXI-Stream of 512, 256, 128 or 64 bits (`MAC_WIDTH`) through built-in width converters, PAUSE timing set by `LINK_GBPS`: 100G (512 bits), 40G (256 bits) and 10G (64 bits) validated on hardware, 25G clocking checked in simulation |

### Interop checklist (what every frame obeys)

ICRC exactly per A17; BTH MigReq = 1, P_Key 0xFFFF, TVer 0, correct PadCnt; UDP destination
4791, source port per QP, UDP checksum 0; IPv4 IHL 5, DF, fragment offset 0, TTL 64, DSCP 0,
ECN 00; AETH with the correct MSN and credits 0x1F; every AckReq ACKed immediately (slow ACKs
trigger mlx5 early duplicates); one NAK-sequence per gap; duplicate WRITE/SEND re-ACKed;
duplicate (also partial) READs re-executed; READ responses and ACKs in PSN order; coalesced
ACKs retire every covered WR; RNR NAK is not an ACK; CNPs accepted and dropped; MigReq 0 and
VID-0 priority tags accepted on receive; receive validation drops bad packets (IHL,
fragments, UDP length, TVer, QP state, pad on FIRST/MIDDLE, length vs PMTU; the IPv4 header
checksum is covered by the Ethernet FCS, not by the ICRC), with CE-marked packets accepted.

## What is deliberately not implemented

| Not in rocelet v1 | Why / what to use instead |
|---|---|
| READ requester (the FPGA pulls from host or GPU memory) | the anchor roles do not need it; est. 1.5-3k LUT; planned for v2 (FPGA pull, NVMe-oF target) |
| Atomics, UD, XRC, RD, DC, SRQ, SEND with invalidate, memory windows type 1/2, FLUSH, ATOMIC WRITE | full-peer features (storage, HPC, key-value stores); the host must not post them (NAK, host QP error) |
| PD / MR table with dynamic registration, associative R_Key lookup | 16 statically configured windows; a 64-entry CAM is a v2 option for multi-tenant hosts |
| In-band connection management (QP1 MADs, RDMA CM) | out-of-band exchange of QPN, PSN, addresses and keys (the host helper `rocelet_host`, or a UDP side channel); rdma_cm applications cannot connect |
| Verbs queues in memory (SQ / RQ / CQ rings, doorbells, WQE fetch) | work requests and completions are AXI-Streams; a soft CPU posts work through a small bridge in the design |
| UC responder | v2 |
| IPv6 in the product | the RTL has it (`IPV6_EN`), simulation only |
| VLAN tagging other than accepting VID 0 (and the optional TX tag), PFC | point to point, 802.3x global pause does the job |
| DCQCN reaction point, ECN notification point (CNP generation) | nothing marks CE on a point-to-point link; v2 "switched fabric pack" with a rate-aware scheduler |
| Per-QP send queues / scheduler | one shared WR stream and WR ring in issue order: a QP waiting on RNR or a slow peer holds back the others (head-of-line blocking); v2 |
| End-to-end credits | the credit field is 0x1F; a host without posted receives answers with RNR NAKs, which rocelet handles |
| Unaligned FPGA buffers | VA and length 64-byte aligned (except the last packet); byte-unaligned buffers cost about 5k LUT |
| The CMAC IP's AXI-Lite statistics block | fabric counters in rocelet instead (FCS errors, RS-FEC, pause, TX underrun) |
| Per-QP statistics counters | the counters are per port; per-QP error causes are kept |

## Host NICs

rocelet is validated against an NVIDIA ConnectX-6 Dx (mlx5) in all three roles: at 100G on a
KCU116 with the AMD CMAC (v0.2.2, including READ re-issue after response loss, where the
continuation answer is required, and link loss; v0.3.0 at 512 bits passes the same simulation
regression and builds the KCU116 target), and at 40G and 10G on a ZCU106 with the open-source
omac MACs (v0.3.0, including 802.3x PAUSE in both directions at 40G).
The host-side facts are in [host-setup.md](host-setup.md). UC (and so the HSB mode) is accepted only by NVIDIA (and rxe,
MANA); Broadcom bnxt_re and the other RDMA drivers reject UC QPs.
