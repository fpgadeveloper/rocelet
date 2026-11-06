# Integrating rocelet into a design

## 1. Add the repository

rocelet is consumed as a git submodule:

```
git submodule add https://github.com/fpgadeveloper/rocelet.git ip/rocelet
git -C ip/rocelet checkout <release tag>      # or dev for the work in progress
```

The sources, in compile order, are listed in `rtl/rocelet.f` (paths relative to the rocelet
root). In a Vivado Tcl flow:

```tcl
set rl [file normalize ip/rocelet]
foreach f [split [string trim [read [open $rl/rtl/rocelet.f]]] "\n"] {
    if {$f ne "" && [string index $f 0] ne "#"} { read_verilog -sv [file join $rl $f] }
}
```

or `add_files` the same list into a project. All files are SystemVerilog-2012 with no vendor
primitives, no IP cores and no include paths.

## 2. Instantiate it

- **RTL top**: instantiate `rocelet_top` (port list and parameters: [interface.md](interface.md)).
- **IP integrator**: a module reference needs a Verilog top; add `rtl/rocelet_bd.v` as well and
  `create_bd_cell -type module -reference rocelet_bd rocelet_0`. Its ports are rocelet_top's,
  grouped into interfaces: `S_AXIL` (AXI4-Lite), `M_AXI` (AXI4), `S_AXIS_RX` / `M_AXIS_TX` (to
  the MAC, `MAC_WIDTH` bits), `M_AXIS_OTHER` / `S_AXIS_OTHER`, `S_AXIS_WR`, `S_AXIS_WR_DATA`, `M_AXIS_WC`,
  `M_AXIS_SEND`, `M_AXIS_RC`, all associated with `clk`. Set the parameters with
  `set_property CONFIG.<name> <value>`.
- **Engine only**: `rocelet_core` (native per-packet memory ports and configuration ports, no
  MAC glue, registers or AXI) for designs that attach on-chip memory directly and write their
  own glue.

## 3. Clock and reset

| Signal | Connect to |
|---|---|
| `clk` | the MAC user clock, the clock of both MAC AXI-Streams. CMAC: `gt_txusrclk2` (322.265625 MHz for 100GBASE-R4); drive the CMAC's `rx_clk` from `gt_txusrclk2` too (the usual configuration), so the RX AXI-Stream is in the same clock. 40GBASE-R4 / 10GBASE-R MAC (omac): its 156.25 MHz user clock. Set `CLK_MHZ` / `CLK_KHZ` to it and `MAC_WIDTH` / `LINK_GBPS` to the MAC (section 4). |
| `rst` | a synchronous, active-high reset in `clk` (e.g. a `proc_sys_reset` in `gt_txusrclk2`), held for at least 4 clocks |
| `mac_rx_reset`, `mac_tx_reset` | the MAC's RX / TX resets (CMAC `usr_rx_reset`, `usr_tx_reset`; omac: tie 0, its `rst` covers both) |
| `mac_rx_status` | the MAC's RX alignment / block lock (CMAC `stat_rx_aligned`, omac `stat_block_lock`; only reported in `STATUS`) |
| `link_up` | RX aligned and no local / remote fault: CMAC `stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault` (recommended; `stat_rx_aligned` alone works), omac `stat_link_up`. Holds the requester's ACK timeouts while the link is down and for `LINK_GRACE` after it is back (section 9). It may come from another clock, such as the MAC's RX clock (synchronised inside). Tied to 0 or 1 (or left unconnected in a block design) the ACK timeouts run without a link hold: the hold is armed only after `link_up` was 1 once. |
| `s_axil_*` | the CPU's AXI-Lite, through a clock converter (SmartConnect with a second clock, or an AXI clock converter) into `clk` |
| `m_axi_*` | memory: an AXI BRAM/URAM controller, a DDR4 MIG port (through a clock converter / width converter as the controller needs), or a SmartConnect. 512-bit data; set `M_AXI_ADDR_W` to the address width the interconnect uses. Raise `MEM_RD_BUF` for a high-latency memory (DDR4: 512). |
| `irq` | the CPU's interrupt controller (level, high while `STATUS.ERR` and `CTRL.IRQ_EN`) |

