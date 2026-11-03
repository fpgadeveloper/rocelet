# Host setup and host rules

What a Linux host with a hardware RoCE v2 NIC needs to talk to a rocelet FPGA over a point-to-
point 100G link, and the host-side rules learned on the bench with the qsfp28-fmc-rocelet
reference design (KCU116 + Opsero OP120). The validated host NIC is an **NVIDIA ConnectX-6
Dx** (firmware 22.43.2566, inbox `mlx5` and rdma-core 50, Ubuntu 24.04, Linux 6.8, 3 m QSFP28
DAC; rocelet v0.1 to v0.2.2, 2026-10-30/31). Where a rule depends on the NIC, the ConnectX-6 Dx
behaviour is the measured one; notes on "some NICs" or "some drivers" say what to check on a
host with another NIC. Items marked *unverified* come from driver sources or published
measurements and were not checked on the bench.

## 1. Link

| Item | Setting |
|---|---|
| Cabling | point to point (DAC, AOC or optics), no switch needed |
| Speed / auto-negotiation | 100GBASE-*4, **forced**: the FPGA's CMAC does no auto-negotiation. A ConnectX-6 Dx starts with clause-73 auto-negotiation and reports "No partner detected" until it is off: `ethtool -s <if> speed 100000 duplex full autoneg off` (make it persistent in the network configuration, for example a systemd `.link` file; mlx5 rejects `lanes 4`). |
| FEC | **RS-FEC (Clause 91) on at both ends.** ConnectX-6 Dx: FEC `Auto` resolves to RS(528,514) against the FPGA with no change on either side (`ethtool --show-fec <if>`); on the 3 m DAC 0 uncorrected codewords on a quiet link, the FPGA corrected about one codeword per second. A NIC whose FEC does not resolve to RS-FEC by itself needs it set by hand, the same at both ends; some drivers accept the change only with the port down: `ip link set <if> down; ethtool --set-fec <if> encoding rs; ip link set <if> up`. |
| MTU | **4200** for PMTU 4096 (`ip link set dev <if> mtu 4200`). The largest IPv4 RoCE frame is 4160 bytes. mlx5's active_mtu is the largest IB MTU not above the netdev MTU - 96 (the ConnectX-6 Dx reports 4096 at MTU 4200); other drivers may compare against the netdev MTU itself. MTU 1500 gives PMTU 1024. |
| Pause | rocelet honours received 802.3x PAUSE and sends PAUSE from its RX FIFO level. ConnectX: link pause is **on** by default (rx and tx); the FPGA's PAUSE frames were honoured with no host change (24,000,193 PAUSE frames sent by the FPGA, all counted by the ConnectX-6 in `rx_pause_ctrl_phy`, no drop). PAUSE from the ConnectX-6 to the FPGA was not tested as such. Some drivers have link flow control **off** by default: check with `ethtool -a <if>` and turn it on with `ethtool -A <if> rx on tx on` (the port may relink for a few seconds). |
| VLAN / DCB | rocelet strips VID-0 priority tags; it does not use other VLANs. A ConnectX-6 Dx accepts VID-0 priority-tagged RoCE frames on an untagged QP (`CTRL.VLAN_TX_TAG` = 1 with PCP 3: received on `rx_prio3`, READ responses at 96.61 Gb/s) and sends its own ACKs untagged. Some NICs tag their RoCE frames with VID 0 when DCB has more than one traffic class (rocelet strips the tag; keep one class point to point), and some drop VID-0-tagged RoCE frames they receive (the frames never reach the QP, yet may still be counted in the NIC's IP octet counters): **keep `CTRL.VLAN_TX_TAG` = 0 (the reset value) unless the host NIC is known to accept them.** |
| FPGA address | the FPGA answers ARP (unicast and broadcast) and ICMP echo, so `ping` works and the kernel resolves its MAC when a QP goes to RTR (1 s timeout, else `ETIMEDOUT`). |

## 2. Neighbour entry

A ConnectX-6 Dx needs no static neighbour entry: a 2 h 15 min soak (772 M messages, 50.6 TB at
50 Gb/s) ran with the kernel's dynamic entry (STALE / REACHABLE). rocelet answers the kernel's
unicast ARP probes, which keeps the entry valid.

Some drivers copy the peer's MAC into a hardware ARP table of their own and **delete it when the
kernel neighbour entry leaves NUD_VALID**; the QP then dies. With such a NIC, pin the entry for
long runs or on a busy CPU:

```
ip neigh replace <fpga-ip> lladdr <fpga-mac> dev <if> nud permanent    # remove after the run
```

## 3. QP bring-up (out of band)

rocelet has no in-band connection manager. The host program (or `host/rocelet_host`) and the
FPGA firmware exchange: QPN, first PSN, IPv4, MAC, path MTU, and for each direction the buffer
VA, R_Key and size, plus the FPGA's READ depth. Then, on the host:

| Step | Setting |
|---|---|
| GID | pick the **RoCE v2, IPv4-mapped** GID of the netdev programmatically (`ibv_query_gid_ex`, type `IBV_GID_TYPE_ROCE_V2`, prefix `::ffff:`), never a fixed index (index 3 on the bench ConnectX-6 Dx; other NICs differ) |
| Address handle | global: `is_global = 1`, `dgid = ::ffff:<fpga-ip>`, `sgid_index` = that GID, `traffic_class` = DSCP << 2 (keep 0) |
| INIT | `pkey_index 0`; access flags as the test needs (LOCAL_WRITE, REMOTE_WRITE, REMOTE_READ) |
| RTR | `path_mtu` <= active_mtu and = the FPGA QP's `QP_PMTU`; `dest_qp_num` = FPGA QPN (`QPN_BASE` + index); `rq_psn` = the FPGA's first PSN (`QP_SQ_PSN`); `max_dest_rd_atomic` 1 (rocelet has no READ requester); `min_rnr_timer` (mlx5 uses it: the ConnectX-6 sent the host's 12 in its RNR NAKs and rocelet waited 0.64 ms; some drivers ignore it) |
| RTS | `sq_psn` = what the FPGA expects (`QP_RQ_PSN`); `retry_cnt 7`, `rnr_retry 7`; `timeout` (e.g. 14: mlx5 uses it, some drivers ignore it); **`max_rd_atomic` <= the FPGA's `READ_DEPTH`** and never 0 (some drivers take 0 as the device maximum). mlx5 rounds it **up** to a power of two: rocelet's `READ_DEPTH` is a power of two, so give the host exactly that value (the ConnectX-6 Dx's maximum, `max_qp_rd_atom`, is 16 = the default `READ_DEPTH`). |

## 4. Receive queue and immediates

- Post receive WRs for every SEND and every WRITE with immediate in flight (zero-length receives
  are fine for WRITE with immediate) and re-post one per completion. Too few receives cost
  rate: each RNR NAK makes the requester wait (one ConnectX-6 run with a 64-entry receive
  queue, re-posted slowly on purpose, was receiver-bound at 5.9 Gb/s).
- **ConnectX-6 Dx: RNR recovers for every message type.** On a multi-packet WRITE with
  immediate it NAKs the LAST packet (the one that consumes the receive WQE) and rocelet resends
  from there: 38,230 RNR NAKs in one run (64 KB WRITE with immediate), all recovered, 0 lost.
  Multi-packet SEND at full rate: 113 RNR NAKs (16 KB SEND, 96.29 Gb/s) and 97 (64 KB SEND with
  immediate, 97.27 Gb/s), all recovered. Its RNR NAKs carry the host QP's `min_rnr_timer`.
- **Other NICs: do not let the receive queue run dry under multi-packet WRITE with immediate
  unless the NIC is known to recover.** On some NICs an RNR NAK on the LAST packet of a
  multi-packet WRITE with immediate flushes the host QP, whatever the requester does, while
  single-packet WRITE with immediate and multi-packet SEND recover from RNR normally. Post at
  least (messages in flight + jitter) receives, or keep WRITE-with-immediate messages <= PMTU,
  or use a plain WRITE plus a separate SEND for the notification.
- Some providers report WRITE-with-immediate completions as `IBV_WC_RECV` with
  `IBV_WC_WITH_IMM`, not as `IBV_WC_RECV_RDMA_WITH_IMM`: classify by what was posted
  (`rocelet_host` does, on every NIC).
- A NIC whose driver does not pass `min_rnr_timer` on may ask for RNR timer code 0 (655 ms) in
  its RNR NAKs; rocelet decodes the code and waits (clamped to `RNR_MIN` / `RNR_MAX`). Lower
  `RNR_MAX` if 655 ms is too long for the application.

## 5. RDMA READ of FPGA memory

- READ depth: see section 3. More *new* READs in flight than the FPGA's depth is a NAK and a
  host QP error. Re-issued (duplicate) READs do not count: since v0.2 rocelet re-executes them
  without taking a READ slot. After a READ-response loss a ConnectX-6 Dx re-issues the partial
  READ and every later outstanding READ within microseconds (duplicate READs about 5.7 x the
  lost responses); with v0.2.0, 13.0 M READs with 15.4 k lost responses at `max_rd_atomic` 16,
  12 and 10 completed with no NAK and correct data (92.56-94.22 Gb/s at 200 ppm loss and
  `max_rd_atomic` 16). (v0.1 counted the duplicates, and the ConnectX-6 Dx with `max_rd_atomic`
  16 got NAK 0x61 "invalid request" on a later READ; the workaround was `max_rd_atomic` 8.)
- **Partial READ re-issue**: after losing a READ RESPONSE, a host re-issues from the lost PSN.
  The ConnectX-6 Dx re-issues a lost MIDDLE after 4.85-4.90 µs (gap detected,
  `implied_nak_seq_err` +1), a lost LAST after its adaptive timeout (96.6 ms and 21.6 ms in two
  runs, `roce_adp_retrans` +1) and a lost FIRST as the whole READ after 2.8 µs. It accepts only
  a continuation answer (MIDDLE ... LAST): keep `CTRL.READ_CONT` = 1 (default). With 0 the
  ConnectX-6 fails the READ with "bad response" (status 7, vendor 0x86) and its QP goes to
  error. Some NICs re-issue a lost READ response only after their READ retransmission timeout
  (tens of milliseconds) rather than on the gap. IBTA and rxe answer with a new FIRST/ONLY
  response; rxe accepts both.
- Rate (ConnectX-6 Dx, `max_rd_atomic` 16): 96.59-96.79 Gb/s at PMTU 4096, 95.10 at 2048,
  81 at 1024 (about 9.9 M READ responses per second; not investigated).

## 6. Counters and observability

| NIC | Where to look |
|---|---|
| ConnectX (mlx5) | `/sys/class/infiniband/<dev>/ports/1/hw_counters/`: `out_of_sequence`, `packet_seq_err`, `implied_nak_seq_err`, `duplicate_request`, `out_of_buffer` (no receive WQE), `rnr_nak_retry_err`, `local_ack_timeout_err`, `roce_adp_retrans`, `roce_adp_retrans_to`, `req_cqe_error`, `resp_cqe_error`, `req_remote_access_errors`, `rx_icrc_encapsulated`, `roce_slow_restart*` (counted since boot: take deltas). On the ConnectX-6 Dx `out_of_sequence` matched the FPGA requests the injector dropped exactly, `packet_seq_err` matched rocelet's NAK-seq exactly (host as requester), `out_of_buffer` matched rocelet's `RX_RNR_NAK`; a frame with a bad ICRC was dropped **without a counter** (`rx_icrc_encapsulated` stayed 0; only the NAK-seq for the next packet shows it). The inbox stack has no `req_transport_retries_exceeded`. `ethtool -S <if>`: `rx_pause_ctrl_phy`, `rx_discards_phy`, `outbound_pci_stalled_wr`; the PHY counters reset at every link down (every FPGA reprogram), so snapshot them per run. The bench host's inbox stack listed no RDMA capture device (`tcpdump -D`): use the FPGA-side capture (host/README.md). Trouble shows in the kernel log as `mlx5` lines. |
| other NICs | the counters differ by driver: some list **no RoCE transport error counters** in `hw_counters` (nothing for ICRC, PSN sequence, NAK, timeout, RNR, duplicates), only IP/UDP packet and octet counters. rocelet's own counters and the FPGA-side capture (host/README.md) then show the transport. Check the kernel log for the driver's QP errors. |
| rocelet | the counters of the register map (docs/registers.md) mirror these: `RX_ICRC_BAD`, `RX_OOS`, `RX_DUP`, `RX_RNR_SENT`, `REQ_RTX`, `REQ_TIMEOUT`, `RX_RNR_NAK`, `RX_CNP`, pause, FCS, RS-FEC, underrun. |

## 7. ConnectX-6 Dx behaviour: confirmed on the bench, and what is unverified

Confirmed with the qsfp28-fmc-rocelet design against the ConnectX-6 Dx (sessions of 2026-10-30
and 2026-10-31, rocelet v0.1 to v0.2.2, and the Holoscan Sensor Bridge sessions of 2026-10-31):

- **Frame acceptance, MigReq (confirmed).** rocelet's RC frames with MigReq = 1 are accepted (0
  NIC error counters in every clean run); the ConnectX-6's own ACKs carry MigReq 1, ToS 0x02
  (ECT(0)) and AETH credits, and pass `roce_check.py`. HSB QPs send MigReq 0, as NVIDIA's HSB
  IP does; HSB's RoCE receiver (a UC QP) on the ConnectX-6 Dx took them into GPU memory.
  *Unverified (literature):* a ConnectX-5 dropped about 500 packets per 16 QPs receiving
  MigReq = 0 on RC (Lumina, SIGCOMM'23); not tried on the bench.
- **ICRC (confirmed, counter differs).** Frames corrupted after the ICRC are dropped and
  recovered by NAK-seq / go-back-N (919 and 15,387 corruptions in two runs, no loss), but
  `rx_icrc_encapsulated` stayed 0 (see section 6). *Unverified:* that there is no public switch
  to disable the check (driver sources).
- **ACKs (confirmed).** One ACK per AckReq, also in the middle of a message (128 KB message: 2
  ACKs, 256 KB: 4); dropped FPGA ACKs (1 in 100) are covered by later ACKs with no ConnectX-6
  retransmission.
- **NAK sequence error (confirmed).** Sent at once for every gap: `out_of_sequence` = the
  injected drops exactly; a lost READ MIDDLE is re-issued in under 5 µs (section 5).
- **Wrong R_Key (confirmed).** NAK remote access error (AETH 0x62): about 1.2-1.4 ms after a
  plain WRITE, 1.83 ms after a 4 KB WRITE with immediate; with a budget of 8 x 1 ms or more
  (default 8 x 5 ms) the FPGA QP reports requester error 0x62 (with the 200 µs ACK timeout the
  design firmware set at the time, 8 x 200 µs, it timed out first, 0xFF). The host's QP goes to error.
- **READ re-issue and continuation (confirmed)**: section 5.
- **RNR (confirmed)**: `min_rnr_timer` honoured, multi-packet WRITE with immediate recovers
  (section 4).
- **Adaptive retransmission (partly seen).** In the loss tests with the host as requester
  (FPGA ACK drops, FPGA-side request drops) `roce_adp_retrans` stayed 0; it counted one on a
  lost READ LAST (re-issue after 96.6 / 21.6 ms). *Unverified (literature):* with `retry_cnt 7`
  a ConnectX-6 Dx retried 8-13 times with timeouts from 4 µs; the `ROCE_ACCL` register
  (`mlxreg -d <bdf> --reg_name ROCE_ACCL --get`) was not recorded. rocelet re-ACKs duplicate
  requests and re-executes duplicate READs either way.
- **UC (confirmed).** HSB 3.0.0's RoCE receiver opened a UC QP on the ConnectX-6 Dx and received
  rocelet's UC-HSB frames into GPU memory (up to 80 Gb/s on the test host). *From sources:* rxe
  and MANA accept UC; other RDMA drivers, bnxt_re among them, reject it (EOPNOTSUPP).
- **Pause (confirmed)**: section 1.
- **ACK round trip and the retransmit ring (confirmed).** 256 KB covers 21 µs at 100 Gb/s; a
  smaller ring is still correct but caps throughput at ring / RTT. Under PCIe back pressure (a
  GPU ring on the Lenovo P520) the ConnectX-6 delays its ACKs (average WR to completion 9.35 µs
  against 5.08 µs into host memory) with 0 retransmissions. A 256 KB message fills the 256 KB
  ring, so one message is in flight: 58.50 Gb/s, against 97.69 Gb/s with 128 KB messages.
- **Link loss (confirmed)**: a 35.6 s DAC pull (v0.2.0) and a 14.9 s pull at the v0.2.2
  defaults, 1 timeout each, nothing lost; `KEEP_ETH_LINK_UP` and forced drops in section 10.
- *Unverified:* **CNPs** may arrive after losses even without ECN marking ("slow restart");
  rocelet counts and drops them (no CNP was looked for on the bench). **Selective repeat**
  stays off without ECE negotiation; keep `selective_repeat_forced_en = 0`.
- **perftest** between two hosts: use `--no_enhanced_reorder` (perftest enables out-of-order
  data placement by default on capable NVIDIA devices). perftest cannot talk to the FPGA (its
  exchange format is its own).

## 8. Safety on a shared host

- Use an isolated point-to-point link; never put the FPGA link on a LAN or behind a router.
  rocelet's ARP/ICMP responder only replies, but a mis-configured test design could reflect
  traffic.
- User-space tools only during tests (`rocelet_host`, `roce_check.py`, `ibv_devinfo`, `rdma`,
  `ethtool -S/-a/--show-fec`, `journalctl -k`). The host changes a test needs are limited to the
  test port and reversible: speed / auto-negotiation, FEC, MTU, link pause, hugepages, and
  where the NIC needs it one static neighbour entry.
- Start at a low rate (rocelet's `PACE_RATE`, `rocelet_host --rate`), step up, check the kernel
  log between steps (`journalctl -k | grep -i mlx5`, or the host NIC's driver name) and **stop at the first RDMA
  error**: capture counters and logs before repeating anything. Keep a way to power the FPGA
  off remotely.

## 9. GPU ring (GPUDirect RDMA via dma-buf)

Nothing changes on the wire or in the FPGA: rocelet writes to a VA and an R_Key as always. The
host registers GPU memory instead of host memory, and `host/rocelet_host --mem gpu` (sink
`--op write` / `write_imm`, `make CUDA=1` build) does it as follows: `cudaMalloc` (2 MiB rounded,
filled with the fill byte, `CU_POINTER_ATTRIBUTE_SYNC_MEMOPS`) -> `cuMemGetHandleForAddressRange(...,
CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD)` -> `ibv_reg_dmabuf_mr(pd, 0, len, iova, fd,
LOCAL_WRITE | REMOTE_WRITE | REMOTE_READ)`. Proven with rocelet on a Lenovo P520 + ConnectX-6 Dx
+ RTX PRO 4000 Blackwell.

**Requirements**

| Item | Needed |
|---|---|
| GPU | a workstation or data-centre NVIDIA GPU with dma-buf support (`CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED` = 1; `selftest-gpu` prints it). Proven: RTX PRO 4000 Blackwell (sm_120) |
| GPU driver | the **NVIDIA open kernel module** (dma-buf export needs it; proven with 595.99.02 open, DKMS). **nvidia-peermem is not needed** and need not be loaded |
| RDMA stack | the **inbox** kernel and rdma-core with dma-buf MRs: Linux >= 5.12, rdma-core >= 34 (`ibv_reg_dmabuf_mr`), an mlx5 NIC. Proven: Ubuntu 24.04 kernel 6.8, rdma-core 50, ConnectX-6 Dx. DOCA-OFED is not needed |
| Build | CUDA toolkit 11.7 or newer (proven 13.2): `make -C host CUDA=1` (add `CUDA_ARCH=sm_XX` to build without querying the GPU). `make` without CUDA builds a binary in which `--mem gpu` stops with a message |
| Topology | NIC and GPU on CPU lanes; ideally behind one PCIe switch (`nvidia-smi topo -m`: `PIX` / `PXB`). `NODE` (different root ports of one CPU) works but caps the rate (below) |
| Completion signal | WRITE with immediate (or plain WRITE checked after the run). Polling GPU memory for a "data then flag" pattern is not safe by default |

**IOVA: 0 (decision 2026-10-30).** `ibv_reg_dmabuf_mr` takes the address the peer will use. rocelet_host
registers the ring at **IOVA 0** by default, the Holoscan Sensor Bridge host convention (HSB's
`RoceReceiver` does the same), so the RLHM `va=` is the byte offset in the ring and an HSB-style
data plane needs no translation. `--gpu-iova dev` registers at the GPU device address instead (`va=`
then looks like any host VA). The FPGA side
is the same either way: the FPGA writes VA = `va=` + offset and its payload pattern uses that VA as
the pattern address, and the GPU checks pattern(VA). The qsfp28-fmc-rocelet firmware accepts
`va=0x0`. `selftest-gpu` registers at both IOVAs.

**BAR1 limit.** The NIC reaches GPU memory through the GPU's BAR1 aperture, so a registered GPU
ring can be no larger than BAR1 minus what the driver keeps. On the P520 BAR1 is **256 MiB** and
cannot be resized (the BIOS has no Resizable BAR; the runtime resize failed): dma-buf registrations
up to 251 MiB work, 252 MiB fails (NVRM "can not alloc VA space"). rocelet_host caps a GPU ring at
**BAR1 - 16 MiB = 240 MiB** (BAR1 read through NVML; 240 MiB if NVML is missing) and refuses a
larger `--buf-size` with a message before allocating; `--buf-size max` takes the cap. A 240 MiB ring
makes BAR1 used ~244 MiB, so **only one such ring fits per GPU at a time, across all processes**:
check `nvidia-smi -q -d MEMORY | grep -A3 BAR1` before a run on a shared host. A GPU with Resizable
BAR has a BAR1 as large as its memory and no practical cap.

**Verification on the GPU.** The CPU cannot read the ring. Each WRITE-with-immediate completion
becomes a job (ring offset, pattern address, length); jobs go to the GPU in batches (64 messages,
or a partial batch after 200 µs), one 256-thread block per message checks every 64-byte beat
against the pattern of its address, and the results return in completion order, so the counts
equal the CPU checker's (`rl_pat_check()`) byte for byte. Bad beats are classified as fill (never
written / not visible yet), misplaced (the pattern beat of another address) or corrupt. With
scrub on (default for rings >= 16 MiB) each checked message is refilled, so a later lap that did
not land, or whose data was not yet visible at its completion, shows up as fill. rocelet has no
application-level credit, so the ring must lap more slowly than a check waits (a 64 MiB ring laps
in 5.4 ms at 100 Gb/s).

**Throughput to expect (P520).** rocelet reached **81.4 Gb/s** FPGA -> GPU ring on the P520 against
**97.7 Gb/s** into host memory (128 KB messages), with the same NIC, FPGA and cable. The NIC and the GPU
sit under different root ports (`NODE`): the NIC's peer writes go through the CPU's root complex as
64-byte TLPs, so the GPU's link carries ~1.38x the payload rate ((64 + 24) / 64) and its Gen3 x16
link is full at ~10 GB/s of payload. So expect **<= ~81 Gb/s** into the GPU on this host. Under PCIe back
pressure the ConnectX delays its ACKs, and rocelet's 256 KB retransmit ring then limits the
data in flight; keep messages <= 128 KB (half the
ring). A host with NIC and GPU behind one switch, or a Gen4/5 GPU slot, lifts the limit.

**Reading the limit while a run is going.**

| Command | What it shows | P520 at the GPU limit |
|---|---|---|
| `nvidia-smi dmon -s t -i 0` | `rxpci` / `txpci` MB/s of the GPU link | `rxpci` ~1.38x the payload rate (~14 GB/s at 81 Gb/s) |
| `ethtool -S enp179s0f0np0 \| grep outbound_pci_stalled_wr` (every few seconds) | `outbound_pci_stalled_wr`: % of the last second the NIC had posted writes it could not send (no PCIe credits) | 72 % into the GPU; 0 into host memory |
| `ethtool -S ... \| grep -E 'rx_discards_phy\|rx_out_of_buffer\|pause_ctrl'` | whether the NIC dropped or paused instead | 0 (it delays ACKs instead) |
| rocelet's `WR_OUTSTANDING` register (a status, not a counter), in the qsfp28-fmc-rocelet design also the producer's "IQ waits" in the console's `hsb st` line; `nvidia-smi -q -d MEMORY` (BAR1) | the FPGA side of the back pressure: `WR_OUTSTANDING` sits at its maximum (the requester's window is full while the NIC delays its ACKs) and "IQ waits" counts the cycles the producer waited for the engine; BAR1 in use | BAR1 ~244 / 256 MiB with a 240 MiB ring |

## 10. Link flaps and cable pulls

**FPGA as requester (FPGA -> host).** rocelet v0.2 holds its ACK timeouts while the link is
down (`link_up` input = the CMAC's `stat_rx_aligned` with no local / remote fault, wired by the
design) and for `LINK_GRACE` after it is back. Nothing is retransmitted by the timer meanwhile
and no retry is used; when the grace ends, every QP with an overdue ACK retransmits its window
once (go-back-N) and continues. The outage a stream survives is then unlimited on the FPGA side
(ConnectX-6 Dx: v0.2.0 survived a 35.6 s DAC pull and forced drops of 5-60 s, v0.2.2 at its
defaults a 14.9 s pull, resumed 1.9 s after the ConnectX-6 carrier returned, with 1 timeout;
0 lost / duplicate messages in every run). `CNT_LINK_DOWN`, `STATUS.LINK_UP` / `TIMER_HOLD` show what happened. See
[integration.md](integration.md) section 9.

Why the defaults are `ACK_TIMEOUT` **5 ms** (since v0.2.1; v0.2.0 had 1 ms) and `LINK_GRACE`
**2 s** (since v0.2.2; v0.2.0 had 3 s, v0.2.1 6 s):

- **5 ms ACK timeout.** A cable pull or a link partner power loss removes the FPGA's RX signal at
  once, so the hold covers it from the first microsecond. A host that takes its port down
  administratively (an ethtool speed / FEC change, `mlxlink`, possibly a driver reload or
  firmware reset) is different: a ConnectX-6 with `KEEP_ETH_LINK_UP` set (the mlxconfig default)
  stops answering **15-25 ms before** the FPGA loses alignment, because its PHY keeps sending a
  valid signal for a while. Those milliseconds are counted as ordinary ACK timeouts; at 1 ms x 8
  tries the QP died at the start of every such drop, at 5 ms (8 x 5 = 40 ms) it used 3-4 tries
  and survived. If `link_up` includes the CMAC's remote fault, the hold may engage earlier, but
  the 5 ms budget does not rely on it.
- **2 s grace.** With `link_up` = aligned and no local / remote fault (the recommended wiring),
  the hold engages within one ACK timeout of a drop, through the fault terms even when the host
  goes silent before the FPGA loses alignment, and it ends only when the partner's own link is
  up: the remote fault clears when the partner receives the FPGA's signal. On the ConnectX-6 Dx
  the carrier returned 4.4-5.6 s after a CMAC reset from the FPGA, and rocelet's `link_up` rose
  within 0.22 s of it, so the grace now starts at the partner's link-up, not at alignment. With
  that, grace 0, 1 s and 3 s all survived 5 s forced drops at 5 ms x 8 (1, 1 and 5 of 8 tries
  used; resume = partner carrier + grace). 2 s keeps margin for a partner whose port is up
  before its RDMA stack answers. v0.2.1's 6 s was chosen when the grace still started at
  alignment (`link_up` = `stat_rx_aligned` alone: the ConnectX-6 reported its link 2.4-2.9 s
  after the FPGA, 5.1-5.4 s after an FPGA-side relink); with the fault terms it was ~6 s of dead
  time per link loss. A design that drives `link_up` from `stat_rx_aligned` alone should raise
  `LINK_GRACE` to ~6 s.
- **The cost.** A lost last packet or a lost ACK (no NAK follows) is detected after 5 ms instead
  of 1 ms. After a link blip with data in flight the requester waits up to the 2 s grace after
  the partner's link-up before it retransmits, unless a NAK (sequence error) from the host
  arrives first, which restarts the window at once; traffic in flight when the link returns
  completes normally without waiting. Lower `LINK_GRACE` for a partner that answers as soon as
  its link is up, raise it (up to 16.7 s) for a slower one.
- **`CNT_LINK_DOWN` counts fault toggles.** Each fall of `link_up` counts, and the fault bits
  toggle while a link comes up, so one physical event usually counts more than once (ConnectX-6
  Dx: +2 per CMAC reset, +3 per forced drop, against +1 on the CMAC's own counter).

Without the `link_up` wiring (v0.1 behaviour) the budget is (`RETRY_CNT` + 1) x `ACK_TIMEOUT`:
8 x 5 ms at reset, so any real link drop is fatal (retry exceeded, code 0xFF). Stretching the
timer tick (`TICK_DIV` up to 1023 clocks per tick, with `ACK_TIMEOUT` 0xFFFFF: 3.33 s per
timeout, 26.6 s budget) survived a 13.9 s pull on the ConnectX-6 bench and failed a 23.65 s one. It is a
**stopgap knob only**, not a default: it also stretches the RNR wait limits (`RNR_MIN` /
`RNR_MAX`) and makes every real loss (a dropped last packet, a NAK that did not arrive) wait
seconds instead of milliseconds.

**Host as requester (host -> FPGA WRITE / SEND, and host READs).** The host QP's own
`timeout` and `retry_cnt` govern it: mlx5 honours them (budget about (retry_cnt + 1) x 4.096 µs x
2^timeout); some drivers ignore `timeout`. For links that can drop, use a large `timeout` on the host
(18-20: 1.07-4.3 s per try) and expect host -> FPGA traffic to resume only at the host's next retry after its link
is back, i.e. up to one host timeout (4.3 s at 20) after the outage at the NIC ends. The host application must not give up while the port
is down (`rocelet_host` waits for `IBV_EVENT_PORT_ACTIVE`, see `--link-grace` /
`--link-down-max` in host/README.md).
