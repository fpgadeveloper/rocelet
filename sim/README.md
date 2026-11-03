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
| `resp_top` | `tb_top_resp.sv` / `test_resp.py --top` | the same through the complete IP: CMAC RX without back-pressure (the feeder honours rocelet's PAUSE requests), RX FIFO, classifier, AXI-Lite configuration, AXI4 memory model (final memory image compared); no RX FIFO drop, no TX underrun, no AXI error |
| `pair_core` | `tb_core_pair.sv` / `test_pair.py` | two rocelet_core over a lossy link (each frame dropped with 5 % probability in each direction): every WR completes once and in order, B's memory, SEND stream and receive completions exact; RING and REREAD go-back-N, RNR stalls, mixed RC / UC / HSB QPs, a forced QP error (FLUSHED completions, other QPs unaffected), LOSSY (lost WRs reported, never misdelivered) with and without a flush, the rate limiter (measured rate), the **RNR wait from the AETH timer code** (code 3 = 30 µs; code 0 = 655 ms clamped to `RNR_MAX`) |
| `pair_top` | `tb_top_pair.sv` / `test_pair.py --top` | two complete rocelet_top as two FPGAs on a lossy 100G link, all configuration through AXI-Lite: the pair checks above plus 802.3x PAUSE in both directions, VID-0 tags (A tags, B strips), ARP and ICMP echo answered by A (checksums, payload), a frame through A's other-traffic port leaving B's, counters (no underrun, no RX FIFO drop, VLAN, completions) |
| `read_reissue` | `tb_core_resp.sv` / `test_read_reissue.py` | the READ responder against a **closed-loop requester model** that keeps `READ_DEPTH` READs outstanding and loses READ response packets at random (the testbench releases each request only after the engine sent the frame the model reacted to): ConnectX-6 behaviour (out-of-order placement, a gap re-issued within a few frames as a partial READ plus some later READs whole, so duplicates arrive for READs the requester already finished) at `READ_DEPTH` 16, 8 and 1, and re-issue only after a timeout (in-order acceptance) at 16. Every frame compared with the model; no NAK (in particular no 0x61 from the depth check), every READ completes with the right data, continuations counted. Fails on v0.1 |
| `link_down` | `tb_core_pair.sv` / `test_pair.py link_down link_nohold` | link loss on a WRITE-with-immediate stream (1 tick = 1 clock, ACK timeout 1000 ticks): the link down 1.2 M ticks (longer than the 20-bit tick counter wraps) with A's `link_up` low, then the partner silent for 250 k ticks of a 300 k-tick `LINK_GRACE`: no timeout while held, the first timeout within a few clocks of the end of the grace and at most one per QP, every WR completes OK, B's memory and receive completions exact; the control with `link_up` left high must fail with retry exceeded (0xFF) |
| `axi_mem` | `tb_axi_mem.sv` / `test_axi_mem.py` | the AXI4 master: 1-4096-byte packets with 4 KB splits, random back-pressure and latency, out-of-order read IDs, **READ after WRITE** (source-0 reads see every earlier write; the test fails when the ordering logic is removed), final memory image |
| `vlan` | `tb_vlan.sv` / `test_vlan.py` | VID-0 tag insertion and removal on 3000 random frames, VID != 0 passed, untagged unchanged |

## Results

Full regression (`make sim`), 2026-10-30, Vivado 2025.2 xsim, v0.2.2 (new reset value
`LINK_GRACE` 2 s; the tests set their own timeouts, `pair_top` checks the `VERSION` 0.2.2 and
the `LINK_GRACE` reset value): **PASS, 15 tests, 0 failed, 11 min**.

### v0.2.1-dev

Full regression (`make sim`), 2026-10-30, Vivado 2025.2 xsim, v0.2.1-dev (new reset values
`ACK_TIMEOUT` 5 ms, `LINK_GRACE` 6 s; the tests set their own timeouts, `pair_top` checks the
`VERSION` 0.2.1 and `LINK_GRACE` reset value): **PASS, 15 tests, 0 failed, 18 min**.

### v0.2.0-dev

Full regression (`make sim`), 2026-10-30, Vivado 2025.2 xsim, v0.2.0-dev: **PASS, 15 tests, 0 failed, 20 min**
(the 13 tests below plus `read_reissue`, 108 s: 600 READs per configuration, rd16_cx6 / rd8_cx6 /
rd1_cx6 / rd16_timeout, and `link_down`, 49 s: link_down 100 WRs with 2 timeouts after the grace,
the first 2 clocks after it, and the link_nohold control failing with 0xFF as expected). The
existing tests run with `link_up` tied high.

### v0.1.0-dev

Full regression (`make sim`), 2026-10-21, Vivado 2025.2 xsim, v0.1.0-dev: **PASS, 13 tests, 0 failed, 14 min**.

| Test | Result | Time (s) | Configurations run |
|---|---|---:|---|
| `regs_generated` | PASS | 0 | |
| `bd_wrapper` | PASS | 0 | |
| `host_tools` | PASS | 9 | |
| `roce_ref` | PASS | 2 | 400 random IPv4 frames, IPv6 residues, golden vectors |
| `icrc_share` | PASS | 64 | 100 frames per variant, gaps and back-pressure |
| `icrc_split` | PASS | 65 | 60 frames per variant, no gaps |
| `req_tx` | PASS | 94 | `qp8_rt_v6`, `qp1_fix_v4`, `qp64_fix_v4_uc`, `qp8_fixfmt_v6`, `hsb` (150 WRs each) |
| `resp_core` | PASS | 122 | `qp8_mr4_cont`, `qp8_mr4_ibta`, `qp1_mr1_v6`, `qp2_mr2_ibta`, `qp64_mr16`, `qp2_rd1_cont` (300 requests each) |
| `resp_top` | PASS | 127 | the same six through rocelet_top |
| `pair_core` | PASS | 193 | `gbn_ring`, `gbn_reread`, `gbn_rnr`, `mixed_uc`, `flush`, `lossy`, `paced`, `rnr_code3`, `rnr_clamp`, `lossy_flush` (100 WRs each) |
| `pair_top` | PASS | 123 | `gbn_ring`, `gbn_reread`, `gbn_rnr`, `mixed_uc`, `flush`, `lossy` |
| `axi_mem` | PASS | 23 | 300 packets |
| `vlan` | PASS | 7 | 3000 frames |

Measured along the way: the rate limiter at `PACE_RATE` 10 B/clk gave 9.38 B/clk over the run
(`paced`); with the testbench's 16 clocks per µs, the RNR wait for timer code 3 (30 µs = 480
clocks) measured 473-495 clocks, and for code 0 clamped to `RNR_MAX` 200 µs (3200 clocks)
3196-3216 (`rnr_code3`, `rnr_clamp`; the timer counts whole microseconds, so ±1 µs).