## 4. MAC configuration

rocelet takes any MAC with the AXI-Stream conventions of [interface.md](interface.md) ("MAC
side"): FCS checked and stripped on RX, appended (with padding to 60 bytes) on TX, no RX
`tready`, RX and TX in one clock, 802.3x PAUSE parsed and sent by the MAC. Static MAC
configuration (enables, FEC, loopback, PAUSE quanta and refresh) and the MAC's statistics stay
in the design next to the MAC; rocelet has no MAC configuration port.

| `rocelet_top` parameter | 100G CMAC | 40GBASE-R4 MAC (omac_40g) | 10GBASE-R MAC (omac_10g) |
|---|---|---|---|
| `MAC_WIDTH` | 512 | 256 | 64 |
| `CLK_MHZ` / `CLK_KHZ` | 322 / 322266 | 156 / 156250 | 156 / 156250 |
| `LINK_GBPS` | 100 | 40 | 10 |
| received PAUSE | quanta (`mac_pause_valid` / `_quanta`) or level | level (`mac_pause_hold`, `CTRL.PAUSE_RX_LEVEL` = 1) | level |

A design whose one bitstream runs the link at more than one speed (e.g. a 25G MAC that also
does 10G) writes `PAUSE_QCLK` for the speed in use; nothing else in rocelet depends on the line
rate. Engine capacity per MAC width: [interface.md](interface.md), "MAC width and throughput"; the rates
measured at 100G, 40G and 10G: [](throughput.md).

### 4.1 The 100G CMAC

rocelet needs nothing from the CMAC's AXI-Lite statistics block: it can be left out
(`ENABLE_AXI_INTERFACE` 0, saving about 5.5k LUT and 26k FF) and the CMAC configured through its
static `ctl_*` ports, or kept for a firmware that wants it.

| CMAC setting | Value |
|---|---|
| Mode | CAUI-4, 4 x 25.78 Gb/s, AXI-Stream user interface (`USER_INTERFACE AXIS`), 322.265625 MHz GT reference clock |
| RS-FEC | **included and enabled** (`INCLUDE_RS_FEC 1`; enable TX and RX RS-FEC: `ctl_rsfec_enable_transmitter_ecc`, `ctl_rsfec_enable_receiver_ecc`/`ctl_rx_rsfec_enable` or the RS-FEC configuration registers). Point to point it is what a ConnectX expects for 100GBASE-CR4/SR4 and it removed the bench's FCS errors. |
| Auto-negotiation / link training | **off** for AOC and optics (they have none); set FEC equal at both ends by hand |
| RX/TX enable | `ctl_rx_enable` = 1, `ctl_tx_enable` = 1, `ctl_tx_send_idle/lfi/rfi` = 0 |
| Received PAUSE | global pause frames accepted and reported: `ctl_rx_pause_enable[8]` = 1, `ctl_rx_enable_gpp` = 1, `ctl_rx_check_mcast_gpp`, `ctl_rx_check_etype_gpp`, `ctl_rx_check_opcode_gpp` = 1 (register equivalents: RX flow-control control 1 = 0x00801500, control 2 = 0x00006419). The CMAC only reports PAUSE; rocelet's arbiter stops starting frames. |
| Sent PAUSE | `ctl_tx_pause_enable[8]` = 1; `ctl_tx_pause_quanta8` = 0x0100 (about 1.3 µs at 100G), `ctl_tx_pause_refresh_timer8` = 0x0080; `ctl_tx_pause_req` <- `{mac_pause_req, 8'd0}`; `ctl_tx_resend_pause` = 0. Set the PAUSE source address (`TX_SA_GPP` / `ctl_tx_sa_gpp`) to the FPGA's MAC. |
| Connections | `rx_axis_*` -> `s_axis_rx_*`; `tx_axis_*` <- `m_axis_tx_*`; `stat_rx_pause_valid[8]` -> `mac_pause_valid`, `stat_rx_pause_quanta8` -> `mac_pause_quanta`, `stat_rx_pause_req[8]` -> `mac_pause_hold` (used only with `CTRL.PAUSE_RX_LEVEL`), `stat_rx_pause` -> `mac_pause_rx_frame`, `stat_tx_pause` -> `mac_pause_tx_frame`; `stat_rx_rsfec_corrected_cw_inc` / `_uncorrected_cw_inc` -> `mac_fec_corr_inc` / `mac_fec_uncorr_inc` (tie 0 when the CMAC does not provide them). The v0.2 names and the mapping: interface.md, "Mapping". |

The CMAC must see no gap inside a TX frame (an underrun gives a bad FCS): rocelet's TX path is
store-and-forward, and `CNT_TX_UNDERRUN` stays 0. The CMAC's RX has no back-pressure: rocelet's
32 KB RX FIFO absorbs bursts and asks the link partner to PAUSE before it overflows.

### 4.2 A 40G or 10G MAC (omac, 156.25 MHz)

- Connect the MAC's 256-bit (40G) or 64-bit (10G) AXI-Streams directly to `s_axis_rx_*` /
  `m_axis_tx_*` with `MAC_WIDTH` set to match; the packer and unpacker inside `rocelet_top`
  handle partial last beats, `tvalid` gaps on RX and the bad-frame flag, and the MAC TX sees no
  gap inside a frame (`CNT_TX_UNDERRUN` counts any, on both sides of the converter; it must stay
  0).
- `clk` = the MAC user clock (156.25 MHz), `CLK_MHZ` 156, `CLK_KHZ` 156250, `LINK_GBPS` 40 or
  10. The engine then has 80 Gb/s of raw capacity each way.
- PAUSE: the MAC parses received PAUSE frames, times the quanta and holds a level
  (`stat_rx_pause_req` on omac, with its `ctl_pause_tx_honour` = 0) -> `mac_pause_hold`;
  firmware sets `CTRL.PAUSE_RX_LEVEL`; tie `mac_pause_valid` to 0. `mac_pause_req` -> the MAC's
  level PAUSE request (omac `ctl_tx_pause_send`: XOFF while high, refreshed, XON on release).
  The full omac connection list: [interface.md](interface.md), "MAC side". Without PAUSE support in the MAC, build with `PAUSE_EN` = 0 or clear
  `CTRL.PAUSE_RX_EN` / `PAUSE_TX_EN`: RX overflow then drops whole frames and go-back-N recovers
  them (with an on-chip memory window nothing back-pressures RX; with DRAM behind `m_axi` PAUSE
  matters).
- No FEC at 40GBASE-R4 (tie the FEC counter inputs to 0); the host port must be forced to the
  same speed with FEC off and auto-negotiation off ([](host-setup.md), section 1).
- 10G or 40G is one link to one host port: the ConnectX-6 Dx does 40GBASE-CR4 and 10G.
- Hardware reference: the qsfp28-fmc-rocelet ZCU106 target (omac_40g, omac_10g as an option),
  see [](designs.md). It places rocelet's two width converters (`rocelet_rx_upsize`,
  `rocelet_tx_downsize`, `rtl/mac/rocelet_mac_width.sv`) at its own MAC boundary and builds the
  engine with `MAC_WIDTH` 512, so its self-test taps keep 64-byte beats; `CAPS` then reads 512
  and the design reports the MAC width in a register of its own. Instantiating `rocelet_top`
  with `MAC_WIDTH` 256 / 64 is equivalent.

