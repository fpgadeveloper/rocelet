# Throughput per MAC width

The engine is 512 bits wide and runs at the MAC's user clock whatever the MAC width
([interface.md, "MAC width and throughput"](interface.md#mac-width-and-throughput)). Its raw
capacity is therefore at least 1.65x the line rate at 100G and 2x at 40G, so every operation
reaches line rate at the large PMTUs; the small-packet limits (per-frame engine costs, READ
responses) move with the clock.

| MAC | `MAC_WIDTH` | `clk` | engine capacity (raw, each way) | line rate |
|---|---|---|---|---|
| 100G CMAC | 512 | 322.27 MHz | 165 Gb/s | 100 Gb/s |
| 40GBASE-R4 (omac_40g) | 256 | 156.25 MHz | 80 Gb/s | 40 Gb/s |
| 10GBASE-R (omac_10g) | 64 | 156.25 MHz | 80 Gb/s | 10 Gb/s |

## Measured

Payload throughput in Gb/s as measured by the receiving side, one QP, 64 KB messages unless
stated, against an NVIDIA ConnectX-6 Dx (firmware 22.43.2566, inbox mlx5 and rdma-core, Ubuntu
24.04) over a 3 m passive QSFP28 DAC, MTU 4200, in the
[qsfp28-fmc-rocelet](https://qsfp28-rocelet.ethernetfmc.com) reference design:

* **100G:** KCU116 + 2x QSFP28 FMC, 100G CMAC with RS-FEC, MicroBlaze console (rocelet v0.2.2;
  rows marked v0.1 were not repeated on later versions, see the design's
  [hardware test page](https://qsfp28-rocelet.ethernetfmc.com/en/latest/hardware_test.html)).
* **40G / 10G:** ZCU106 + 2x QSFP28 FMC, omac_40g (40GBASE-CR4, FEC off) or omac_10g
  (10GBASE-R), rocelet v0.3.0; the FPGA memory is the design's 256 KB URAM window unless stated.

| Operation | PMTU | 100G (KCU116) | 40G (ZCU106) | 10G (ZCU106) |
|---|---|---:|---:|---:|
| FPGA to host, WRITE with immediate | 4096 | 98.01 | 38.83 | 9.80 |
| FPGA to host, WRITE with immediate | 1024 | 92.56 (v0.1) | | |
| Host to FPGA, WRITE | 4096 | 96.79 | 38.74 | 9.69-9.71 |
| Host to FPGA, SEND | 4096 | 96.68 (16 KB, with immediate, v0.1) | 39.20 (8 KB) | 9.80 (8 KB) |
| Host READ of FPGA memory | 4096 | 96.59 | 38.73-39.17 | 9.44-9.57 |
| Host READ of FPGA memory | 2048 | 95.10 (v0.1) | | |
| Host READ of FPGA memory | 1024 | 81.15 (v0.1) | 37.03 | |
| Host READ of FPGA memory | 512 | | 34.43 | |
| Host WRITE into the PS DDR window (ZCU106 design, 256 MB) | 4096 | | 38.75 | 9.69-9.80 |
| Host READ of the PS DDR window | 4096 / 1024 | | 38.74 / 37.02 | 9.13 |
| Holoscan Sensor Bridge UC stream (1 MiB frames) into GPU memory, frames checked | 4096 | 80 (clean up to the test host's NIC-to-GPU limit of about 81) | 39.0 | 9.77 |

* **Line rate at 40G and 10G**: every 40G figure at PMTU 4096 is within the frame overhead of
  the 40 Gb/s line (Ethernet, IP, UDP, BTH and ICRC headers, preamble and gap); the READ figures
  at PMTU 1024 and 512 are the line rate at those packet sizes too. The engine is not the limit
  at either speed.
* **READ at small PMTUs**: at 100G the READ rate at PMTU 1024 (about 9.9 M responses/s at
  322 MHz) is below line rate; at 40G the same engine at 156.25 MHz still reaches line rate at
  PMTU 1024 and 512, because a 40G link carries fewer responses per second than the engine
  produces. PMTU 256 was not measured. Use PMTU 4096 (or 2048) for READ-heavy traffic.
* **PAUSE**: both directions were exercised at 40G. PAUSE transmit holds a host WRITE into a
  memory slower than the link without loss (a single HP port of the ZCU106's PS DDR: 32.0 Gb/s
  lossless, against 26.3 Gb/s with go-back-N losses without PAUSE); PAUSE receive held the
  FPGA's WRITE with immediate stream (38.78 to 23.89 Gb/s under 802.3x frames from the host,
  0 lost). At 100G: 24 M PAUSE frames sent, all honoured by the ConnectX-6.
* **Memory behind `m_axi`**: the engine reaches line rate only if the memory keeps up. The
  ZCU106 design spreads its PS DDR window over two HP ports per direction for that; one 128-bit
  HP port at 250 MHz capped it at about 32 Gb/s.
* Host-side limits seen while measuring, not the FPGA's: checking every byte on the CPU
  (`rocelet_host --verify full`) is CPU-bound at about 13 Gb/s on the test host (use
  `--verify sample:N` above that), and a simple single-threaded Holoscan Sensor Bridge receiver
  drops packets on the host above about 9 Gb/s.
