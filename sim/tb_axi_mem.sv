// SPDX-License-Identifier: MIT
//
// tb_axi_mem - self-checking testbench of rocelet_axi_mem against axi_slave_model (random
// back-pressure and latency, read bursts of the two IDs out of order). Random write
// packets (1..4096 bytes, 64-byte aligned, some across a 4 KB boundary) and read packets of
// both sources; a reference memory is updated when a write command is accepted. Source-0
// reads must return the data of every write accepted before them (READ after WRITE);
// source-1 reads use a region that is never written. The consumers of the read data
// stall at random. +n=<packets> +seed=
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_axi_mem;

logic clk = 1'b0, rst = 1'b1;
always #1.551 clk = ~clk;

logic         wcmd_valid = 1'b0, r0_valid = 1'b0, r1_valid = 1'b0;
wire  logic   wcmd_ready, r0_ready, r1_ready;
logic [63:0]  wcmd_addr, r0_addr, r1_addr;
logic [12:0]  wcmd_len, r0_len, r1_len;
logic [511:0] wdat_tdata;
logic [63:0]  wdat_tkeep;
logic         wdat_tvalid = 1'b0, wdat_tlast;
wire  logic   wdat_tready;
wire  logic [511:0] r0_tdata, r1_tdata;
wire  logic   r0_tvalid, r1_tvalid;
logic         r0_tready = 1'b0, r1_tready = 1'b0;

wire logic [1:0]  awid, bid, arid, rid;
wire logic [63:0] awaddr, araddr;
wire logic [7:0]  awlen, arlen;
wire logic [2:0]  awsize, arsize, awprot, arprot;
wire logic [1:0]  awburst, arburst, bresp, rresp;
wire logic [3:0]  awcache, arcache;
wire logic        awlock, arlock, awvalid, awready, wlast, wvalid, wready, bvalid, bready;
wire logic        arvalid, arready, rlast, rvalid, rready;
wire logic [511:0] wdata, rdata;
wire logic [63:0] wstrb;

rocelet_axi_mem #(.ADDR_W(64), .ID_W(2), .RD_BUF(128), .RD1_EN(1'b1)) dut (
    .clk(clk), .rst(rst),
    .s_wcmd_valid(wcmd_valid), .s_wcmd_ready(wcmd_ready), .s_wcmd_addr(wcmd_addr), .s_wcmd_len(wcmd_len),
    .s_wdat_tdata(wdat_tdata), .s_wdat_tkeep(wdat_tkeep), .s_wdat_tvalid(wdat_tvalid), .s_wdat_tready(wdat_tready),
    .s_wdat_tlast(wdat_tlast),
    .s_r0cmd_valid(r0_valid), .s_r0cmd_ready(r0_ready), .s_r0cmd_addr(r0_addr), .s_r0cmd_len(r0_len),
    .m_r0dat_tdata(r0_tdata), .m_r0dat_tvalid(r0_tvalid), .m_r0dat_tready(r0_tready),
    .s_r1cmd_valid(r1_valid), .s_r1cmd_ready(r1_ready), .s_r1cmd_addr(r1_addr), .s_r1cmd_len(r1_len),
    .m_r1dat_tdata(r1_tdata), .m_r1dat_tvalid(r1_tvalid), .m_r1dat_tready(r1_tready),
    .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
    .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awcache(awcache), .m_axi_awprot(awprot),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
    .m_axi_arburst(arburst), .m_axi_arlock(arlock), .m_axi_arcache(arcache), .m_axi_arprot(arprot),
    .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid),
    .m_axi_rready(rready),
    .ev_wr_err(), .ev_rd_err()
);

axi_slave_model #(.ADDR_W(64), .ID_W(2)) u_slave (
    .clk(clk), .rst(rst),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid),
    .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arvalid(arvalid),
    .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
);

// reference memory (bytes; unwritten = the slave's pattern)
byte unsigned ref_mem [longint unsigned];
function automatic byte unsigned ref_rd(input longint unsigned a);
    if (ref_mem.exists(a)) return ref_mem[a];
    return 8'(a ^ (a >> 8) ^ 8'h5A);
endfunction

int errors = 0, n = 200, seed = 1, n_w = 0, n_r0 = 0, n_r1 = 0, r0_pend = 0;
logic [511:0] exp0 [$], exp1 [$];
// regions (16 x 16 KB) and whether a source-0 read of each is pending
int busy [16];

initial begin
    if (!$value$plusargs("n=%d", n)) n = 200;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    errors = $urandom(seed) * 0;
    for (int i = 0; i < 16; i++) busy[i] = 0;
    repeat (8) @(posedge clk);
    rst <= 1'b0;
end

// write commands + data (data stream follows the command, as the engine does)
logic [511:0] wq [$];
logic [63:0]  wk [$];
logic         wl [$];
initial begin
    wait (!rst);
    repeat (10) @(posedge clk);
    for (int i = 0; i < n; i++) begin
        int reg_i, len, off;
        longint unsigned a;
        forever begin
            reg_i = $urandom_range(15, 0);
            if (busy[reg_i] == 0) break;
            @(posedge clk);
        end
        len = ($urandom_range(3, 0) == 0) ? $urandom_range(64, 1) : $urandom_range(4096, 1);
        off = 64 * $urandom_range(191, 0);              // up to 12 KB into the 16 KB region
        a   = 64'h1000_0000 + reg_i * 16384 + off;
        wcmd_valid <= 1'b1; wcmd_addr <= a; wcmd_len <= len;
        @(posedge clk);
        while (!wcmd_ready) @(posedge clk);
        wcmd_valid <= 1'b0;
        // the data, and the reference update at command acceptance
        for (int b = 0; b < (len + 63) / 64; b++) begin
            logic [511:0] d; logic [63:0] k;
            for (int j = 0; j < 64; j++) begin
                d[j*8 +: 8] = $urandom_range(255, 0);
                k[j] = (64 * b + j < len);
                if (k[j]) ref_mem[a + 64 * b + j] = d[j*8 +: 8];
            end
            wq.push_back(d); wk.push_back(k); wl.push_back(b == (len + 63) / 64 - 1);
        end
        n_w++;
        repeat ($urandom_range(6, 0)) @(posedge clk);
    end
