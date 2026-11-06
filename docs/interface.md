# rocelet: top-level interface (`rocelet_top`)

**Status:** the interface of rocelet v0.3.0. Every change to a port or parameter name is listed
in the change log at the end of this file, with its date, and named in the commit message.

`rocelet_top` is the module a design instantiates (as a git submodule; source list
`rtl/rocelet.f`). Everything runs in **one clock**, `clk`, the MAC's user clock: 322.265625 MHz
for the 512-bit 100G CMAC (250 MHz also closes timing), 156.25 MHz for a 256-bit 40GBASE-R4 or a
64-bit 10GBASE-R MAC. There is no clock-domain crossing inside the IP. The engine is 512 bits
wide; `MAC_WIDTH` selects the width of the MAC AXI-Stream ports (64, 128, 256 or 512 bits), and
for a MAC narrower than 512 bits the width converters inside `rocelet_top` pack and unpack the
beats, so the MAC's AXI-Stream connects directly (see [MAC side](#mac-side)). The register map
behind `s_axil_*` is in [registers.md](registers.md) (generated from `regs/rocelet_regs.py`; C
header `sw/rocelet_regs.h`).

Byte order on every stream: byte *i* of a frame or payload is `tdata[8*i +: 8]` (byte 0 first
on the wire), `tkeep[i]` qualifies it; `tkeep` is contiguous from bit 0 on every beat, and every
beat of a frame but the last is full. All user ports other than the MAC ports are 512 bits
(64-byte beats) at every `MAC_WIDTH`.

## Parameters

| Parameter | Default | Range | Meaning |
|---|---|---|---|
| `NUM_QP` | 16 | 1-256 | queue pairs (local QPN = `QPN_BASE` + index) |
| `NUM_MR` | 16 | 1-64, power of 2 | memory windows (selected by R_Key low bits) |
| `QPN_BASE` | 24'h000100 | aligned to the next power of 2 >= `NUM_QP` | local QPN of QP 0 |
| `PMTU_RUNTIME` | 1 | 0/1 | 1: path MTU per QP at run time (256-4096); 0: every QP uses 2^`PMTU_LOG2` |
| `PMTU_LOG2` | 12 | 8-12 | the fixed PMTU when `PMTU_RUNTIME` = 0 |
| `READ_DEPTH` | 16 | 1, 2, 4, 8, 16 | outstanding RDMA READs per QP (responder); give the host exactly this value. Only new READs count; duplicate (re-issued) READs are re-executed without taking a slot |
| `RTX_MODE` | "RING" | "RING", "REREAD", "LOSSY" | requester retransmission: on-chip payload ring (go-back-N); payload re-read from memory through `m_axi` (go-back-N); lossy resume (no payload storage, experimental) |
| `RING_BYTES` | 262144 | 65536-2097152, power of 2 | retransmit ring size (`RTX_MODE` "RING") |
| `RING_RAM` | "ultra" | "ultra", "block" | ring memory type |
| `MAX_WR` | 128 | 16-256, power of 2 | outstanding work requests (the requester window) |
| `RX_ICRC_EN` | 1 | 0/1 | check the ICRC of received RoCE frames (0: rely on the Ethernet FCS) |
| `ICRC_SHARE` | 1 | 0/1 | CRC cores with one shared 512-bit data network (smaller) |
| `IPV6_EN` | 0 | 0/1 | IPv6 support (simulation-verified only; not part of v1) |
| `HSB_EN` | 1 | 0/1 | Holoscan Sensor Bridge builder mode (QP type 2) |
| `VLAN_EN` | 1 | 0/1 | 802.1Q VID-0 tag removal on RX and optional tagging on TX |
| `PAUSE_EN` | 1 | 0/1 | 802.3x PAUSE honoured (TX gate) and requested from the RX FIFO level |
| `ARP_EN` | 1 | 0/1 | built-in ARP and ICMP-echo responder |
| `OTHER_EN` | 1 | 0/1 | the other-traffic ports (non-RoCE frames to/from a CPU or NIC stack) |
| `COUNTERS_EN` | 1 | 0/1 | the statistics counters of the register map |
| `RX_FIFO_DEPTH` | 512 | 128-4096, power of 2 | store-and-forward RX frame FIFO, 64-byte beats (512 = 32 KB) |
| `TX_FIFO_DEPTH` | 512 | 128-4096, power of 2 | store-and-forward TX frame FIFO, 64-byte beats |
| `OTHER_TX_FIFO_DEPTH` | 256 | 64-1024, power of 2 | store-and-forward FIFO on the other-traffic TX input |
| `M_AXI_ADDR_W` | 64 | 32-64 | memory master address width |
| `M_AXI_ID_W` | 2 | 1-8 | memory master ID width |
| `MEM_RD_BUF` | 256 | 128-1024, power of 2 | read-data buffer per read source, 64-byte beats (bounds the outstanding reads) |
| `CLK_MHZ` | 322 | 100-400 | engine clock in MHz, rounded: reset value of the `TICK_DIV` register (clock cycles per microsecond; 156 at 156.25 MHz, timers 0.16 % short) |
| `CLK_KHZ` | 0 | 0, 100000-400000 | engine clock in kHz for the exact figures (`CLK_KHZ` register, `PAUSE_QCLK` reset value): 322266 for the CMAC, 156250 for a 40G / 10G MAC; 0 = `CLK_MHZ` x 1000. Since v0.3 |
| `LINK_GBPS` | 100 | 1-255 | link speed in Gb/s: sets the reset value of `PAUSE_QCLK` (the length of a received PAUSE quantum, 512 bit times) and is reported in `CAPS`. Firmware can change `PAUSE_QCLK` for another speed. Since v0.3 |
| `MAC_WIDTH` | 512 | 64, 128, 256, 512 | width of the MAC AXI-Stream ports (`s_axis_rx_*`, `m_axis_tx_*`); below 512 the built-in width converters run between the MAC and the 512-bit engine. Reported in `CAPS`. Since v0.3 |
| `READ_CONT_DEFAULT` | 1 | 0/1 | reset value of `CTRL.READ_CONT` (partial READ re-issue answered as a continuation) |