## 5. The other-traffic ports

Non-RoCE frames (not answered by the built-in ARP/ICMP responder) leave on
`m_axis_other` when `CTRL.OTHER_RX_EN` = 1, and `s_axis_other` sends frames (FCS appended by the
MAC). Use them for a soft CPU's network stack (the HSB control plane: BOOTP enumeration on UDP
12267/12268, the ECB register protocol on UDP 8192; an out-of-band QP exchange), or for a NIC
stack such as Zircon (then clear `CTRL.ARP_INT` so ARP and ICMP go to the stack). For a
MicroBlaze: an AXI-Stream FIFO or DMA plus 32 <-> 512-bit width converters; the
`OTHER_TX_FIFO_DEPTH`-beat FIFO inside rocelet makes the TX side gap-tolerant (frames must fit
in it: 256 beats = 16 KB by default). Tie `m_axis_other_tready` = 1 and `s_axis_other_tvalid` =
0 when unused.

## 6. Work requests and payload

- `s_axis_wr`: one 256-bit beat per work request (layout in [interface.md](interface.md)).
- `s_axis_wr_data` (`RTX_MODE` "RING", "LOSSY"): the payload, ceil(length / 64) beats, the WR's
  bytes from lane 0, `tlast` on the last beat. In "RING" mode a WR is forwarded once all of its
  payload is in the 256 KB ring, so a WR must fit in the ring (split long transfers into WRs of
  at most a quarter of the ring for streaming).