end
always @(posedge clk) begin
    if (wdat_tvalid && wdat_tready) begin
        void'(wq.pop_front()); void'(wk.pop_front()); void'(wl.pop_front());
    end
    if (!wdat_tvalid || wdat_tready) begin
        if (wq.size() > 0) begin
            wdat_tvalid <= 1'b1;
            wdat_tdata  <= wq[0];
            wdat_tkeep  <= wk[0];
            wdat_tlast  <= wl[0];
        end else begin
            wdat_tvalid <= 1'b0;
        end
    end
end

// source-0 reads of written regions (expected data snapshot at command acceptance)
int r0_reg [$];
int r0_beats [$];
initial begin
    wait (!rst);
    repeat (30) @(posedge clk);
    for (int i = 0; i < n; i++) begin
        int reg_i, len, off;
        longint unsigned a;
        reg_i = $urandom_range(15, 0);
        len = $urandom_range(4096, 1);
        off = 64 * $urandom_range(191, 0);
        a   = 64'h1000_0000 + reg_i * 16384 + off;
        busy[reg_i]++;
        r0_valid <= 1'b1; r0_addr <= a; r0_len <= len;
        @(posedge clk);
        while (!r0_ready) @(posedge clk);
        r0_valid <= 1'b0;
        for (int b = 0; b < (len + 63) / 64; b++) begin
            logic [511:0] d;
            for (int j = 0; j < 64; j++) d[j*8 +: 8] = (64 * b + j < len) ? ref_rd(a + 64 * b + j) : 8'h00;
            exp0.push_back(d);
        end
        r0_reg.push_back(reg_i);
        r0_beats.push_back((len + 63) / 64);
        n_r0++;
        repeat ($urandom_range(10, 0)) @(posedge clk);
    end
end
// source-1 reads of the pattern region
initial begin
    wait (!rst);
    repeat (20) @(posedge clk);
    for (int i = 0; i < n; i++) begin
        int len;
        longint unsigned a;
        len = $urandom_range(4096, 1);
        a   = 64'h8000_0000 + 64 * $urandom_range(100000, 0);
        r1_valid <= 1'b1; r1_addr <= a; r1_len <= len;
        @(posedge clk);
        while (!r1_ready) @(posedge clk);
        r1_valid <= 1'b0;
        for (int b = 0; b < (len + 63) / 64; b++) begin
            logic [511:0] d;
            for (int j = 0; j < 64; j++) d[j*8 +: 8] = (64 * b + j < len) ? ref_rd(a + 64 * b + j) : 8'h00;
            exp1.push_back(d);
        end
        n_r1++;
        repeat ($urandom_range(10, 0)) @(posedge clk);
    end
end

function automatic bit beat_eq(input logic [511:0] got, input logic [511:0] e);
    // bytes past the packet end are don't-care: the expected beat has them 0
    for (int j = 0; j < 64; j++) if (e[j*8 +: 8] != 8'h00 && got[j*8 +: 8] != e[j*8 +: 8]) return 0;
    return 1;
endfunction

int r0_cnt = 0;
always @(posedge clk) begin
    r0_tready <= ($urandom_range(99, 0) >= 30);
    r1_tready <= ($urandom_range(99, 0) >= 30);
    if (r0_tvalid && r0_tready) begin
        if (exp0.size() == 0 || !beat_eq(r0_tdata, exp0[0])) begin
            if (errors < 5) $display("TB_ERROR read0 data mismatch");
            errors++;
        end
        if (exp0.size()) void'(exp0.pop_front());
        r0_cnt++;
        if (r0_cnt == r0_beats[0]) begin
            busy[r0_reg[0]]--;
            void'(r0_reg.pop_front()); void'(r0_beats.pop_front());
            r0_cnt = 0;
        end
    end
    if (r1_tvalid && r1_tready) begin
        if (exp1.size() == 0 || !beat_eq(r1_tdata, exp1[0])) begin
            if (errors < 5) $display("TB_ERROR read1 data mismatch");
            errors++;
        end
        if (exp1.size()) void'(exp1.pop_front());
    end
end

initial begin
    wait (!rst);
    wait (n_w == n && n_r0 == n && n_r1 == n);
    repeat (2000) @(posedge clk);
    if (exp0.size() || exp1.size() || wq.size()) begin
        $display("TB_ERROR left over: %0d %0d %0d", exp0.size(), exp1.size(), wq.size());
        errors++;
    end
    // final memory image
    foreach (ref_mem[a]) if (u_slave.rd_byte(a) != ref_mem[a]) begin
        if (errors < 8) $display("TB_ERROR memory @%0h", a);
        errors++;
    end
    $display("TB_DONE writes=%0d reads0=%0d reads1=%0d wbursts=%0d rbursts=%0d errors=%0d", n_w, n_r0, n_r1,
             u_slave.n_wbursts, u_slave.n_rbursts, errors + u_slave.errors);
    $finish;
end

initial begin
    #20ms;
    $display("TB_TIMEOUT");
    $finish;
end

endmodule