## Ports

### Clock, reset, interrupt

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | engine clock = the MAC user clock (CMAC: `gt_txusrclk2`; omac: its user clock); the MAC RX and TX AXI-Streams must both be in it |
| `rst` | in | 1 | synchronous reset, active high (at least 4 cycles) |
| `irq` | out | 1 | level: a QP error is latched (`STATUS.ERR`) and `CTRL.IRQ_EN` = 1 |

### MAC side

Any Ethernet MAC whose RX and TX AXI-Streams run in one user clock (`clk`) connects here: the
100G CMAC (512 bits), the open-source omac IPs of `opsero-ethernet-mac` (`omac_40g` 256 bits,
`omac_10g` 64 bits, both at 156.25 MHz), or another MAC with the same AXI-Stream conventions.
Requirements on the MAC: the FCS is checked and stripped on RX (`tuser` flags a bad frame on its
last beat); the FCS is appended and short frames are padded to 60 bytes on TX; RX has no
`tready` (every beat is taken; `tvalid` may drop between beats); TX has `tready` and must not
see a gap inside a frame (rocelet never makes one); 802.3x PAUSE frames are parsed and sent by
the MAC (or PAUSE is unused, `PAUSE_EN` = 0 or `CTRL.PAUSE_RX_EN` / `PAUSE_TX_EN` = 0). If a
MAC delivers RX in another clock (a recovered clock), put an asynchronous FIFO at the MAC width
in front of `s_axis_rx_*`.

| Port | Dir | Width | Description |
|---|---|---|---|
| `mac_rx_reset` | in | 1 | the MAC's RX in reset (CMAC `usr_rx_reset`; synchronous to `clk`): the RX path discards the frame in progress; tie 0 if unused |
| `mac_tx_reset` | in | 1 | the MAC's TX in reset (CMAC `usr_tx_reset`): RX input held while high; tie 0 if unused |
| `mac_rx_status` | in | 1 | the MAC's RX status (CMAC `stat_rx_aligned`, omac `stat_block_lock`); status register only (`STATUS.MAC_RX_STATUS`). `mac_rx_aligned` before v0.3 |
| `link_up` | in | 1 | link state for the requester: RX aligned / block-locked and no local or remote fault (CMAC `stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault`, omac `stat_link_up`). While it is 0, and for `LINK_GRACE` timer ticks after it rises, the ACK timeouts are held (no timeout counted, no retransmission started by the timer); an ACK that became overdue meanwhile times out at once when the hold ends. Synchronised inside (may come from another clock). The hold is armed only after `link_up` has been 1 once since reset, so tied to 0 or 1 (or left unconnected in a block design, which ties it to 0) the ACK timeouts run without a link hold. Since v0.2 |
| `s_axis_rx_tdata` | in | `MAC_WIDTH` | MAC RX AXI-Stream (CMAC `rx_axis_*`); no `tready`: every beat is taken; `tvalid` gaps allowed |
| `s_axis_rx_tkeep` | in | `MAC_WIDTH`/8 | contiguous from bit 0; all ones except on the last beat |
| `s_axis_rx_tvalid` | in | 1 | |
| `s_axis_rx_tlast` | in | 1 | |
| `s_axis_rx_tuser` | in | 1 | bad frame (FCS error) on the last beat: the frame is dropped (narrow MACs: a flag on any beat of the frame counts) |
| `m_axis_tx_tdata` | out | `MAC_WIDTH` | MAC TX AXI-Stream (CMAC `tx_axis_*`); frames are store-and-forward, `tvalid` never drops inside a frame (also after the width converter) |
| `m_axis_tx_tkeep` | out | `MAC_WIDTH`/8 | |
| `m_axis_tx_tvalid` | out | 1 | |
| `m_axis_tx_tready` | in | 1 | |
| `m_axis_tx_tlast` | out | 1 | |
| `m_axis_tx_tuser` | out | 1 | always 0 |
| `mac_pause_hold` | in | 1 | level: a received PAUSE is in force, the MAC times the quanta itself (omac `stat_rx_pause_req`; CMAC `stat_rx_pause_req[8]`). Holds the engine's TX while `CTRL.PAUSE_RX_LEVEL` = 1. Tie 0 if unused |
| `mac_pause_valid` | in | 1 | a received global PAUSE, pulse or level (CMAC `stat_rx_pause_valid[8]`): loads the TX pause timer with `mac_pause_quanta` x `PAUSE_QCLK` / 256 clocks; quanta 0 (XON) clears it. Tie 0 for a MAC that reports a level only |
| `mac_pause_quanta` | in | 16 | quanta of the received PAUSE (CMAC `stat_rx_pause_quanta8`) |
| `mac_pause_req` | out | 1 | level: send PAUSE (XOFF, refreshed by the MAC) while high, XON when it drops; raised when the RX FIFO reaches `PAUSE_WM.XOFF`, released at `XON`, each level held >= 32 clocks (CMAC `ctl_tx_pause_req[8]`, omac `ctl_tx_pause_send`) |
| `mac_pause_rx_frame` | in | 1 | one pulse per PAUSE frame received (CMAC `stat_rx_pause`; counter `CNT_PAUSE_RX` only); tie 0 if unused |
| `mac_pause_tx_frame` | in | 1 | one pulse per PAUSE frame sent (CMAC `stat_tx_pause`; counter only); tie 0 if unused |
| `mac_fec_corr_inc` | in | 1 | FEC corrected codeword (CMAC `stat_rx_rsfec_corrected_cw_inc`; counter only); tie 0 without FEC |
| `mac_fec_uncorr_inc` | in | 1 | FEC uncorrectable codeword (CMAC `stat_rx_rsfec_uncorrected_cw_inc`; counter only); tie 0 without FEC |