- "REREAD": the payload is read from `m_axi` at the WR's `local_addr` (64-byte aligned), per
  packet, and again for a retransmission.
- `m_axis_wc`: one completion per WR in WR order; tie `tready` = 1 if not needed (completions
  then just pass).
- Memory alignment: remote VAs of FPGA windows and local addresses are 64-byte aligned; WR
  lengths are arbitrary.

## 7. Firmware bring-up

Register names from [registers.md](registers.md) (C header `sw/rocelet_regs.h`):

1. Release `rst`; read `ID` (0x52434C54), `VERSION`, `BUILD0..3`, `CAPS` (MAC width, link
   speed) and `CLK_KHZ` (since v0.3; 0 on older builds), and convert clock counts with
   `CLK_KHZ` rather than a compile-time constant.
2. `MAC_LO/HI`, `IP4`, `IP_HDR` (TTL 64, ToS 0), `TICK_DIV` (clock MHz, if not `CLK_MHZ`),
   `ACK_TIMEOUT`, `RNR_MIN/MAX`, `RETRY`, `ACKREQ_N`, `PAUSE_WM`, `PAUSE_QCLK` (only if the link
   runs at another speed than `LINK_GBPS`), `CTRL` (defaults: RX/TX on, READ continuation on,
   VID-0 strip on, ARP/ICMP on, pause honour and request on; set `PAUSE_RX_LEVEL` for a MAC
   that reports received PAUSE as a level).
3. Memory windows: `MR_INDEX`, `MR_FLAGS` (valid, write, read), `MR_RKEY` (low log2(NUM_MR)
   bits = index; the high bits a fresh random value per connection), `MR_VA_*`, `MR_LEN`,
   `MR_LADDR_*`, `MR_COMMIT`.
