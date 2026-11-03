# rocelet host helper (`rocelet_host`) and packet referee (`roce_check.py`)

These tools test a design built around the rocelet RoCE v2 engine (for example the KCU116 +
Opsero 2x QSFP28 FMC reference design, qsfp28-fmc-rocelet) against a hardware RoCE v2 NIC
(plain libibverbs; the release validation ran on an NVIDIA ConnectX-6 Dx, `mlx5`). They are
host software only; nothing here is part of the FPGA IP. They were first written for the
research prototype (2026-10-21) and used for the ConnectX-6 Dx validation on 2026-10-30/31.

| file | what it is |
|---|---|
| `rocelet_host` (`rocelet_host.c`, `rl_verbs.c`, `rl_record.c`, `rl_stats.c`, `rl_common.h`) | libibverbs program, no rdma_cm. It opens the device, creates a PD, registers pinned host buffers, creates an RC QP and exchanges one-line parameter records with the FPGA console. It then moves the QP INIT→RTR→RTS and runs one test role (sink, source, reader or idle). It snapshots `hw_counters` and netdev statistics before and after, and prints the QP state. |
| GPU ring (`rl_gpu.h`, `rl_gpu_cuda.cu`, `rl_gpu_mock.c`, `rl_gpu_ref.c`, `rl_gpuv.c`, `rl_gring.c`, `rl_gpu_selftest.c`) | `--mem gpu`: the sink's buffer is GPU memory registered through a dma-buf (GPUDirect RDMA without nvidia-peermem) and checked by a CUDA kernel. Built with `make CUDA=1`; see "GPU ring" below. Adapted from an earlier Opsero host receiver (same copyright holder, MIT). |
| `roce_check.py` | Independent referee for framing and ICRC. Reads a pcap, or a hex dump captured by the FPGA. Checks every header field of every RoCE v2 frame, the ICRC (computed by scapy and by a separate zlib model), PSN and opcode sequences, AckReq spacing, ACK/NAK/MSN and the payload pattern. |
| `tests/` | Tests that need no hardware: `pattern_ref.py` (the test payload pattern in Python), `test_roce_check.py` (golden vectors plus good and broken frame streams) and `test_gpu.c` (the GPU ring logic on the mock back end). |

## Build and test

```
sudo apt install build-essential libibverbs-dev rdma-core ibverbs-utils python3-scapy
make -C host            # builds rocelet_host (gcc, -Wall -Wextra -Werror), host memory only
make -C host test       # selftest + pattern cross-check + GPU ring logic (mock) + roce_check tests
make -C host test-noscapy   # the same without roce_check's scapy tests
make -C host CUDA=1     # also the GPU ring (--mem gpu, selftest-gpu): nvcc, CUDA 11.7+
make -C host CUDA=1 CUDA_ARCH=sm_120   # explicit GPU architecture (no GPU query at build time)
```

`make test` never opens an RDMA device and never touches a GPU (the GPU ring logic runs on a mock
back end in host memory). Every other `rocelet_host` command uses the device: `info`, `counters`
and `run`; `selftest-gpu` uses the GPU (and the RDMA device for its registration test).
Switching between `make` and `make CUDA=1` rebuilds everything. A build without CUDA has no CUDA
symbols and no `ibv_reg_dmabuf_mr` reference; `--mem gpu` then stops with exit 2 and a message.

## Parameter records (the out-of-band exchange)

There is no in-band connection manager: the host and the FPGA exchange their QP parameters out
of band. Each side prints its own parameters as two short lines; the operator, or the agent
driving the bench, types or pastes them on the other side (a design may also carry them over a
UDP side channel). Each line is at most 96 characters, because a small MicroBlaze console reads
at most 127 characters and 12 words per line.

```
host -> FPGA (rocelet_host prints them; type them into the FPGA console):
  RLH qpn=0x1b psn=0x3c2b1a ip=192.168.20.1 mac=6cfe549177f0 mtu=4096 ord=16
  RLHM rkey=0x12ab va=0x7f3e40000000 len=0x4000000

FPGA -> host (the FPGA console prints them; paste them into rocelet_host):
  RLF qp=0 qpn=0x100 psn=0x10123 ip=192.168.20.2 mac=020a35726c01 mtu=4096 rd=16 seed=0x5eed1234
  RLFM mr=0 rkey=0x1000 va=0x10000000000 len=0x40000000 pat=0x10000000000 acc=rw
  RLFM mr=1 rkey=0x2001 va=0x0 len=0x40000 acc=rw
```

