# Changelog

All notable changes to rocelet. Versions follow semantic versioning; `-dev` versions are work in
progress on the `dev` branch, releases are on `main` and tagged.

## v0.2.2 (2026-10-31)

First release. It collects the development versions v0.2.0-dev and v0.2.1-dev (their entries
below have the details and the measurements behind each change) and the shorter link grace
from the ConnectX-6 Dx check of v0.2.1 (stream 5c), on top of v0.1.0-dev. `VERSION` reads 0.2.2 (register 0x004 = 0x00000202). The `link_up` port is new
since v0.1.0-dev; no other port or parameter changed.

### Validated on

KCU116 + Opsero 2x QSFP28 FMC (OP120) port 0 in the qsfp28-fmc-rocelet reference design,
3 m passive QSFP28 DAC to an **NVIDIA ConnectX-6 Dx** (firmware 22.43.2566, inbox mlx5 and
rdma-core, Ubuntu 24.04, Linux 6.8), 100G RS-FEC, MTU 4200: FPGA WRITE with immediate into host
memory 98.01 Gb/s, host WRITE into FPGA memory 96.79 Gb/s, host READ of FPGA memory
96.59 Gb/s (`max_rd_atomic` 16 with READ-response loss), go-back-N after a dropped last
packet in 5.0 ms, and link loss at the default settings: a **real cable pull** (14.9 s outage
with a 40 Gb/s stream in flight: resume 1.9 s after the ConnectX-6 carrier returned, 1 timeout,
8.85 M messages with 0 lost / duplicate / corrupt, both QPs alive) and forced 5 s / 30 s
drops (1 timeout each, resume 1.8 / 2.0 s after the carrier). Into GPU memory (dma-buf, RTX PRO
4000 on a Lenovo P520) the rate is limited by that host's NIC-to-GPU path, about 81 Gb/s. The
regression (`make sim`) passes 15/15. Before the ConnectX-6 Dx arrived, the v0.1 interop
ran against the development host's NIC (see v0.1.0-dev); that NIC is not part of the release
validation.

### Fixed

- **R1, READ depth** (v0.2.0-dev): `READ_DEPTH` counts new READs only. Duplicate READs that a
  ConnectX-6 Dx re-issues after READ-response loss are re-executed without a READ resource;
  before, a legitimate new READ could be NAKed (0x61) and the host QP died with
  `max_rd_atomic` = `READ_DEPTH` = 16.

### Added

- **R2, ACK-timeout hold on link loss** (v0.2.0-dev): input port `link_up`; while it is low
  and for `LINK_GRACE` (register 0x070) after it rises, the requester counts no ACK timeout; a
  QP whose ACK became overdue times out once when the hold ends. A cable pull of any length is
  survived on the FPGA side. `STATUS.LINK_UP` [5], `STATUS.TIMER_HOLD` [6], counter
  `CNT_LINK_DOWN` (index 49). `link_up` tied to 0 or 1 keeps the v0.1 behaviour.
- **GPU ring in `rocelet_host`** (`--mem gpu`, `make CUDA=1`): sink into GPU memory through a
  dma-buf (no nvidia-peermem), registered at IOVA 0 (Holoscan Sensor Bridge convention),
  checked by a CUDA kernel; `selftest-gpu`.
- **Documentation site:** the `docs/` pages build with Sphinx (`make docs`; `.readthedocs.yaml`,
  `docs/conf.py`, `docs/index.md`) and are hosted at https://rocelet.ethernetfmc.com.

### Changed

- **Defaults: `ACK_TIMEOUT` 5 ms** (was 1 ms; v0.2.1-dev). A ConnectX-6 that takes its port
  down administratively stops answering 15-25 ms before the FPGA loses alignment, so the hold
  engages late; at 1 ms x 8 the QP died at the start of every such drop, at 5 ms it survives
  (and with the fault terms in `link_up` the hold engages within one timeout). Cost: a lost
  last packet / ACK without a NAK is detected after 5 ms.
- **Defaults: `LINK_GRACE` 2 s** (2,000,000 ticks = 0x1E8480; 3 s in v0.2.0-dev, 6 s in
  v0.2.1-dev). With the recommended `link_up` the hold engages within one ACK timeout of a drop
  and the grace starts only when the partner's link is up (its remote fault clears): the
  ConnectX-6 Dx carrier returned 4.4-5.6 s after a CMAC reset and rocelet's `link_up` rose
  within 0.22 s of it. Grace 0 / 1 s / 3 s all survived 5 s forced drops at 5 ms x 8 (1 / 1 / 5
  timeouts, 0 lost / duplicate); 2 s keeps margin for partners whose port goes up before their
  RDMA stack answers. Cost: ~2 s of extra stall per link loss with data in flight (6 s with
  v0.2.1-dev). docs: host-setup.md section 10 (why 2 s, the cost, `CNT_LINK_DOWN` counts fault
  toggles), integration.md section 9, interface.md change log.
