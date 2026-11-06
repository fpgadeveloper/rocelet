# Designs using rocelet

| Design | Board | MAC | Link | Control plane | Engine configuration |
|---|---|---|---|---|---|
| [qsfp28-fmc-rocelet](https://qsfp28-rocelet.ethernetfmc.com), target `kcu116` | AMD KCU116 (Kintex UltraScale+ XCKU5P) + Opsero 2x QSFP28 FMC (OP120), QSFP28 port 0 | AMD 100G CMAC (hard MAC, free license) with RS-FEC, 512 bits at 322.27 MHz | 100GBASE-CR4 / -SR4 | MicroBlaze console (UART) | `MAC_WIDTH` 512, `CLK_KHZ` 322266, `LINK_GBPS` 100 |
| [qsfp28-fmc-rocelet](https://qsfp28-rocelet.ethernetfmc.com), target `zcu106` | AMD ZCU106 (Zynq UltraScale+ XCZU7EV) + Opsero 2x QSFP28 FMC (OP120) on HPC0, QSFP28 port 0 | [omac_40g](https://omac.ethernetfmc.com/en/latest/omac_40g.html) (open source, MIT) on four GTH lanes, 256 bits at 156.25 MHz; option: [omac_10g](https://omac.ethernetfmc.com/en/latest/omac_10g.html), 64 bits | 40GBASE-CR4 (FEC off); option 10GBASE-R | Linux on the Cortex-A53 (daemon, CLI, web UI, `rl0` network interface for non-RoCE traffic) or a bare-metal A53 console | engine `MAC_WIDTH` 512 with rocelet's width converters at the design's MAC boundary (equivalent to `MAC_WIDTH` 256 / 64), `CLK_KHZ` 156250, `LINK_GBPS` 40 / 10 |
| [qsfp28-fmc-rocelet](https://qsfp28-rocelet.ethernetfmc.com), target `vck190_fmcp1` | AMD VCK190 (Versal AI Core XCVC1902) + Opsero 2x QSFP28 FMC (OP120) on FMCP1, QSFP28 port 0 | the Versal **MRMAC** (hard MAC, no-cost license) with RS-FEC, 384 bits at 390.625 MHz, behind a design-side adapter (`mac_mrmac100g`: RX packer and asynchronous FIFO, store-and-forward TX FIFO and 64 → 48-byte downsizer) | 100GBASE-CR4 / -SR4 | Linux on the Cortex-A72 (the ZCU106 stack) or a bare-metal A72 console | `MAC_WIDTH` 512, `CLK_MHZ` 300, `CLK_KHZ` 300000, `LINK_GBPS` 100: the engine on a free-running 300 MHz clock of its own, the MAC behind asynchronous FIFOs ([integration.md, 4.3](integration.md#43-a-mac-in-another-clock-the-engine-on-its-own-clock)) |

All three targets build the engine with the v1 parameters (16 QPs, 16 memory windows, 16
outstanding READs, 256 KB retransmit ring, Holoscan Sensor Bridge mode) and connect it to the
MAC through one generic MAC boundary, so the same system logic (memory windows, self-test,
Holoscan Sensor Bridge producer) runs with any of the MACs. All three are validated on hardware
against an NVIDIA ConnectX-6 Dx: the measured rates per MAC are on [](throughput.md), the
design's own pages (getting started, host setup, hardware test, the Linux stack of the ZCU106
and VCK190 targets, porting to other boards) at
[qsfp28-rocelet.ethernetfmc.com](https://qsfp28-rocelet.ethernetfmc.com).

The ZCU106 target is also the reference for **Zynq UltraScale+ RFSoC** boards (same processing
system): there the 100G CMAC (on boards that have one) goes behind the same MAC boundary as on
the KCU116, and the ZynqMP software stack is reused. The VCK190 target is the reference for
**Versal** devices with an MRMAC: the same adapter, NoC memory path and software, with the
board's GT quad, MRMAC site and pins.

Using rocelet in a design of your own? A pull request adding it to this list is welcome.