4. Per connection, after the out-of-band exchange with the host (QPN, PSN, IP, MAC, PMTU,
   buffer VA / R_Key / size, READ depth): `QP_INDEX`, `QP_FLAGS` (valid, type RC/UC/HSB),
   `QP_SQ_PSN`, `QP_RQ_PSN` (the host's first PSN), `QP_PMTU`, `QP_DMAC_*`, `QP_DIP0`,
   `QP_DQPN`, `QP_UDP` (source port, e.g. 0xC000 + index), `QP_COMMIT`. The QP's local QPN is
   `QPN_BASE` + index; the host must use exactly `READ_DEPTH` as `max_rd_atomic`.
5. Post work requests on `s_axis_wr`.
6. On `irq` / `STATUS.ERR`: read `LAST_REQ_ERR`, `LAST_RESP_ERR`, `QP_ERR_MAP*` and
   `QP_STATUS`; recover a QP by a new exchange and a new commit (after its outstanding work
   requests have completed: `WR_OUTSTANDING`, or flush them with `QP_ERR_CMD`); `CMD.CLR_ERR`.

The host side of the exchange and the host rules: [host-setup.md](host-setup.md) and
`host/README.md`.

## 8. Timing

The v1 configuration of v0.3.0 closes timing out of context at 322.27 MHz on an xcku5p-2 with
the 512-bit MAC (WNS +0.105 ns for the v1 top, +0.115 ns for the 512-bit run of the MAC widths),
and with a 256-bit or 64-bit MAC at 156.25 MHz on an xczu7ev-2 with a wide margin (WNS +1.267 /
+1.407 ns); see [resources.md](resources.md), "v1 configuration" and "MAC widths". In a full design, place the IP near the MAC (the GT quad), and keep the AXI-Lite and
memory clock crossings outside it.

At 322 MHz the tightest paths are the fan-out of the engine reset register (`eng_rst_reg`,
`rst` or `CTRL.RESET`: into the RX FIFO's read pointer in the v1 top, +0.105 ns, 0 logic levels;
into the memory master's read buffer in the 512-bit run, +0.115 ns, 1 logic level) and, in the
v1 top, the retransmit ring's output FIFO read pointer to the clock enables of the transmit
builder (`u_core/g_ring.u_ring/u_of` -> `u_core/u_bld`: +0.170 ns, 5 logic levels). If a
design misses on these paths by a little, a post-route `phys_opt_design` pass (or the
`Performance_ExplorePostRoutePhysOpt` strategy) is the first thing to try; the run-to-run
spread of the slack is about 0.1 ns.

250 MHz is a valid fallback clock for the 100G CMAC with the same logic: set `CLK_MHZ` 250 and
`CLK_KHZ` 250000 (or 0), which give the reset values of `TICK_DIV`, `CLK_KHZ` and `PAUSE_QCLK`
(or write `TICK_DIV` and `PAUSE_QCLK` at run time; firmware that converts clock counts reads
`CLK_KHZ`). The responder then reaches line rate only at PMTU 4096.

## 9. Link loss (cable pulls, link partner resets)

An RC requester normally survives an outage only as long as its retry budget: `RETRY_CNT` + 1
ACK timeouts (8 x 5 ms at reset). A cable pull takes far longer: 10-20 s by hand, plus the
link partner's own link-up after the reseat (a ConnectX-6 Dx: 2.3-3 s after the plug, while
the FPGA's CMAC is aligned again after ~0.4-0.5 s). The requester therefore takes the link
state as an input:

- Wire `link_up` to the MAC's link state without faults: for the CMAC
  `stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault` (recommended; all three are
  CMAC status outputs in its RX clock), for omac `stat_link_up`. A local fault means this CMAC is not receiving a valid
  signal; a remote fault means the link partner reports that it is not receiving ours. Either
  way the peer is not receiving or not transmitting frames, so ACKs cannot arrive and the timer
  should hold then too, not only when alignment is lost (a partner that takes its port down
  administratively can keep its PHY up and signal a fault, or go silent, before the FPGA loses
  alignment; the 5 ms `ACK_TIMEOUT` default covers the silent part). The fault bits may toggle
  briefly while the link comes up; that is harmless, since every rise of `link_up` starts the
  `LINK_GRACE` hold again (each fall adds one to `CNT_LINK_DOWN`, so one outage may count more
  than once). `stat_rx_aligned` alone also works. While `link_up` is 0 no ACK
  timeout is counted and the timer starts no retransmission; packets already queued (new data,
  a go-back-N started by a NAK, an RNR resend) still go out and are lost, which the held
  timeout then covers.
- After `link_up` rises the timeouts stay held for `LINK_GRACE` ticks (reset 2,000,000 = 2 s
  at the default `TICK_DIV`; 24 bits, up to 16.7 s; 0 = none), for a partner whose port is up
  before its RDMA stack answers. With the fault terms in `link_up` the grace starts at the
  partner's own link-up (the remote fault clears when the partner receives our signal; a
  ConnectX-6 Dx was up 4.4-5.6 s after a CMAC reset and `link_up` rose within 0.22 s of its
  carrier), and grace 0 / 1 s / 3 s all survived 5 s forced drops on the bench; 2 s is margin.
  With `stat_rx_aligned` alone the grace starts at alignment, before the partner is up (a
  ConnectX-6 Dx: 2.4-2.9 s after the FPGA, 5.1-5.4 s after an FPGA-side relink): raise it to
  ~6 s then. Until it ends, a QP whose ACKs were lost in the outage waits (a NAK from the
  partner ends the wait earlier).
- When the hold ends, every QP whose ACK became overdue meanwhile times out at once: one
  retransmission of its window from the oldest unacknowledged PSN (go-back-N), retry count +1.
  A QP that was not yet overdue times out at its normal time. Nothing is lost or duplicated
  (simulated: `link_down` in the regression, 1.2 M ticks down + 250 k ticks partner silent).
- The RNR wait is not held: it is a delay the responder asked for, not a loss detector; when it
  expires during an outage the resend is lost and the held ACK timeout covers it. RNR NAKs, not
  the wait, count against `RNR_RETRY`.
- Software sees `STATUS.LINK_UP`, `STATUS.TIMER_HOLD` and the `CNT_LINK_DOWN` counter;
  `CNT_REQ_TIMEOUT` counts only real timeouts (one per QP with data in flight after an
  outage).
- The host's side (host -> FPGA traffic, host READs) is governed by the host QP's `timeout` /
  `retry_cnt` (mlx5 honours them; some drivers ignore `timeout`): see [host-setup.md](host-setup.md).

## 10. Portability

The engine is vendor-neutral SystemVerilog: no vendor primitives or macros are instantiated,
memories and FIFOs are inferred from behavioural code, and there is no HLS. What is specific to
the AMD flow, and what a port to another device family has to look at:

- **Synthesis attributes.** The RTL carries Vivado hints only: `ram_style` on the inferred
  memories (the retransmit ring offers an `"ultra"` option that maps it to UltraScale+ URAM;
  `"block"` and `"distributed"` are plain block and LUT RAM), one `use_dsp = "yes"` (the
  PAUSE quanta multiply) and `ASYNC_REG` on the link-status synchroniser. Other tools ignore unknown attributes; their own
  equivalents (such as Quartus's `ramstyle`) can be substituted, and the ring's RAM type
  (`RING_RAM`) should then be set to a RAM type the device has.
- **MAC interface and clock.** The engine takes a 64-, 128-, 256- or 512-bit AXI-Stream MAC
  interface (`MAC_WIDTH`; 512 bits inside) and runs entirely in the MAC's clock domain,
  322.265625 MHz for the AMD CMAC (250 MHz also closes on Kintex UltraScale+), 156.25 MHz for
  a 40G or 10G MAC. A MAC with another bus or with RX in a separate clock needs a thin adapter
  (an asynchronous FIFO), and timing has to be closed at that clock on the target device.
- **Flow and proof.** The simulation regression runs on Vivado's xsim, the resource and timing
  figures ([resources.md](resources.md)) come from Vivado out-of-context runs, the block-design
  wrapper (`rtl/rocelet_bd.v`) is for IP integrator, and the hardware results were taken on a
  Kintex UltraScale+ (KCU116, 100G) and a Zynq UltraScale+ MPSoC (ZCU106, 40G and 10G).
  Nothing has been synthesised, timed or run on another vendor's device.