- **`link_up` recommendation**: `stat_rx_aligned & ~stat_rx_local_fault &
  ~stat_rx_remote_fault` (integration.md section 9). A design that drives `link_up` from
  `stat_rx_aligned` alone should raise `LINK_GRACE` to ~6,000,000 itself (its grace starts at
  alignment, before the partner is up).

### Host tools (`host/`, rocelet_host 0.2.1)

- `--dev` defaults to the first RDMA device present (`run`, `info`, `counters`; was the fixed
  device name of the development host); with several devices the choice is printed.
- Link-aware sink: a port error no longer ends the run; the silence timer is held while the
  port is down and for `--link-grace` after it returns, the run fails only after
  `--link-down-max`; the summary prints the port-down events and the longest outage.
- mlx5 watch list of the counters a ConnectX-6 Dx really has (`roce_adp_retrans`,
  `roce_slow_restart`, CNP, CQE and remote access errors).
- The sink fails on missing messages (exit 4, exit 5 when none arrived).
- GPU ring, see Added.

### Integration changes (designs using rocelet)

- Connect `link_up` (recommended form above); without it the v0.1 behaviour stays.
- Firmware that writes its own `ACK_TIMEOUT` / `LINK_GRACE` should follow the new defaults
  (5000 µs, 2,000,000 ticks); `LINK_GRACE` is 24 bits, `ACK_TIMEOUT` 20 bits.
- `sw/rocelet_regs.h` has the new status bits and counter name; show `STATUS[6:5]` and
  `CNT_LINK_DOWN` if the console has a status command.

## v0.2.1-dev (2026-10-30)

New link-loss defaults from the ConnectX-6 Dx re-validation of v0.2.0 (stream 5, session B).
`VERSION` reads 0.2.1. No port, parameter or logic change.

### Changed

- **`ACK_TIMEOUT` reset 1 ms -> 5 ms** (0x3E8 -> 0x1388). A ConnectX-6 that takes its port
  down administratively (ethtool speed / FEC change; `KEEP_ETH_LINK_UP` set) stops answering
  15-25 ms before the FPGA loses alignment, so the `link_up` hold engages late; at 1 ms x 8 the QP
  died at the start of every such drop (forced-50G drops of 5-60 s), at 5 ms it used 3-4 tries
  and survived. Cable pulls were already held from the first microsecond (35.6 s pull PASS at
  1 ms). Cost: a lost last packet / ACK without a NAK is detected after 5 ms instead of 1 ms.
- **`LINK_GRACE` reset 3 s -> 6 s** (3,000,000 -> 6,000,000 ticks). The ConnectX-6 reports its
  link 2.4-2.9 s after the FPGA's (margin 0.1-0.6 s with 3 s) and 5.1-5.4 s after an
  FPGA-side relink (CMAC reset from the FPGA), which 3 s did not cover. Cost: after a link blip a
  QP whose ACKs were lost waits up to 6 s unless a NAK arrives first.
- docs: `link_up` recommendation is now
  `stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault` (integration.md section 9,
  interface.md): a fault means the peer is not receiving / not transmitting, so the timer should
  hold then too; fault toggles at link-up are covered by `LINK_GRACE`. host-setup.md section 10
  explains both defaults and their cost.

### Integration changes (designs using rocelet)

- Optional: drive `link_up` from aligned and no local / remote fault (see above).
- Firmware that writes its own `ACK_TIMEOUT` / `LINK_GRACE` values should follow the new
  defaults (5000 µs, 6,000,000 ticks) unless it has a reason not to; `LINK_GRACE` is 24 bits
  (values above 16,777,215 are truncated by the register).

## v0.2.0-dev (2026-10-30)

Two fixes from the first ConnectX-6 Dx hardware run (stream 4). `VERSION` reads 0.2.0.

### Fixed

