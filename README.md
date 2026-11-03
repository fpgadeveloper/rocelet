# rocelet

**rocelet** is an open-source, lightweight **RoCE v2** (RDMA over Converged Ethernet) engine
for FPGAs, written in vendor-neutral SystemVerilog and validated on AMD UltraScale+ (see
[Portability](docs/integration.md#10-portability)). It is built for the common FPGA use case: moving data
at line rate between an FPGA and a host or GPU over a point-to-point 100 GbE link, using
standard RDMA NICs (validated with an NVIDIA ConnectX-6 Dx) on the host side, without a
licensed IP core.

## What it does

- **RC (reliable connection) requester:** RDMA WRITE, WRITE with immediate, SEND, SEND with
  immediate, multi-packet messages, go-back-N retransmission with an on-chip retransmit ring
  (or by re-reading FPGA memory). Zero loss against a standard NIC.
- **RC responder:** RDMA WRITE and SEND from the host into FPGA memory, RDMA READ of FPGA
  memory by the host, duplicate and NAK handling, RNR, READ continuation.
- **UC streamer mode** compatible with the NVIDIA Holoscan Sensor Bridge data plane
  (one RETH per packet).
- IPv4/UDP framing, TX and RX ICRC, PMTU 256-4096, 802.1Q priority tags, 802.3x pause
  honoured and generated, CNPs dropped.
- Out-of-band QP setup: a small host helper based on libibverbs exchanges QPN, PSN, rkey and
  buffer addresses with the FPGA over a side channel. No in-band connection manager.
- 512-bit AXI-Stream at the 100G CMAC user clock; AXI-Lite control; AXI-MM data.

On a Kintex UltraScale+ (KCU116) the full engine uses about one third of the logic of AMD's
ERNIC IP and a few percent of its block RAM, and sustains line rate for messages of 2 KB and
larger. It has been validated against an independent hardware RoCE v2 NIC.

In numbers, the v0.2.2 IP (16 QPs, 16 memory windows, 16 outstanding READs per QP, 256 KB
retransmit ring, RX ICRC check, MAC glue, register file and AXI4 memory master) uses about
**20.8k LUT, 37 BRAM36 and 8 URAM** on an xcku5p and closes timing at 322 MHz
([docs/resources.md](docs/resources.md)).

## Architecture

![rocelet block diagram](docs/images/rocelet-block.png)

How to read the diagram, the receive and transmit paths, the requester and the responder:
[docs/architecture.md](docs/architecture.md).

## Using it

rocelet is meant to be pulled into a design as a git submodule. The first reference design is
[qsfp28-fmc-rocelet](https://github.com/fpgadeveloper/qsfp28-fmc-rocelet) (Opsero 2x QSFP28
FMC on the KCU116 and other AMD development boards). The `dev` branch holds the work in
progress; `main` holds releases.

A design instantiates `rocelet_top` (or `rocelet_bd` in an IP integrator block design) between
the 100G CMAC and its data: work requests and their payload go in on AXI-Streams, completions
come out; host WRITEs and READs reach FPGA memory through an AXI4 master; a soft CPU configures
the queue pairs through AXI-Lite after exchanging their parameters with the host. Start with
[docs/integration.md](docs/integration.md).

## Documentation

The documentation is hosted at [rocelet.ethernetfmc.com](https://rocelet.ethernetfmc.com)
(built by Read the Docs from the `docs/` folder, which reads the same on GitHub):

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | block diagram, module hierarchy, receive and transmit paths, reliability, HSB mode, clocking |
| [docs/interface.md](docs/interface.md) | the top-level ports and parameters, the work-request and completion formats |
| [docs/registers.md](docs/registers.md) | the AXI-Lite register map (generated; C header `sw/rocelet_regs.h`) |
| [docs/integration.md](docs/integration.md) | adding rocelet to a design: sources, clocks, CMAC settings (RS-FEC, pause, no auto-negotiation on AOC), memory, firmware bring-up, timing, link loss, portability |
| [docs/roce-subset.md](docs/roce-subset.md) | the RoCE v2 subset implemented, the wire rules, and what is deliberately left out |
| [docs/hsb.md](docs/hsb.md) | Holoscan Sensor Bridge compatibility: the data-plane mode, the control plane and producer in the reference design, future work |
| [docs/host-setup.md](docs/host-setup.md) | host rules: MTU, FEC, neighbour entries, QP attributes, receive queues, ConnectX-6 Dx facts, GPU ring, link flaps and cable pulls |
| [docs/resources.md](docs/resources.md) | synthesis results and build-option costs |
| [sim/README.md](sim/README.md) | the simulation regression and its results |
| [host/README.md](host/README.md) | `rocelet_host` (libibverbs test helper) and `roce_check.py` (packet referee) |

## Repository layout

```
rtl/        the IP (SystemVerilog; rocelet.f lists the sources in compile order)
regs/       the register map source (rocelet_regs.py generates the RTL package, the C header and docs/registers.md)
sw/         rocelet_regs.h for firmware
sim/        Python reference models, xsim testbenches, run_tests.py (make sim)
synth/      out-of-context synthesis / place / route scripts (make synth)
host/       host tools: rocelet_host (C, libibverbs), roce_check.py
docs/       documentation
scripts/    generators (the IP integrator wrapper)
```

## Quick start

```
make sim-quick          # simulation regression, smaller workloads (Vivado xsim + Python 3 with scapy)
make sim                # the full regression
make synth              # OOC synthesis, place and route of the v1 configuration (Vivado)
make -C host && make -C host test     # host tools (libibverbs-dev); the tests need no RDMA device
```

The simulations need Vivado's `xvlog`/`xelab`/`xsim` on the PATH (or `VIVADO_SETTINGS`
pointing at `settings64.sh`) and `pip install scapy`.

## Status

v0.2.2 (2026-10-31), the first release; see [CHANGELOG.md](CHANGELOG.md). Validated in the
qsfp28-fmc-rocelet design (KCU116 + 2x QSFP28 FMC) against an NVIDIA ConnectX-6 Dx: 98.0 Gb/s
FPGA WRITE with immediate into host memory, 96.8 Gb/s host WRITE and 96.6 Gb/s host READ of
FPGA memory, go-back-N under injected loss, and link loss at the default settings including a
real cable pull (14.9 s outage, stream resumed ~2 s after the link returned, nothing lost). The
HSB mode carries a Holoscan Sensor Bridge device data plane into GPU memory with NVIDIA's HSB
3.0.0 host software (qsfp28-fmc-rocelet 0.3.0).

## Origin

The feature set was chosen by a measured study of RoCE v2 (protocol decomposition, prior art,
a resource baseline of AMD's ERNIC IP, per-block synthesis costs, whole-design builds and bench tests
against a hardware NIC). The prototype that study produced was then productised into this IP;
the prototype itself is not published.

## Contribute

We strongly encourage community contribution to these projects. Please make a pull request if you
would like to share your work:
* if you've spotted and fixed any issues
* if you've added support for other boards, MACs or host NICs
* if you've extended the RoCE v2 subset or the host tools

Thank you to everyone who supports us!

## About us

This project was developed by [Opsero Inc.](https://opsero.com "Opsero Inc."),
a tight-knit team of FPGA experts delivering FPGA products and design services to start-ups and tech companies.
Follow our blog, [FPGA Developer](https://www.fpgadeveloper.com "FPGA Developer"), for news, tutorials and
updates on the awesome projects we work on.

## License

The sources of this repository are released under the MIT license, see [LICENSE](LICENSE).