With `PAUSE_EN` = 0, `mac_pause_req` is 0 and the pause inputs are ignored. Static MAC
configuration (enables, FEC, loopback, PAUSE frame quanta / refresh, the CMAC's `ctl_*` bus)
and MAC statistics stay in the design, next to the MAC: rocelet has no MAC configuration
port.

#### Mapping (v0.2 CMAC port -> v0.3)

| v0.2.x port | v0.3 port | CMAC connection |
|---|---|---|
| `mac_rx_aligned` | `mac_rx_status` | `stat_rx_aligned` |
| `stat_rx_pause_req` [8:0] | `mac_pause_hold` | `stat_rx_pause_req[8]` (used with `CTRL.PAUSE_RX_LEVEL`) |
| `stat_rx_pause_valid` [8:0] | `mac_pause_valid` | `stat_rx_pause_valid[8]` |
| `stat_rx_pause_quanta8` | `mac_pause_quanta` | `stat_rx_pause_quanta8` |
| `stat_rx_pause` | `mac_pause_rx_frame` | `stat_rx_pause` |
| `stat_tx_pause` | `mac_pause_tx_frame` | `stat_tx_pause` |
| `ctl_tx_pause_req` [8:0] | `mac_pause_req` | `ctl_tx_pause_req = {mac_pause_req, 8'd0}` |
| `stat_rx_rsfec_corrected_cw_inc` | `mac_fec_corr_inc` | same signal |
| `stat_rx_rsfec_uncorrected_cw_inc` | `mac_fec_uncorr_inc` | same signal |

For an omac IP ([opsero-ethernet-mac interface contract](https://omac.ethernetfmc.com/en/latest/interface.html), user side): `link_up` <-
`stat_link_up`, `mac_rx_status` <- `stat_block_lock`, `mac_pause_hold` <- `stat_rx_pause_req`
(the IP's PAUSE timer level) with `CTRL.PAUSE_RX_LEVEL` = 1 (firmware sets it) and the IP's
`ctl_pause_tx_honour` = 0, `mac_pause_valid` = 0, `ctl_tx_pause_send` <- `mac_pause_req` (its
XOFF quanta / refresh in `ctl_tx_pause_quanta` / `ctl_tx_pause_refresh`), `mac_pause_rx_frame`
<- `ev_rx_pause`, `mac_pause_tx_frame` <- `ev_tx_pause`, `mac_rx_reset` / `mac_tx_reset` = 0
(the IP's `rst` covers both), FEC inputs 0. Its RX stream has occasional single-cycle `tvalid`
gaps (clock crossing) and `tuser` on the last beat; both are handled.

#### MAC width and throughput

The engine works on 512-bit (64-byte) beats at `clk` whatever the MAC width, so its frame rate
per clock is the same as at 100G; what changes is the clock and the line rate.

| MAC | `MAC_WIDTH` | `clk` | MAC beats | engine capacity (raw, each way) | line rate | headroom |
|---|---|---|---|---|---|---|
| 100G CMAC | 512 | 322.27 MHz | 1 per clock | 165 Gb/s | 100 Gb/s | 1.65x |
| 40GBASE-R4 (omac_40g) | 256 | 156.25 MHz | 1 per clock | 80 Gb/s | 40 Gb/s | 2x |
| 10GBASE-R (omac_10g) | 64 | 156.25 MHz | 1 per clock | 80 Gb/s | 10 Gb/s | 8x |
| 25GBASE-R (omac_10g at 25G) | 64 | 390.625 MHz | 1 per clock | 200 Gb/s | 25 Gb/s | 8x |

- RX: the packer emits one 512-bit beat per 2 (256 bits) or 8 (64 bits) MAC beats, so the engine
  sees `tvalid` gaps; the per-frame engine costs (2 clocks of parser classification, the ICRC and
  VLAN stages) are paid once per frame at the 512-bit rate. Host WRITE at PMTU 4096 needs 65 + 2
  clocks per frame at 156.25 MHz: about 76 Gb/s of payload capacity, against about 39 Gb/s on a
  40G link.
- TX: one 512-bit beat leaves as 2 or 8 MAC beats without a gap; the engine side waits on
  `tready`, as it does at 100G behind the CMAC (whose clock outruns the line too).
- **READ responses are the tight case at 40G**, because each READ response carries a fixed
  per-packet cost on top of its data beats. Measured on the ZCU106 against a ConnectX-6 Dx, host
  READ of FPGA memory still runs at 40G line rate at PMTU 4096, 1024 and 512 (38.7, 37.0 and
  34.4 Gb/s of payload); PMTU 256 was not measured. At 10G every operation has several times the line rate
  in hand. All measured rates per MAC width: [](throughput.md).
- Latency in clocks is unchanged (plus 1 clock in each converter and up to 7 clocks of packing at
  64 bits); in nanoseconds it scales with 1 / `clk` (2.06x from 322.27 to 156.25 MHz), plus the
  serialisation time of the slower link.
- The register units that count clocks or 512-bit beats keep their meaning: `PAUSE_WM`, the FIFO
  levels and `RING_USED` are in 64-byte beats; `TICK_DIV` is clocks per microsecond (156 at
  156.25 MHz); `PACE_RATE` is credit per clock in 1/256 byte (`INC` = rate / 8 / f_clk x 256: 8192
  for 40 Gb/s and 2048 for 10 Gb/s at 156.25 MHz, 9930 for 100 Gb/s at 322.27 MHz);
  `PAUSE_QCLK` is the received PAUSE quantum in clocks x 256 (512 at 40G, 2048 at 10G, 423 at
  100G).

#### Timers at 156.25 MHz

The microsecond timer ticks every `TICK_DIV` clocks. `TICK_DIV` is an integer, so at
156.25 MHz the 156 of the reset value (`CLK_MHZ` 156) makes a tick 0.998 us: `ACK_TIMEOUT`,
`RNR_MIN` / `RNR_MAX`, `LINK_GRACE` and the decoded RNR wait run 0.16 % short (5 ms becomes
4.992 ms), which is irrelevant for those timers; firmware may write 156 or 157 as it likes. The
ACK-timeout scanner needs about 3 clocks per QP (16 QPs in about 0.3 us, 256 in about 5 us at
156.25 MHz, against 2.4 us at 322 MHz), small against millisecond timeouts. The received-PAUSE timer does not use the tick: it
counts `PAUSE_QCLK` / 256 clocks per quantum (`PAUSE_QCLK` is 20 bits, clocks x 256: 12.8 fixed
point, rounded up from `CLK_KHZ` and `LINK_GBPS`), so it is exact to 0.2 % at every speed (checked in simulation at 10G, 25G, 40G and
100G, `sim/test_pause.py`).

### Capabilities (registers 0x000-0x01C)

Firmware, daemons and host tools discover a build from the read-only block at the start of the
register map: `ID` ("RCLT"), `VERSION`, `BUILD0` (NUM_QP, NUM_MR, READ_DEPTH, RTX_MODE and the
feature enables, among them HSB_EN), `BUILD1` (RING_BYTES in KB, MAX_WR, PMTU_LOG2), `BUILD2`
(QPN_BASE), `BUILD3` (RX / TX FIFO depths), **`CAPS`** (MAC_WIDTH in bits, LINK_GBPS; since
v0.3) and **`CLK_KHZ`** (the engine clock; since v0.3). Builds before v0.3 read 0 at 0x018 and
0x01C. Firmware converts clock counts with `CLK_KHZ` (latency probes, rate limits, the HSB
producer period) instead of a compile-time constant.

### Other traffic (non-RoCE frames)

Frames that are not RoCE (UDP port 4791) and not answered internally (ARP/ICMP with
`CTRL.ARP_INT` = 1) leave on `m_axis_other_*` when `CTRL.OTHER_RX_EN` = 1 (they are dropped
otherwise; the port then stays idle). Frames on `s_axis_other_*` are sent to the MAC; they may
arrive with gaps (an `OTHER_TX_FIFO_DEPTH`-beat store-and-forward FIFO is inside) and must be
shorter than that FIFO. With `OTHER_EN` = 0 the ports are present but unused.

| Port | Dir | Width | Description |
|---|---|---|---|
| `m_axis_other_tdata` | out | 512 | received non-RoCE Ethernet frames (no FCS) |
| `m_axis_other_tkeep` | out | 64 | |
| `m_axis_other_tvalid` | out | 1 | |
| `m_axis_other_tready` | in | 1 | tie 1 if unused |
| `m_axis_other_tlast` | out | 1 | |
| `s_axis_other_tdata` | in | 512 | Ethernet frames to send (no FCS; the MAC appends it) |
| `s_axis_other_tkeep` | in | 64 | |
| `s_axis_other_tvalid` | in | 1 | tie 0 if unused |
| `s_axis_other_tready` | out | 1 | |
| `s_axis_other_tlast` | in | 1 | |

### Work requests (requester: FPGA → host)

A work request (WR) is one 256-bit beat on `s_axis_wr`. With `RTX_MODE` "RING" or "LOSSY" its
payload follows on `s_axis_wr_data`: ceil(length / 64) beats, the WR's bytes from lane 0 of the
first beat, `tlast` on the last beat (zero-length WRs have no payload beats). With "RING" a WR
is forwarded once all of its payload is in the retransmit ring, so a WR must not be longer than
`RING_BYTES` (keep WRs well below it for streaming). With "REREAD" the engine reads the payload
itself through `m_axi` from the WR's local address; `s_axis_wr_data` is unused. "LOSSY" WRs
should not be longer than the QP's PMTU (a host NIC may not resume inside a message). Each WR
produces exactly one work completion on `m_axis_wc`, in WR order.

WR descriptor (`s_axis_wr_tdata`):

| Bits | Field | Description |
|---|---|---|
| [7:0] | `qp` | QP index (< `NUM_QP`) |
| [11:8] | `opcode` | 0 RDMA WRITE, 1 RDMA WRITE with immediate, 2 SEND, 3 SEND with immediate; only bits [9:8] are decoded, keep [11:10] at 0 |
| [12] | `se` | solicited event on the last packet (SEND, WRITE with immediate) |
| [13] | `hsb_md` | HSB QPs: this WR is an HSB metadata record; bytes 4-7 of the packet that carries the immediate are replaced by {0x00, PSN[23:0]} (big-endian) |
| [15:14] | - | reserved, 0 |
| [31:16] | `wr_id` | returned in the completion |
| [63:32] | `length` | bytes (0 allowed) |
| [127:64] | `remote_va` | remote virtual address (WRITE) |
| [159:128] | `rkey` | remote key (WRITE) |
| [191:160] | `imm` | immediate data (big-endian on the wire as given); HSB QPs: [11:0] = buffer (page) index, [31:12] are replaced by PSN[19:0] |
| [255:192] | `local_addr` | "REREAD" only: `m_axi` address of the payload, 64-byte aligned |

| Port | Dir | Width | Description |
|---|---|---|---|
| `s_axis_wr_tdata` | in | 256 | WR descriptor |
| `s_axis_wr_tvalid` | in | 1 | |
| `s_axis_wr_tready` | out | 1 | low while the window (`MAX_WR`) or the ring is full |
| `s_axis_wr_data_tdata` | in | 512 | WR payload |
| `s_axis_wr_data_tvalid` | in | 1 | |
| `s_axis_wr_data_tready` | out | 1 | |
| `s_axis_wr_data_tlast` | in | 1 | last beat of a WR's payload (checked: `CNT_WR_DATA_ERR`) |
| `m_axis_wc_tdata` | out | 64 | work completion, see below |
| `m_axis_wc_tvalid` | out | 1 | |
| `m_axis_wc_tready` | in | 1 | tie 1 if completions are not needed |

Work completion (`m_axis_wc_tdata`): [15:0] `wr_id`, [23:16] `qp`, [31:24] `status`
(0x00 success: every packet acknowledged, or sent for UC; 0x01 lost: "LOSSY" mode dropped data
of this WR; 0x02 flushed: the QP was in the error state), [63:32] reserved (0).

QP types (`QP_FLAGS.TYPE`): RC (reliable, ACKed, go-back-N), UC (unreliable: FIRST/MIDDLE/LAST
opcodes, completion when sent), and **UC-HSB** (`HSB_EN`): every packet is a UC RDMA WRITE Only
(0x2A) with its own RETH (VA advanced per packet, DMA length = that packet), the last packet of a
WRITE-with-immediate WR is WRITE Only with Immediate (0x2B) carrying {PSN[19:0], imm[11:0]};
AckReq 0, MigReq 0, P_Key 0xFFFF, as NVIDIA's HSB IP sends them. SEND opcodes on an HSB QP are
sent as plain UC SENDs.

### Responder (host → FPGA)

RDMA WRITE payload goes to memory through `m_axi` (cut-through: a packet whose ICRC turns out
bad has already been written and is overwritten by the host's retransmission). SEND payload goes
to `m_axis_send`, one packet at a time; after each packet's last beat `send_commit_valid` pulses
with `send_commit_ok` = 1 (keep the packet) or 0 (discard it: bad ICRC; the host retransmits).
RDMA READ data is read from memory through `m_axi`.

| Port | Dir | Width | Description |
|---|---|---|---|
| `m_axis_send_tdata` | out | 512 | SEND payload, packet by packet |
| `m_axis_send_tkeep` | out | 64 | |
| `m_axis_send_tvalid` | out | 1 | |
| `m_axis_send_tready` | in | 1 | back-pressure stalls the whole receive path (then PAUSE) |
| `m_axis_send_tlast` | out | 1 | last beat of a packet |
| `m_axis_send_tuser` | out | 16 | [7:0] QP index, [8] first packet of a message, [9] last packet of a message |
| `send_commit_valid` | out | 1 | one pulse per SEND packet with payload, after its last beat |
| `send_commit_ok` | out | 1 | 1 = commit the packet, 0 = discard it |
| `send_rnr` | in | `NUM_QP` | bit q = 1: no receive buffer on QP q; a SEND FIRST/ONLY arriving on it is answered with an RNR NAK (timer code `RNR_NAK_TIMER`) and dropped. Tie 0 if unused |
| `m_axis_rc_tdata` | out | 128 | receive completion (SEND and WRITE with immediate, at the last packet of the message): [31:0] immediate, [63:32] message length in bytes, [71:64] QP index, [72] 1 = SEND (0 = WRITE with immediate), [73] immediate present, [127:74] 0 |
| `m_axis_rc_tvalid` | out | 1 | |
| `m_axis_rc_tready` | in | 1 | back-pressure stalls the receive path; tie 1 if unused |

### Memory (AXI4 master, `m_axi`)

512-bit AXI4 master used for: responder WRITE data (write channel, `AWID` 0), RDMA READ
responses (read channel, `ARID` 0) and, with `RTX_MODE` "REREAD", requester payload (read
channel, `ARID` 1). Bursts are INCR, `AxSIZE` = 6 (64 bytes), at most 64 beats, never across a
4 KB boundary; addresses are 64-byte aligned (memory windows and REREAD local addresses must be
64-byte aligned), `WSTRB` follows the payload's byte count on the last beat. A READ is issued only
after every earlier write has been acknowledged (B channel), so READ-after-WRITE on a QP returns
the written data. Read data is buffered per source (`MEM_RD_BUF` beats); the master never stalls
`RREADY` waiting for the other source. `AxCACHE` = 0011, `AxPROT` = 000, `AxLOCK` = 0.

| Port | Dir | Width |
|---|---|---|
| `m_axi_awid` | out | `M_AXI_ID_W` |
| `m_axi_awaddr` | out | `M_AXI_ADDR_W` |
| `m_axi_awlen` | out | 8 |
| `m_axi_awsize` | out | 3 |
| `m_axi_awburst` | out | 2 |
| `m_axi_awlock` | out | 1 |
| `m_axi_awcache` | out | 4 |
| `m_axi_awprot` | out | 3 |
| `m_axi_awvalid` | out | 1 |
| `m_axi_awready` | in | 1 |
| `m_axi_wdata` | out | 512 |
| `m_axi_wstrb` | out | 64 |
| `m_axi_wlast` | out | 1 |
| `m_axi_wvalid` | out | 1 |
| `m_axi_wready` | in | 1 |
| `m_axi_bid` | in | `M_AXI_ID_W` |
| `m_axi_bresp` | in | 2 |
| `m_axi_bvalid` | in | 1 |
| `m_axi_bready` | out | 1 |
| `m_axi_arid` | out | `M_AXI_ID_W` |
| `m_axi_araddr` | out | `M_AXI_ADDR_W` |
| `m_axi_arlen` | out | 8 |
| `m_axi_arsize` | out | 3 |
| `m_axi_arburst` | out | 2 |
| `m_axi_arlock` | out | 1 |
| `m_axi_arcache` | out | 4 |
| `m_axi_arprot` | out | 3 |
| `m_axi_arvalid` | out | 1 |
| `m_axi_arready` | in | 1 |
| `m_axi_rid` | in | `M_AXI_ID_W` |
| `m_axi_rdata` | in | 512 |
| `m_axi_rresp` | in | 2 |
| `m_axi_rlast` | in | 1 |
| `m_axi_rvalid` | in | 1 |
| `m_axi_rready` | out | 1 |

### Control (AXI4-Lite slave, `s_axil`)

32-bit data, 16-bit byte address, in `clk`. No `AxPROT`. Register map: [registers.md](registers.md).

| Port | Dir | Width |
|---|---|---|
| `s_axil_awaddr` | in | 16 |
| `s_axil_awvalid` | in | 1 |
| `s_axil_awready` | out | 1 |
| `s_axil_wdata` | in | 32 |
| `s_axil_wstrb` | in | 4 |
| `s_axil_wvalid` | in | 1 |
| `s_axil_wready` | out | 1 |
| `s_axil_bresp` | out | 2 |
| `s_axil_bvalid` | out | 1 |
| `s_axil_bready` | in | 1 |
| `s_axil_araddr` | in | 16 |
| `s_axil_arvalid` | in | 1 |
| `s_axil_arready` | out | 1 |
| `s_axil_rdata` | out | 32 |
| `s_axil_rresp` | out | 2 |
| `s_axil_rvalid` | out | 1 |
| `s_axil_rready` | in | 1 |

## Instantiation template

100G CMAC (512 bits):

```systemverilog
rocelet_top #(
    .NUM_QP(16), .NUM_MR(16), .READ_DEPTH(16), .RTX_MODE("RING"), .RING_BYTES(262144),
    .HSB_EN(1'b1), .CLK_MHZ(322), .CLK_KHZ(322266), .LINK_GBPS(100), .MAC_WIDTH(512)
) u_rocelet (
    .clk(cmac_usr_clk), .rst(cmac_usr_rst), .irq(rocelet_irq),
    .mac_rx_reset(usr_rx_reset), .mac_tx_reset(usr_tx_reset), .mac_rx_status(stat_rx_aligned),
    .link_up(stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault),
    .s_axis_rx_tdata(rx_axis_tdata), .s_axis_rx_tkeep(rx_axis_tkeep), .s_axis_rx_tvalid(rx_axis_tvalid),
    .s_axis_rx_tlast(rx_axis_tlast), .s_axis_rx_tuser(rx_axis_tuser),
    .m_axis_tx_tdata(tx_axis_tdata), .m_axis_tx_tkeep(tx_axis_tkeep), .m_axis_tx_tvalid(tx_axis_tvalid),
    .m_axis_tx_tready(tx_axis_tready), .m_axis_tx_tlast(tx_axis_tlast), .m_axis_tx_tuser(tx_axis_tuser),
    .mac_pause_hold(stat_rx_pause_req[8]), .mac_pause_valid(stat_rx_pause_valid[8]),
    .mac_pause_quanta(stat_rx_pause_quanta8), .mac_pause_req(pause_req),     // ctl_tx_pause_req = {pause_req, 8'd0}
    .mac_pause_rx_frame(stat_rx_pause), .mac_pause_tx_frame(stat_tx_pause),
    .mac_fec_corr_inc(stat_rx_rsfec_corrected_cw_inc), .mac_fec_uncorr_inc(stat_rx_rsfec_uncorrected_cw_inc),
    .m_axis_other_tdata(), .m_axis_other_tkeep(), .m_axis_other_tvalid(), .m_axis_other_tready(1'b1),
    .m_axis_other_tlast(),
    .s_axis_other_tdata('0), .s_axis_other_tkeep('0), .s_axis_other_tvalid(1'b0), .s_axis_other_tready(),
    .s_axis_other_tlast(1'b0),
    .s_axis_wr_tdata(wr_tdata), .s_axis_wr_tvalid(wr_tvalid), .s_axis_wr_tready(wr_tready),
    .s_axis_wr_data_tdata(pay_tdata), .s_axis_wr_data_tvalid(pay_tvalid), .s_axis_wr_data_tready(pay_tready),
    .s_axis_wr_data_tlast(pay_tlast),
    .m_axis_wc_tdata(wc_tdata), .m_axis_wc_tvalid(wc_tvalid), .m_axis_wc_tready(1'b1),
    .m_axis_send_tdata(send_tdata), .m_axis_send_tkeep(send_tkeep), .m_axis_send_tvalid(send_tvalid),
    .m_axis_send_tready(1'b1), .m_axis_send_tlast(send_tlast), .m_axis_send_tuser(send_tuser),
    .send_commit_valid(send_commit_valid), .send_commit_ok(send_commit_ok), .send_rnr('0),
    .m_axis_rc_tdata(rc_tdata), .m_axis_rc_tvalid(rc_tvalid), .m_axis_rc_tready(1'b1),
    .m_axi_awid(...), /* ... the full AXI4 master ... */ .m_axi_rready(...),
    .s_axil_awaddr(...), /* ... AXI4-Lite ... */ .s_axil_rready(...)
);
```

40GBASE-R4 MAC with a 256-bit AXI-Stream at 156.25 MHz (e.g. omac_40g; the MAC times received
PAUSE quanta itself and reports a level; firmware sets `CTRL.PAUSE_RX_LEVEL`); only the
parameters and MAC ports differ:

```systemverilog
rocelet_top #(
    .CLK_MHZ(156), .CLK_KHZ(156250), .LINK_GBPS(40), .MAC_WIDTH(256) /* , ... as above */
) u_rocelet (
    .clk(mac_clk), .rst(mac_rst), .irq(rocelet_irq),
    .mac_rx_reset(1'b0), .mac_tx_reset(1'b0), .mac_rx_status(stat_block_lock), .link_up(stat_link_up),
    .s_axis_rx_tdata(rx_tdata), .s_axis_rx_tkeep(rx_tkeep), .s_axis_rx_tvalid(rx_tvalid),   // 256 / 32 bits
    .s_axis_rx_tlast(rx_tlast), .s_axis_rx_tuser(rx_tuser),
    .m_axis_tx_tdata(tx_tdata), .m_axis_tx_tkeep(tx_tkeep), .m_axis_tx_tvalid(tx_tvalid),
    .m_axis_tx_tready(tx_tready), .m_axis_tx_tlast(tx_tlast), .m_axis_tx_tuser(),
    .mac_pause_hold(stat_rx_pause_req), .mac_pause_valid(1'b0), .mac_pause_quanta('0),
    .mac_pause_req(ctl_tx_pause_send), .mac_pause_rx_frame(ev_rx_pause), .mac_pause_tx_frame(ev_tx_pause),
    .mac_fec_corr_inc(1'b0), .mac_fec_uncorr_inc(1'b0),
    /* ... user ports as above, all 512 bits ... */
);
```

## Engine-only core (`rocelet_core`)

Designs that attach on-chip memory directly (URAM, for example) can use
`rocelet_core` instead: the same engine without the MAC glue, register file and AXI adapter,
with native per-packet memory command/data ports and a configuration port. It is documented in
[architecture.md](architecture.md); `rocelet_top` is the supported integration point.

## Change log of this interface

- 2026-10-21: first frozen version (v0.1.0-dev).
- 2026-10-21: no port or parameter change; registers added to the map (registers.md): `RETRY`
  (0x064, retry_cnt / rnr_retry), `PACE_RATE` / `PACE_BURST` (0x068 / 0x06C, requester rate
  limit). `rtl/rocelet_bd.v` added (IP integrator wrapper with the same ports).
- 2026-10-30 (v0.2.0-dev): **new input port `link_up`** (also in `rocelet_bd.v`): ACK-timeout
  hold while the link is down plus a grace after it comes back. New register `LINK_GRACE`
  (0x070, reset 3,000,000 ticks = 3 s), `STATUS.LINK_UP` [5] and `STATUS.TIMER_HOLD` [6], counter
  `CNT_LINK_DOWN` (index 49, 0x2C4); `VERSION` 0.2.0. No other port or parameter changed.
  `READ_DEPTH` now counts new READs only (duplicates are re-executed without a slot).
- 2026-10-30 (v0.2.1-dev): no port or parameter change. Reset values: `ACK_TIMEOUT` 1000 -> 5000
  (5 ms), `LINK_GRACE` 3,000,000 -> 6,000,000 ticks (6 s); `VERSION` 0.2.1. `link_up`
  recommendation: `stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault`.
- 2026-10-30 (v0.2.2, released 2026-10-31): no port or parameter change. Reset value `LINK_GRACE` 6,000,000 ->
  2,000,000 ticks (2 s); `VERSION` 0.2.2. With the recommended `link_up` the grace starts at the
  partner's link-up, so 2 s is enough; raise it to ~6 s if `link_up` is `stat_rx_aligned` alone.
- 2026-11-03 (v0.3.0): **MAC ports generic and width-parameterized**
  (also in `rocelet_bd.v`). New parameters `MAC_WIDTH` (64 / 128 / 256 / 512, default 512:
  bit-identical MAC side to v0.2.2), `LINK_GBPS` (default 100), `CLK_KHZ` (default 0 =
  `CLK_MHZ` x 1000). `s_axis_rx_*` / `m_axis_tx_*` are `MAC_WIDTH` wide (width converters inside
  below 512). Renamed: `mac_rx_aligned` -> `mac_rx_status`; the CMAC-shaped PAUSE / FEC ports
  -> `mac_pause_hold`, `mac_pause_valid`, `mac_pause_quanta`, `mac_pause_req` (1 bit each where
  the CMAC buses were 9 bits: bit 8 only was used), `mac_pause_rx_frame`, `mac_pause_tx_frame`,
  `mac_fec_corr_inc`, `mac_fec_uncorr_inc` (mapping table under [MAC side](#mac-side)). Registers:
  `CAPS` (0x018) and `CLK_KHZ` (0x01C) read only, `PAUSE_QCLK` (0x074) read/write (the PAUSE
  quantum was fixed at the 100G value before: 2.5x too short at 40G, 10x at 10G),
  `STATUS.MAC_ALIGNED` -> `STATUS.MAC_RX_STATUS`; `CNT_PAUSE_GATE` also counts rises of
  `mac_pause_hold` in level mode; `CNT_TX_UNDERRUN` also counts gaps after the TX width
  converter; `VERSION` 0.3.0. Received-PAUSE loads take 2 clocks longer (DSP multiply).