- **READ_DEPTH counted re-executed duplicate READs** (responder). With the host's
  `max_rd_atomic` = `READ_DEPTH` = 16 and READ-response loss, a ConnectX-6 Dx re-issues the
  tail of the READ (and some later outstanding READs) within microseconds and completes some
  of them from the stale responses still in flight; rocelet still counted the queued
  re-executions as outstanding and NAKed a legitimate new READ with 0x61 (invalid request),
  which killed the host QP (`max_rd_atomic` 8 was the workaround). Only new READs take a READ
  resource now; duplicates are re-executed (whole, or as a continuation) without one.
  New regression test `read_reissue` (closed-loop requester model with response loss, ConnectX
  fast re-issue and re-issue after a timeout, READ_DEPTH 16 / 8 / 1); it fails on v0.1.

### Added

- **ACK-timeout hold on link loss**: new input port `link_up` (CMAC `stat_rx_aligned`, also on
  `rocelet_bd.v`). While it is low, and for `LINK_GRACE` timer ticks after it rises (new
  register 0x070, reset 3,000,000 = 3 s, for the link partner's slower link-up), the
  requester counts no ACK timeout and the timer starts no retransmission; a QP whose ACK became
  overdue meanwhile times out at once when the hold ends (one go-back-N, retry + 1). A cable
  pull of any length is survived on the FPGA side; before, (`RETRY_CNT` + 1) x `ACK_TIMEOUT` (8 ms at
  reset, at most 26.6 s with `TICK_DIV` 1023) was the limit. The RNR wait is not held. The hold
  is armed only after `link_up` was 1 once since reset, so `link_up` tied to 0 or 1 (or left
  unconnected in a block design) keeps the v0.1 behaviour. `ACK_TIMEOUT` (1 ms) and `TICK_DIV`
  are unchanged.
- `STATUS.LINK_UP` [5], `STATUS.TIMER_HOLD` [6], counter `CNT_LINK_DOWN` (index 49).
- Regression test `link_down`: a WRITE-with-immediate stream, the link down for 1.2 M ticks
  (longer than the 20-bit tick counter wraps) and the partner silent in the grace: no timeout
  while held, one per QP when the grace ends, nothing lost or duplicated; the control without
  the hold fails with retry exceeded.
- docs: host-setup.md "Link flaps and cable pulls" (the hold, the host's `timeout` /
  `retry_cnt`, `TICK_DIV` as a stopgap knob only), integration.md section 9 and the `link_up`
  wiring, ConnectX-6 READ facts (continuation required).

### Host tools (`host/`, rocelet_host 0.2.0)

- **GPU ring** (`--mem gpu`, `make CUDA=1`): `sink --op write|write_imm` into GPU memory via
  dma-buf (`cudaMalloc` -> `cuMemGetHandleForAddressRange` -> `ibv_reg_dmabuf_mr`; inbox rdma-core
  and mlx5, NVIDIA open kernel module, no nvidia-peermem). Registered at **IOVA 0** by default
  (Holoscan Sensor Bridge convention: RLHM `va=` = ring offset), `--gpu-iova dev` for the device
  address. Ring capped at BAR1 - 16 MiB (240 MiB on a 256 MiB BAR1, refused with a message
  above); `--buf-size max`. A CUDA verify kernel checks every 64-byte beat of each WRITE+imm
  message against the payload pattern in batches (64 / 200 µs) with in-order retire; the
  immediate sequence stays on the CPU; byte and error counts equal the CPU checker's. Bad beats
  are classified fill / misplaced / corrupt; `--gpu-scrub` refills checked messages so a lap that
  did not land is caught. Plain WRITE: end-of-run scan kernel. Back end, batching, build split
  and BAR1 handling adapted from an earlier Opsero host receiver (same copyright holder, MIT).
- `selftest-gpu`: the GPU path without NIC traffic (kernel = CPU reference on planted faults,
  scrub, scan, BAR1 cap refusal, dma-buf registration on `--dev` at both IOVAs, BAR1 use,
  throughput); `--mock` runs it on a mock back end.
- `make` without CUDA builds no CUDA code (`--mem gpu` stops with exit 2 and a message);
  `make test` adds `tests/test_gpu` (batching, back pressure, failures, references, scrub, cap)
  and `selftest-gpu --mock`; `make test-noscapy` skips the scapy tests.
- docs/host-setup.md section 9 "GPU ring": requirements, the IOVA decision, BAR1 math, the
  P520's ~81 Gb/s NIC -> GPU limit (97.75 into host memory) and how to read it.

### Integration changes (designs using rocelet)

- Connect `link_up` to the CMAC's `stat_rx_aligned` (otherwise the v0.1 behaviour stays).
- Firmware: nothing required (`LINK_GRACE` resets to 3 s); show `STATUS[6:5]` and
  `CNT_LINK_DOWN` if the console has a status command; the counter list in
  `sw/rocelet_regs.h` has one more name.

## v0.1.0-dev (2026-10-21)

First version of the IP, productised from Opsero's research prototype (validated in
simulation, through a QSFP28 loopback plug on a KCU116 and against the development host's NIC; the
prototype itself is not published).

