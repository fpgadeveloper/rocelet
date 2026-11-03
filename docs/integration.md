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
  the CMAC), `M_AXIS_OTHER` / `S_AXIS_OTHER`, `S_AXIS_WR`, `S_AXIS_WR_DATA`, `M_AXIS_WC`,
  `M_AXIS_SEND`, `M_AXIS_RC`, all associated with `clk`. Set the parameters with
  `set_property CONFIG.<name> <value>`.
- **Engine only**: `rocelet_core` (native per-packet memory ports and configuration ports, no
  MAC glue, registers or AXI) for designs that attach on-chip memory directly and write their
  own glue.

## 3. Clock and reset

| Signal | Connect to |
|---|---|
| `clk` | the CMAC user clock `gt_txusrclk2` (322.265625 MHz for 100GBASE-R4). Drive the CMAC's `rx_clk` from `gt_txusrclk2` too (the usual configuration), so the RX AXI-Stream is in the same clock. |
| `rst` | a synchronous, active-high reset in `clk` (e.g. a `proc_sys_reset` in `gt_txusrclk2`), held for at least 4 clocks |
| `mac_rx_reset`, `mac_tx_reset` | CMAC `usr_rx_reset`, `usr_tx_reset` |
| `mac_rx_aligned` | CMAC `stat_rx_aligned` (only reported in `STATUS`) |
| `link_up` | CMAC `stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault` (recommended; `stat_rx_aligned` alone works). Holds the requester's ACK timeouts while the link is down and for `LINK_GRACE` after it is back (section 9). In the CMAC's RX clock is fine (synchronised inside). Tie 0 or 1 (or leave it unconnected in a block design) for the v0.1 behaviour: the hold is armed only after `link_up` was 1 once. |
| `s_axil_*` | the CPU's AXI-Lite, through a clock converter (SmartConnect with a second clock, or an AXI clock converter) into `clk` |
| `m_axi_*` | memory: an AXI BRAM/URAM controller, a DDR4 MIG port (through a clock converter / width converter as the controller needs), or a SmartConnect. 512-bit data; set `M_AXI_ADDR_W` to the address width the interconnect uses. Raise `MEM_RD_BUF` for a high-latency memory (DDR4: 512). |
| `irq` | the CPU's interrupt controller (level, high while `STATUS.ERR` and `CTRL.IRQ_EN`) |

## 4. CMAC configuration

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
| Sent PAUSE | `ctl_tx_pause_enable[8]` = 1; `ctl_tx_pause_quanta8` = 0x0100 (about 1.3 µs at 100G), `ctl_tx_pause_refresh_timer8` = 0x0080; `ctl_tx_pause_req` <- rocelet's `ctl_tx_pause_req`; `ctl_tx_resend_pause` = 0. Set the PAUSE source address (`TX_SA_GPP` / `ctl_tx_sa_gpp`) to the FPGA's MAC. |
| Connections | `rx_axis_*` -> `s_axis_rx_*`; `tx_axis_*` <- `m_axis_tx_*`; `stat_rx_pause_req`, `stat_rx_pause_valid`, `stat_rx_pause_quanta8`, `stat_rx_pause`, `stat_tx_pause` -> the inputs of the same names; `stat_rx_rsfec_corrected_cw_inc` / `_uncorrected_cw_inc` -> the RS-FEC counter inputs (tie 0 when the CMAC does not provide them) |

The CMAC must see no gap inside a TX frame (an underrun gives a bad FCS): rocelet's TX path is
store-and-forward, and `CNT_TX_UNDERRUN` stays 0. The CMAC's RX has no back-pressure: rocelet's
32 KB RX FIFO absorbs bursts and asks the link partner to PAUSE before it overflows.

## 5. The other-traffic ports

Non-RoCE frames (not answered by the built-in ARP/ICMP responder) leave on
`m_axis_other` when `CTRL.OTHER_RX_EN` = 1, and `s_axis_other` sends frames (FCS appended by the
CMAC). Use them for a soft CPU's network stack (the HSB control plane: BOOTP enumeration on UDP
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

1. Release `rst`; read `ID` (0x52434C54) and `BUILD0..3`.
2. `MAC_LO/HI`, `IP4`, `IP_HDR` (TTL 64, ToS 0), `TICK_DIV` (clock MHz, if not `CLK_MHZ`),
   `ACK_TIMEOUT`, `RNR_MIN/MAX`, `RETRY`, `ACKREQ_N`, `PAUSE_WM`, `CTRL` (defaults: RX/TX on,
   READ continuation on, VID-0 strip on, ARP/ICMP on, pause honour and request on).
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

The v1 configuration closes timing at 322.27 MHz out of context on an xcku5p-2 (see
[resources.md](resources.md)). In a full design, place the IP near the CMAC (the GT quad), and
keep the AXI-Lite and memory clock crossings outside it.

In the complete KCU116 design (qsfp28-fmc-rocelet: CMAC, MicroBlaze, traffic generator and
checker, 17 % of the KU5P) v0.1.0-dev closes at +0.016 ns. **The known tight path** is in the
responder transmit engine: `u_core/u_rtx/r_act_reg` to the read enable of its response queue
RAM (`u_core/u_rtx/u_q/g_sync.mem_reg*/ENARDEN`, 9 logic levels). It was also the worst path out
of context in v0.1 (+0.144 ns; since v0.2 that is the counter clear, +0.107 ns, see
[resources.md](resources.md)). The next ones are in the RX ICRC CRC network (+0.05 ns in the KCU116
design). If a design misses on these paths by a little, a post-route `phys_opt_design` pass (or
the `Performance_ExplorePostRoutePhysOpt` strategy) is the first thing to try; the run-to-run
spread of the slack is about 0.1 ns.

250 MHz is a valid fallback clock with the same logic (set `CLK_MHZ` and `TICK_DIV`); the
responder then reaches line rate only at PMTU 4096.

## 9. Link loss (cable pulls, link partner resets)

An RC requester normally survives an outage only as long as its retry budget: `RETRY_CNT` + 1
ACK timeouts (8 x 5 ms at reset). A cable pull takes far longer: 10-20 s by hand, plus the
link partner's own link-up after the reseat (a ConnectX-6 Dx: 2.3-3 s after the plug, while
the FPGA's CMAC is aligned again after ~0.4-0.5 s). Since v0.2 the requester knows the link
state:

- Wire `link_up` to the CMAC's
  `stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault` (recommended; all three are
  CMAC status outputs in its RX clock). A local fault means this CMAC is not receiving a valid
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
  `"block"` and `"distributed"` are plain block and LUT RAM), one `use_dsp = "no"` and
  `ASYNC_REG` on the link-status synchroniser. Other tools ignore unknown attributes; their own
  equivalents (such as Quartus's `ramstyle`) can be substituted, and the ring's RAM type
  (`RING_RAM`) should then be set to a RAM type the device has.
- **MAC interface and clock.** The engine expects a 512-bit AXI-Stream MAC interface and runs
  entirely in the MAC's clock domain, 322.265625 MHz for the AMD CMAC (250 MHz also closes on
  Kintex UltraScale+). A MAC with another bus or clock needs a thin adapter, and timing has to
  be closed at that clock on the target device.
- **Flow and proof.** The simulation regression runs on Vivado's xsim, the resource and timing
  figures ([resources.md](resources.md)) come from Vivado out-of-context runs, the block-design
  wrapper (`rtl/rocelet_bd.v`) is for IP integrator, and every hardware result was taken on a
  Kintex UltraScale+ (KCU116). Nothing has been synthesised, timed or run on another vendor's
  device.
