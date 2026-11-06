# rocelet simulation

Vivado xsim testbenches driven by Python reference models. Every test is self-checking: the
Python side generates the stimulus (with the model's predictions) or the testbench checks
itself, and the result is a PASS / FAIL line.

## Running

```
make sim            # python3 -I sim/run_tests.py          full regression
make sim-quick      # python3 -I sim/run_tests.py --quick  smaller workloads
python3 -I sim/run_tests.py -k pair                         # tests whose name contains "pair"
python3 -I sim/test_pair.py --top 100 5 50 gbn_rnr          # one test, one configuration
```

Needs Vivado 2025.x (`xvlog`, `xelab`, `xsim` on the PATH, or `VIVADO_SETTINGS` pointing at
`settings64.sh`), Python 3 and scapy (`pip install scapy`). Build products go to `sim/build`
(or `$SIM_BUILD`). Each testbench is compiled once per configuration and re-compiled when a
source changes.

## Files

| File | What it is |
|---|---|
| `roce_ref.py` | RoCE v2 reference: ICRC (IBTA A17 masks, written from the specification, cross-checked against `scapy.contrib.roce` and two golden vectors), frame builder and parser, beat-file I/O |
| `hsb_ref.py` | NVIDIA Holoscan Sensor Bridge data-plane format (packet headers, immediate, metadata record), re-expressed from NVIDIA's HSB sources |
| `simlib.py` | file lists and the xsim runner |
| `axi_slave_model.sv` | AXI4 slave memory: random back-pressure and latency, out-of-order read IDs, burst checks |
| `axil_bfm.svh` | AXI4-Lite master tasks |
| `run_tests.py` | the regression |

## Tests

| Test | Testbench / driver | What is checked |
|---|---|---|
| `regs_generated` | `regs/rocelet_regs.py --check` | the RTL package, C header and register document match the register-map source |
| `bd_wrapper` | `scripts/gen_bd_wrapper.py --check` | the IP integrator wrapper matches rocelet_top's port list |
| `host_tools` | `make -C host test` | the host tools build with `-Werror`; pattern, record and referee selftests, the GPU ring logic on the mock back end (no RDMA device, no GPU) |
| `roce_ref` | `roce_ref.py` | the reference ICRC against scapy on 400 random IPv4 frames, IPv6 residues, golden vectors |
| `icrc_share`, `icrc_split` | `tb_icrc.sv` / `test_icrc.py` | ICRC generator and checker (shared and split CRC networks, GRAN 4 and 1): good frames, masked-field changes (must stay good), MAC changes, single bit flips (must fail), Ethernet-padded short frames, random gaps and back-pressure; VLAN-aware and programmable-offset variants |
| `req_tx` | `tb_req_tx.sv` / `test_req_tx.py` | requester segmentation for RC, UC and HSB QPs against a model: opcodes, PSNs, AckReq (last and every N), SE, MigReq, RETH / ImmDt, pad, MAC / IP / UDP fields, IPv4 checksum, ICRC; every IPv4 frame dissected and re-built by scapy; **HSB packets byte-identical to NVIDIA's HSB IP**, every HSB metadata record decoded as the host does (PSN = immediate PSN, page) |
| `resp_core` | `tb_core_resp.sv` / `test_resp.py` | the RC responder of rocelet_core against an IBTA responder model, with WRITE / SEND / READ on several QPs, duplicates, out-of-sequence packets (one NAK per gap), bad ICRCs, bad R_Keys (NAK + QP error), received ACKs, CNPs, non-RoCE frames, **partial READ re-issues** (continuation with `read_cont` 1, new response with 0), **RNR NAKs** from `send_rnr` and the requester's retry, bad duplicate READs dropped; every transmitted frame, memory write, SEND packet, completion (with length), received ACK and QP error compared; IPv6 and 1/2/8/64-QP configurations |
| `resp_top` | `tb_top_resp.sv` / `test_resp.py --top` | the same through the complete IP: MAC RX without back-pressure (the feeder honours rocelet's PAUSE requests), RX FIFO, classifier, AXI-Lite configuration, AXI4 memory model (final memory image compared); no RX FIFO drop, no TX underrun, no AXI error |
| `pair_core` | `tb_core_pair.sv` / `test_pair.py` | two rocelet_core over a lossy link (each frame dropped with 5 % probability in each direction): every WR completes once and in order, B's memory, SEND stream and receive completions exact; RING and REREAD go-back-N, RNR stalls, mixed RC / UC / HSB QPs, a forced QP error (FLUSHED completions, other QPs unaffected), LOSSY (lost WRs reported, never misdelivered) with and without a flush, the rate limiter (measured rate), the **RNR wait from the AETH timer code** (code 3 = 30 µs; code 0 = 655 ms clamped to `RNR_MAX`) |
| `pair_top` | `tb_top_pair.sv` / `test_pair.py --top` | two complete rocelet_top as two FPGAs on a lossy 100G link, all configuration through AXI-Lite: the pair checks above plus 802.3x PAUSE in both directions, VID-0 tags (A tags, B strips), ARP and ICMP echo answered by A (checksums, payload), a frame through A's other-traffic port leaving B's, counters (no underrun, no RX FIFO drop, VLAN, completions) |
| `read_reissue` | `tb_core_resp.sv` / `test_read_reissue.py` | the READ responder against a **closed-loop requester model** that keeps `READ_DEPTH` READs outstanding and loses READ response packets at random (the testbench releases each request only after the engine sent the frame the model reacted to): ConnectX-6 behaviour (out-of-order placement, a gap re-issued within a few frames as a partial READ plus some later READs whole, so duplicates arrive for READs the requester already finished) at `READ_DEPTH` 16, 8 and 1, and re-issue only after a timeout (in-order acceptance) at 16. Every frame compared with the model; no NAK (in particular no 0x61 from the depth check), every READ completes with the right data, continuations counted. Fails when duplicate READs take a READ slot |
| `link_down` | `tb_core_pair.sv` / `test_pair.py link_down link_nohold` | link loss on a WRITE-with-immediate stream (1 tick = 1 clock, ACK timeout 1000 ticks): the link down 1.2 M ticks (longer than the 20-bit tick counter wraps) with A's `link_up` low, then the partner silent for 250 k ticks of a 300 k-tick `LINK_GRACE`: no timeout while held, the first timeout within a few clocks of the end of the grace and at most one per QP, every WR completes OK, B's memory and receive completions exact; the control with `link_up` left high must fail with retry exceeded (0xFF) |
| `axi_mem` | `tb_axi_mem.sv` / `test_axi_mem.py` | the AXI4 master: 1-4096-byte packets with 4 KB splits, random back-pressure and latency, out-of-order read IDs, **READ after WRITE** (source-0 reads see every earlier write; the test fails when the ordering logic is removed), final memory image |
| `vlan` | `tb_vlan.sv` / `test_vlan.py` | VID-0 tag insertion and removal on 3000 random frames, VID != 0 passed, untagged unchanged |
| `mac_width` | `tb_mac_width.sv` / `test_mac_width.py` | the MAC width converters at 64, 128 and 256 bits (self-checking): RX packing with tvalid gaps inside and between frames, partial last beats, the bad-frame flag on the last or an earlier beat, an abort mid-frame; TX unpacking with MAC back-pressure, no tvalid gap inside a frame, full rate back to back (fails on each of three single-line mutations) |
| `pause` | `tb_top_pause.sv` / `test_pause.py` | rocelet_top clocked at the MAC clock of 10G (156.25 MHz, 64 bits), 25G (390.625 MHz, 64 bits), 40G (156.25 MHz, 256 bits) and 100G (322.27 MHz, 512 bits): `CAPS`, `CLK_KHZ`, `PAUSE_QCLK` reset values; the TX hold of 1-65535 received quanta against 512 bit times x quanta; XON; `PAUSE_QCLK` rewritten (hold doubles); level mode (`mac_pause_hold`); no frame starts while paused |
| `resp_top_w256`, `resp_top_w64` | `tb_top_resp.sv` / `test_resp.py --top --mac-width N` | `resp_top` with the MAC model at 256 / 64 bits (frames in MAC-width beats with partial last beats, random tvalid gaps inside frames) through the IP's width converters |
| `pair_top_w256`, `pair_top_w64` | `tb_top_pair.sv` / `test_pair.py --top --mac-width N` | `pair_top` over a 256 / 64-bit link (one MAC beat per clock, RX gaps), PAUSE as the receiving MAC's hold level (`CTRL.PAUSE_RX_LEVEL`) with low watermarks; PAUSE must have been in force |

## Results

Full regression (`make sim`), Vivado 2025.2 xsim, v0.3.0: **PASS, 21 tests, 0 failed**, about
30 min (the tests above; `pair_top` checks `VERSION` 0.3.0, `CAPS` and `CLK_KHZ`). In the narrow
`pair_top` runs PAUSE was in force (as the MAC's hold level) 5-39 times per configuration;
`pause` holds within 0.2 % of 512 bit times x quanta at 10G / 25G / 40G / 100G (100+ quanta).