| key | in | meaning |
|---|---|---|
| `qpn` | RLH, RLF | the sender's own QP number. The other side uses it as the BTH DestQP (`QP_DQPN` register on the FPGA). |
| `psn` | RLH, RLF | the sender's first send PSN. The other side uses it as its expected PSN (`QP_RQ_PSN` on the FPGA, `rq_psn` on the host). |
| `ip`, `mac` | both | IPv4 address and MAC of the sender's port. `mac` is 12 hex digits; colons are optional. |
| `mtu` | both | path MTU in bytes. The host prints the value it will use: the smallest of `--pmtu`, its active_mtu and the FPGA's `mtu`. The FPGA must use the same value (`QP_PMTU` = log2). |
| `ord` | RLH | number of RDMA READs the host keeps in flight. It is never more than the FPGA's `rd`. |
| `rd` | RLF | the FPGA's READ responder depth (`READ_DEPTH`, register `BUILD0`). |
| `seed` | RLF | payload pattern seed of the design's traffic generator / checker. |
| `qp` | RLF | the FPGA QP index (information only). |
| `rkey`, `va`, `len` | RLHM | the host buffer that the FPGA writes into (the `rkey` and `remote_va` of the FPGA's work requests). |
| `rkey`, `va`, `len`, `pat`, `acc` | RLFM | one FPGA memory window (`MR_*` registers). `pat` is the pattern address (local address) of `va`. It defaults to `va`, which is right for identity windows. `acc` is `r`, `w` or `rw`. |

Number syntax is C syntax, as `strtoul(s, NULL, 0)` reads it: `0x..` is hexadecimal, anything else
is decimal, and the printers never emit leading zeros. Keys may appear in any order. Unknown keys
are ignored. Text before the tag, such as a console prompt, is ignored. `rocelet_host selftest`
round-trips the format.

### The FPGA side of the exchange

A design's firmware maps the records onto rocelet's registers ([../docs/registers.md](../docs/registers.md)):

| record | firmware action |
|---|---|
| `RLH qpn= psn= ip= mac= mtu= ord=` | `QP_INDEX` = the FPGA QP, `QP_DQPN` = qpn, `QP_RQ_PSN` = psn, `QP_DIP0` = ip, `QP_DMAC_*` = mac, `QP_PMTU` = log2(mtu), `QP_SQ_PSN` = the FPGA's own first PSN, `QP_UDP` = a source port, `QP_FLAGS` = valid + type, then `QP_COMMIT`. |
| `RLHM rkey= va= len=` | the destination of the FPGA's work requests (`rkey`, `remote_va`). |
| (printed) `RLF qp= qpn= psn= ip= mac= mtu= rd= seed=` | qpn = `QPN_BASE` + index (`BUILD2`), psn = the `QP_SQ_PSN` it will commit, rd = `READ_DEPTH`. |
| (printed) `RLFM mr= rkey= va= len= pat= acc=` | one per memory window it commits (`MR_*`). |

The FPGA must answer ARP (rocelet does, `CTRL.ARP_INT`); it accepts MigReq 0 and VID-0
priority tags (`CTRL.VLAN_RX_STRIP`), which ConnectX in PCP mode and some other NICs send.

## `rocelet_host` usage

```
rocelet_host info --dev rocep179s0f0 [--fpga-ip 192.168.20.2]   # port, active_mtu, GID table, neighbour
rocelet_host counters --dev rocep179s0f0 [--save a.txt | --diff a.txt]
rocelet_host pattern --addr 0x10000000000 --seed 0x5eed1234 --len 128
rocelet_host run --role sink|source|reader|idle --op write|write_imm|send|send_imm [options]
rocelet_host run --role sink --op write_imm --mem gpu --buf-size max [options]   # CUDA=1 build
rocelet_host selftest-gpu --dev rocep179s0f0 [--gpu 0] [--buf-size BYTES] [--mock]
```

`rocelet_host --help` lists every option. The defaults are deliberately safe:

| option | default | note |
|---|---|---|
| `--dev` | the first RDMA device present | `run`, `info` and `counters` print the choice when several are present (`rdma link show` lists them). `selftest-gpu` registers the ring on a device only when `--dev` is given. |
| `--rate` | `1G` | Source/reader payload rate. Use `max` to remove the limit. |
| `--depth` | 16 | Send WRs in flight (source/reader). |
| `--pmtu` | 4096 | Capped at active_mtu and at the FPGA's `mtu=`. |
| `--retry` / `--rnr-retry` | 7 / 7 | |
| `--timeout` | 14 | **Some drivers ignore it** (see the host rules below). |
| `--max-rd` | 16 | Capped at the FPGA's `rd=`. Never 0: some drivers take 0 as the device maximum. |
| `--max-dest-rd` | 1 | The FPGA has no READ requester in v1. |
| `--migreq` | not set | `migrated` sets the verbs APM state. Some drivers ignore it and always send MigReq = 0. |
| `--qp-type` | `rc` | `uc` needs a provider with UC QPs (mlx5, rxe); others reject it (EOPNOTSUPP). |
| `--verify` | `full` | Full checking costs about 1 CPU-byte per byte. Above ~40 Gb/s use `sample:N`. |
| `--hugepages` | `try` | Reserve 2 MiB pages for line-rate runs: `echo 512 \| sudo tee /proc/sys/vm/nr_hugepages`. |
| `--repost-delay-us` | 0 | Sink: re-post each receive N µs late, a deliberately slow receiver for RNR tests. |
| `--mem` | `host` | `gpu`: the sink buffer is a GPU ring (sink `--op write` / `write_imm` only, one ring). Needs a `make CUDA=1` build. |
| `--buf-size` | 64M | With `--mem gpu`, the GPU ring size; `max` = the largest ring BAR1 allows (BAR1 - 16 MiB: **240 MiB** on a 256 MiB BAR1). A larger ring is refused before anything is allocated. |
| `--gpu` | 0 | CUDA device index. |
| `--gpu-iova` | `0` | The address the ring is registered at: `0` (Holoscan Sensor Bridge convention; the RLHM `va=` is the byte offset in the ring) or `dev` (the GPU device address). The pattern address is always the VA the FPGA wrote to. |
| `--gpu-batch` / `--gpu-wait-us` | 64 / 200 | Messages per verify-kernel launch; a partial batch launches after this wait. |
| `--gpu-scrub` | `auto` | `on`: after its check the kernel refills each message with the fill byte, so a later lap of the ring that did not land (or was not visible yet at its completion) is caught as fill instead of passing on the old data. `auto` = on when the slots in use span >= 16 MiB (a lap then takes >= 1.3 ms at 100 Gb/s; a check waits <= 200 µs + the kernel). Keep it off for small windows. |
| `--link-grace` / `--link-down-max` | 10 / 60 s | A port error (link down) does not end the run: the sink's silence timer is held while the port is down and for `--link-grace` s after it is ACTIVE again; the run fails if the port stays down longer than `--link-down-max`. Whether the RC QP survives depends on the requester: its retry budget (FPGA `ACK_TIMEOUT` x (`RETRY_CNT` + 1)), or no limit with rocelet's `link_up` hold (../docs/host-setup.md section 10). |

Run it on the NIC's NUMA node, e.g. `numactl --cpunodebind=1 --membind=1 rocelet_host ...`.

### How a run proceeds

1. Open the device and pick the RoCE v2 IPv4-mapped GID of the netdev (or take `--gid-index`).
   Check that the port is ACTIVE and that the path MTU is no more than active_mtu.
2. Register the host buffer with LOCAL_WRITE, REMOTE_WRITE and REMOTE_READ, then
   create the QP and move it to INIT. Sinks post their receive WRs at this point.
3. If no `--peer` lines were given, print a preliminary RLH/RLHM and read RLF (+RLFM) lines from the
   control input.
4. Agree on mtu, ord and seed. Print the **final** RLH/RLHM, and write them to `--record-out` if given.
5. Check the kernel neighbour entry of the FPGA IP. Move the QP to RTR (the kernel resolves the
   FPGA's MAC by ARP within 1 s) and then to RTS. Print the QP state. Print `RLH READY`.
6. Source and reader roles wait for a `go` line, so that the FPGA can apply the record first.
   The sink waits for data.
7. Status line every `--interval`. Summary at the end: counter deltas, a `WATCH:` line for every
   problem counter that moved, the QP state, `result: PASS/FAIL`, and the exit code.

The control input (`--ctl`, stdin by default) accepts RLF/RLFM records, `go`, `done` (sink: stop
and verify), `stats` (print the counter deltas now) and `quit`. An agent drives it through a FIFO:

```
mkfifo /tmp/rl.ctl
numactl --cpunodebind=1 --membind=1 ./rocelet_host run --dev rocep179s0f0 --role sink --op write_imm \
    --len 65536 --count 10000 --ctl /tmp/rl.ctl --record-out /tmp/rl.rec > rl.log 2>&1 &
exec 3>/tmp/rl.ctl          # keep the FIFO open for writing
echo "RLF qp=0 qpn=0x100 psn=0x10123 ip=192.168.20.2 mac=020a35726c01 mtu=4096 rd=16 seed=0x5eed1234" >&3
cat /tmp/rl.rec             # -> type both lines into the FPGA console, then start the FPGA sender
```

The record can also be passed up front with `--peer 'RLF ...' --peer 'RLFM ...'`. In that case
`rocelet_host` prints only the final host record.

### Roles

| role | data | verification |
|---|---|---|
| `sink --op write` | The FPGA RDMA-WRITEs into the RLHM buffer. | Address-based scan at the end (`done`, silence, `--duration`): every 64-byte beat at host VA A must be `pattern(A)`, all fill bytes (never written), or it counts as corrupt. With `--count`, the expected number of written slots is checked. Progress is measured by the `ip4InOctets` hw counter. With `--mem gpu` the scan runs on the GPU. |
| `sink --op write_imm` | As above, plus one receive completion per WR. | The immediate must be `imm0 + n` (gaps count as lost, backwards as dup). Slot n of the window is checked at completion (`--mem gpu`: by the GPU in batches, results in completion order). |
| `sink --op send / send_imm` | The FPGA SENDs into the posted receives (`--rq-depth`, slot = `--len`). | Self-describing pattern: bytes 0..7 hold the pattern address. Consecutive addresses, length = `--len`, immediates as above. |
| `source --op write / write_imm / send / send_imm` | The host writes or sends a mirror of the FPGA window (`pattern(pat + offset)`) into the RLFM window. | The design's data checker judges the data. The host checks completions, rate and WC errors. |
| `reader` | RDMA READ of the RLFM window, slot by slot. | Each landing slot must equal `pattern(pat + offset)`, either from the pattern region or from URAM previously written by `source`. |
| `idle` | The QP is only brought to RTS. | Status, counters and async events. Use it for FPGA-driven tests where the host is a passive responder. |

### The payload pattern

The reference designs' traffic generator and data checker produce this pattern (first defined
as `rl_sys_pkg::pat_beat` in the research prototype). Every 64-byte beat at pattern address A
holds A in bytes 0..7 and `(A ^ {S, ~S}) + K[i]` in bytes 8i..8i+7, all little endian. A region
with pattern address P holds `pat_beat(P + 64k)` in its k-th beat. The FPGA WR generator uses P =
the remote VA of the WR. The memory model and the checkers use P = the local address (= VA for
identity windows). `tests/pattern_ref.py --check ./rocelet_host` compares 25 cases with the
Python version.

## GPU ring (`--mem gpu`)

The sink's ring lives in GPU memory: `cudaMalloc` (2 MiB rounded, filled with the fill byte),
exported as a dma-buf (`cuMemGetHandleForAddressRange`) and registered with
`ibv_reg_dmabuf_mr`. The NIC writes into the GPU through its BAR1 aperture; nvidia-peermem is not
needed (inbox rdma-core and mlx5, NVIDIA open kernel module). Requirements, the IOVA choice,
the BAR1 limit and the throughput to expect on a given host are in
[../docs/host-setup.md](../docs/host-setup.md), "GPU ring".

| op | what the GPU checks | same numbers as the CPU path |
|---|---|---|
| `write_imm` | Each completion becomes a job (slot offset, pattern address = the VA the FPGA wrote, length). Jobs are batched (64, or after 200 µs) and one 256-thread block per message compares every 64-byte beat with the pattern; results come back in completion order. The immediate sequence (lost / duplicate) stays on the CPU. Receives are re-posted at the completion, not after the check. | `checked bytes`, `data N msgs / M bytes`, first bad byte and the first five mismatch dumps are exactly what `rl_pat_check()` would give (the CPU reference `rl_gpu_ref.c` is what the kernel must reproduce; `selftest-gpu` compares them on the GPU). |
| `write` | At the end of the run, a scan kernel classifies every beat of the ring as written correctly, never written (fill) or corrupt. | The `WRITE target scan` line. |

Extra GPU lines in the summary: ring size, IOVA, BAR1 used; launches, average batch, kernel time
and GPU busy %, back-pressure waits (every batch in flight), unchecked jobs (a GPU error: the run
fails), scrub on/off; and, if any beat was bad, how many were **fill** (never written, or not
visible at the completion), **misplaced** (a correct pattern beat of another address) or
**corrupt**.

`selftest-gpu` checks the GPU path without NIC traffic: device and dma-buf attributes, BAR1, the
verify kernel against the CPU reference on a CPU-generated pattern with planted faults (one wrong
byte, an unwritten message, a misplaced beat, an unwritten tail, garbage, partial and unaligned
regions; pattern base 0 and a device-like base; batches of 1, 7 and 64), the scrub, the scan
kernel, the refusal of a ring above the BAR1 cap, then the run-size ring (`--buf-size`, default
the cap): cudaMalloc + export + `ibv_reg_dmabuf_mr` on `--dev` at IOVA 0 and at the device
address (no QP is created), BAR1 use while registered, and the kernels' throughput. It prints
PASS/FAIL (exit 0/4). `--mock` runs the same on the mock back end (part of `make test`).

## Host rules

The host-side rules learned on the bench against the NVIDIA ConnectX-6 Dx (mlx5, the release's
validation NIC) are in
[../docs/host-setup.md](../docs/host-setup.md): GID selection, MTU
4200, neighbour entries, receive-queue depth under WRITE with immediate, READ depth, pause,
RS-FEC, what a NIC may ignore, and where the counters are.

## `roce_check.py` and the capture modes

```
roce_check.py CAP.pcapng [--src 192.168.20.2] [--pmtu 4096] [--seed 0x5eed1234] [--expect-migreq 1] [-v]
roce_check.py --hex fpga_capture.txt [--pmtu 4096]
```

It prints one line for every frame with an error or warning (all frames with `-v`), then a
summary per flow: PSN range, gaps, go-back-N retransmissions, opcode-sequence errors, AckReq
spacing, MSN/NAK/RNR, and pattern. The last line is a verdict. Exit code 0 = PASS, 1 = errors,
2 = no RoCE frames. The ICRC is computed twice, by `scapy.contrib.roce` and by a zlib model of
IBTA A17, and the two must agree. Both reproduce the golden vectors of the research study.

The host NIC hides RoCE traffic, so the interop tests use three capture modes:

1. **IPv4-checksum capture mode (FPGA → host frames, no host change).** If the design has a TX
   fault injector (the research prototype and the reference design's test build do), make it
   corrupt byte 25 of every engine frame (the low byte of the IPv4 header checksum). The ICRC masks the IPv4 checksum, so the frames
   keep a valid engine-generated ICRC. A NIC whose RDMA parser rejects them passes them to the
   netdev, where `dumpcap`/`tcpdump` see them. Then run `roce_check.py --expect-bad-ipcsum`. The kernel
   IP stack drops these frames after capture. Whether a NIC does this depends on the NIC; not
   tried on the ConnectX-6 Dx.
2. **FPGA-side capture (host → FPGA frames).** Use the design's RX capture buffer (if it has one)
   and its console hex dump, then `roce_check.py --hex`. This is the only way to see the host NIC's
   own frames (ACK/NAK, READ responses, requests) on a host with no RDMA capture device, such as
   the ConnectX-6 Dx bench host, whose inbox stack listed none (`tcpdump -D`); it was the referee there. It checks their headers and also confirms our ICRC
   model against a real NIC.
3. **RDMA off on the port (needs the user's approval; host driver change).** Drivers that
   support the generic devlink parameter `enable_roce` can remove the RDMA device of one PCI
   function: `devlink dev param set pci/<bdf> name enable_roce value false cmode <mode>` (the
   cmode the driver supports: `runtime`, or `driverinit` followed by `devlink dev reload`).
   Every UDP-4791 frame then reaches the netdev. Re-enable with `value true`. It applies per PCI
   function; the other ports are not affected. No host QP can exist while RDMA is off. Not tried
   on the ConnectX-6 Dx.

## Exit codes

`rocelet_host`: 0 PASS, 1 usage, 2 local setup (device, port, GID, MTU, memory, GPU ring, QP), 3 FPGA record or QP
bring-up (RTR/RTS, ARP), 4 errors found (WC, data, sequence, async; for a WRITE-with-immediate or SEND
sink with `--count`, fewer messages than `--count`), 5 the sink received nothing (for those sinks:
no message, whatever the NIC's IPv4 counters say).