### Engine (from the prototype)

- RoCE v2 over IPv4, 512-bit datapath, one clock domain (322.27 MHz CMAC user clock).
- RC requester: RDMA WRITE, WRITE with immediate, SEND, SEND with immediate, multi-packet;
  coalesced-ACK processing, go-back-N from a 256 KB URAM payload ring (`RTX_MODE` "RING") or by
  re-reading memory ("REREAD"); lossy resume ("LOSSY", experimental); ACK timeout, retry and RNR
  counters.
- RC responder: RDMA WRITE, WRITE with immediate, SEND, SEND with immediate, RDMA READ
  (`READ_DEPTH` per QP), duplicate / out-of-sequence handling (one NAK per gap), R_Key and
  bounds checks against `NUM_MR` memory windows, cut-through commit on a good ICRC.
- TX ICRC generation and RX ICRC check (IBTA A17), shared CRC network; CNPs counted and dropped.
- MAC glue: store-and-forward RX and TX FIFOs, classifier, ARP/ICMP responder, frame arbiter,
  802.1Q VID-0 tag removal and optional tagging, 802.3x PAUSE honoured and requested from the
  RX FIFO level.

### New in this version

- `rocelet_top` with a frozen port list (docs/interface.md): CMAC AXI-Stream and pause / RS-FEC
  status, other-traffic ports, work-request / completion AXI-Streams, responder SEND and
  receive-completion streams, AXI4 memory master, AXI4-Lite control, irq; `rocelet_bd.v`
  wrapper for IP integrator; `rocelet_core` for native memory ports.
- QP type per QP at run time: RC, UC, or UC in **Holoscan Sensor Bridge mode** (WRITE Only per
  packet with its own RETH, WRITE Only with Immediate {PSN[19:0], buffer[11:0]}, metadata PSN
  patch, MigReq 0), byte-identical to NVIDIA's HSB data-plane packets; per-QP UDP destination
  port.
- **READ continuation**: partial duplicate READs answered MIDDLE ... LAST (`CTRL.READ_CONT`,
  default on), as the development host's NIC required (the ConnectX-6 Dx does too); IBTA answer
  selectable.
- **RNR wait decoded from the AETH timer code** (IBTA table), clamped to `RNR_MIN` / `RNR_MAX`;
  20-bit microsecond timers; run-time `TICK_DIV`; IBTA retry_cnt / rnr_retry semantics
  (`RETRY`).
- **RNR NAK generation** for SENDs while `send_rnr[qp]` is high.
- QP error handling: errors flush the QP's outstanding work requests (completion status
  FLUSHED), forced error (`QP_ERR_CMD`), disabled QPs, per-QP error causes, `LOSS_FATAL`.
- Requester rate limiter (token bucket, `PACE_RATE` / `PACE_BURST`); AckReq every N packets
  at run time (`ACKREQ_N`).
- Receive completions carry the message length; duplicate READs are re-checked against the
  memory window.
- AXI4 memory master with 4 KB burst splitting, per-source read buffers and READ-after-WRITE
  ordering.
- AXI4-Lite register file generated from `regs/rocelet_regs.py` (RTL package, C header,
  docs/registers.md): configuration, staged QP and window tables, status, 49 event counters and
  64-bit cycle / byte counters. The CMAC's own statistics block is no longer needed.
- Back-pressure on the ACK processor's event queues; pipelined work-request retirement.
- Simulation regression (`make sim`), OOC synthesis scripts (`make synth`), host tools
  (`rocelet_host`, `roce_check.py`), documentation; MIT licence.

### Fixes after the first KCU116 hardware run

- `rocelet_host` sink: a WRITE-with-immediate or SEND sink with `--count` now fails when
  fewer messages arrive (exit 4, or 5 when none arrive even if the NIC's IPv4 counters
  moved); before, a stream that stopped early or was dropped by the NIC reported PASS.
- docs: the development host's NIC drops VID-0-tagged RoCE frames, so `CTRL.VLAN_TX_TAG` stays
  0 unless the host NIC is known to accept them (host-setup.md); the known tight timing path in
  the KCU116 design (integration.md section 8).
