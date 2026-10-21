# rocelet

**rocelet** is an open-source, lightweight **RoCE v2** (RDMA over Converged Ethernet) engine
for AMD FPGAs, written in SystemVerilog. It is built for the common FPGA use case: moving data
at line rate between an FPGA and a host or GPU over a point-to-point 100 GbE link, using
standard RDMA NICs (NVIDIA ConnectX, Intel E810, and others) on the host side, without a
licensed IP core.

## What it does

- **RC (reliable connection) requester:** RDMA WRITE, WRITE with immediate, SEND, SEND with
  immediate, multi-packet messages, go-back-N retransmission with an on-chip retransmit ring.
  Zero loss against a standard NIC.
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

## Using it

rocelet is meant to be pulled into a design as a git submodule. The first reference design is
[qsfp28-fmc-rocelet](https://github.com/fpgadeveloper/qsfp28-fmc-rocelet) (Opsero 2x QSFP28
FMC on the KCU116 and other AMD development boards). The `dev` branch holds the work in
progress; `main` holds releases.

## Origin

The feature set was chosen by a measured study of RoCE v2 (protocol decomposition, prior art,
an ERNIC resource baseline, per-block synthesis costs, whole-design builds and bench tests
against a hardware NIC). The prototype that study produced lives on the `research` branch of
the qsfp28-fmc-rocelet repository.

## License

MIT.
