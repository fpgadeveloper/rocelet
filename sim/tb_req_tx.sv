// SPDX-License-Identifier: MIT
//
// tb_req_tx - xsim testbench for the requester TX path: rocelet_req_ctrl (WR segmentation,
// per-QP PSN and type) -> rocelet_tx_builder (headers) -> rocelet_icrc_tx (ICRC), payload
// straight from a stream (no ring, no ACK tracking). Files in +dir=:
//   cfg.txt  qp ipv6 dmac dip dqpn sport dport psn pmtu type   (hex)
//   wr.txt   qp class va rkey len imm laddr id flags            (hex)
//   pay.txt  payload beats (hex)
// Output: out.txt, every frame beat. +ackreq_n=N: AckReq every N packets.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_req_tx
    import rocelet_pkg::*;
#(
    parameter int NUM_QP        = 8,
    parameter bit PMTU_RUNTIME  = 1'b1,
    parameter bit IPV6_EN       = 1'b0,
    parameter bit SHIFT_GENERIC = 1'b0,
    parameter int ICRC_GRAN     = 4,
    parameter int OPSET         = 1,
    parameter bit HSB_EN        = 1'b1
);
localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1;

logic clk = 1'b0, rst = 1'b1;
always #1.551 clk = ~clk;

logic             cfg_we = 1'b0;
logic [QPW-1:0]   cfg_qp;
logic             cfg_ipv6;
logic [47:0]      cfg_dmac;
logic [127:0]     cfg_dip;
logic [23:0]      cfg_dqpn, cfg_psn;
logic [15:0]      cfg_sport, cfg_dport;
logic [3:0]       cfg_pmtu;
logic [1:0]       cfg_type;
logic [7:0]       ackreq_n = 8'd0;

logic             wr_valid = 1'b0;
wire  logic       wr_ready;
logic [QPW-1:0]   wr_qp;
logic [1:0]       wr_class;
logic             wr_se, wr_md;
logic [63:0]      wr_va, wr_laddr;
logic [31:0]      wr_rkey, wr_len, wr_imm;
logic [15:0]      wr_id;

logic [511:0]     pay_data;
logic             pay_valid = 1'b0;
wire  logic       pay_ready;

wire  logic [511:0] m_tdata;
wire  logic [63:0]  m_tkeep;
wire  logic         m_tvalid, m_tlast;
logic               m_tready = 1'b0;

wire  logic         d_valid, d_ready;
tx_desc_t           d_desc;

rocelet_req_ctrl #(
    .NUM_QP(NUM_QP), .PMTU_RUNTIME(PMTU_RUNTIME), .PMTU_LOG2(12), .HSB_EN(HSB_EN),
    .SRC_MM(1'b0), .REXMIT_EN(1'b0), .LOSSY_EN(1'b0)
) u_ctrl (
    .clk(clk), .rst(rst), .cfg_ackreq_n(ackreq_n), .qp_err('0),
    .cfg_we(cfg_we), .cfg_qp(cfg_qp), .cfg_psn(cfg_psn), .cfg_pmtu_log2(cfg_pmtu), .cfg_type(cfg_type),
    .s_wr_valid(wr_valid), .s_wr_ready(wr_ready), .s_wr_qp(wr_qp), .s_wr_class(wr_class),
    .s_wr_se(wr_se), .s_wr_md(wr_md), .s_wr_va(wr_va), .s_wr_rkey(wr_rkey), .s_wr_len(wr_len),
    .s_wr_imm(wr_imm), .s_wr_laddr(wr_laddr), .s_wr_id(wr_id),
    .s_rex_valid(1'b0), .s_rex_ready(), .s_rex_qp('0), .s_rex_class('0), .s_rex_se(1'b0), .s_rex_va('0),
    .s_rex_rkey('0), .s_rex_len('0), .s_rex_imm('0), .s_rex_laddr('0), .s_rex_id('0),
    .s_rex_first_psn('0), .s_rex_start_psn('0),
    .s_ctl_valid(1'b0), .s_ctl_ready(), .s_ctl_qp('0), .s_ctl_psn('0), .s_ctl_probe(1'b0),
    .m_desc_valid(d_valid), .m_desc_ready(d_ready), .m_desc(d_desc), .m_desc_gen(),
    .m_rd_valid(), .m_rd_ready(1'b1), .m_rd_addr(), .m_rd_len(),
    .m_trk_valid(), .m_trk_ready(1'b1), .m_trk_qp(), .m_trk_id(), .m_trk_first_psn(),
    .m_trk_last_psn(), .m_trk_class(), .m_trk_se(), .m_trk_va(), .m_trk_rkey(), .m_trk_len(),
    .m_trk_imm(), .m_trk_laddr()
);

wire logic [511:0] f_tdata;
wire logic [63:0]  f_tkeep;
wire logic         f_tvalid, f_tready, f_tlast;

rocelet_tx_builder #(
    .NUM_QP(NUM_QP), .IPV6_EN(IPV6_EN), .SHIFT_GENERIC(SHIFT_GENERIC), .OPSET(OPSET)
) u_bld (
    .clk(clk), .rst(rst),
    .cfg_we(cfg_we), .cfg_qp(cfg_qp), .cfg_ipv6(cfg_ipv6), .cfg_dmac(cfg_dmac),
    .cfg_dip(cfg_dip), .cfg_dqpn(cfg_dqpn), .cfg_sport(cfg_sport), .cfg_dport(cfg_dport),
    .my_mac(48'h02_00_00_00_00_01), .my_ip4(32'hC0A80201),
    .my_ip6(128'hFE80_0000_0000_0000_0000_0000_C0A8_0201), .ip_tos(8'h00), .ip_ttl(8'd64),
    .s_desc_valid(d_valid), .s_desc_ready(d_ready), .s_desc(d_desc),
    .s_pay_tdata(pay_data), .s_pay_tvalid(pay_valid), .s_pay_tready(pay_ready),
    .m_axis_tdata(f_tdata), .m_axis_tkeep(f_tkeep), .m_axis_tvalid(f_tvalid),
    .m_axis_tready(f_tready), .m_axis_tlast(f_tlast)
);

rocelet_icrc_tx #(.GRAN(ICRC_GRAN), .REM(ICRC_GRAN == 4 ? 2 : 0), .IPV6_EN(IPV6_EN)) u_icrc (
    .clk(clk), .rst(rst), .l3_off(6'd14),
    .s_axis_tdata(f_tdata), .s_axis_tkeep(f_tkeep), .s_axis_tvalid(f_tvalid),
    .s_axis_tready(f_tready), .s_axis_tlast(f_tlast),
    .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready), .m_axis_tlast(m_tlast)
);

string  dir;
integer fdo, seed, gap, bp, r, nwr = 0, nfr = 0, nexp = 0, an;
bit     cfg_done = 1'b0, wr_done = 1'b0, pay_done = 1'b0;

function automatic int urand100();
    return $urandom_range(99, 0);
endfunction

initial begin
    integer fd, q, v6, pm, ty;
    logic [47:0] dm; logic [127:0] di; logic [23:0] dq, ps; logic [15:0] sp, dp;
    if (!$value$plusargs("dir=%s", dir)) dir = ".";
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("gap=%d", gap)) gap = 20;
    if (!$value$plusargs("bp=%d", bp)) bp = 20;
    if (!$value$plusargs("nexp=%d", nexp)) nexp = 0;
    if (!$value$plusargs("ackreq_n=%d", an)) an = 0;
    ackreq_n = an;
    r = $urandom(seed);
    fdo = $fopen({dir, "/out.txt"}, "w");
    fd = $fopen({dir, "/cfg.txt"}, "r");
    repeat (8) @(posedge clk);
    rst <= 1'b0;
    repeat (4) @(posedge clk);
    while ($fscanf(fd, "%h %h %h %h %h %h %h %h %h %h\n", q, v6, dm, di, dq, sp, dp, ps, pm, ty) == 10) begin
        cfg_we <= 1'b1; cfg_qp <= q; cfg_ipv6 <= v6[0]; cfg_dmac <= dm; cfg_dip <= di;
        cfg_dqpn <= dq; cfg_sport <= sp; cfg_dport <= dp; cfg_psn <= ps; cfg_pmtu <= pm; cfg_type <= ty;
        @(posedge clk);
        cfg_we <= 1'b0;
        repeat (3) @(posedge clk);
    end
    $fclose(fd);
    cfg_done = 1'b1;
end

// work requests
initial begin
    integer fd, q, c, fl;
    logic [63:0] va, la; logic [31:0] rk, ln, im; logic [15:0] id;
    wait (cfg_done);
    fd = $fopen({dir, "/wr.txt"}, "r");
    while ($fscanf(fd, "%h %h %h %h %h %h %h %h %h\n", q, c, va, rk, ln, im, la, id, fl) == 9) begin
        while (urand100() < gap) @(posedge clk);
        wr_valid <= 1'b1; wr_qp <= q; wr_class <= c; wr_va <= va; wr_rkey <= rk; wr_len <= ln;
        wr_imm <= im; wr_laddr <= la; wr_id <= id; wr_se <= fl[0]; wr_md <= fl[1];
        @(posedge clk);
        while (!wr_ready) @(posedge clk);
        wr_valid <= 1'b0;
        nwr++;
    end
    $fclose(fd);
    wr_done = 1'b1;
end

// payload
initial begin
    integer fd;
    logic [511:0] d;
    wait (cfg_done);
    fd = $fopen({dir, "/pay.txt"}, "r");
    while ($fscanf(fd, "%h\n", d) == 1) begin
        while (urand100() < gap) begin pay_valid <= 1'b0; @(posedge clk); end
        pay_valid <= 1'b1; pay_data <= d;
        @(posedge clk);
        while (!pay_ready) @(posedge clk);
    end
    pay_valid <= 1'b0;
    $fclose(fd);
    pay_done = 1'b1;
end

function automatic int popc(input logic [63:0] k);
    int c = 0;
    for (int i = 0; i < 64; i++) c += k[i];
    return c;
endfunction

longint cyc = 0, t_first = -1, t_last = 0, nbeats = 0;
always @(posedge clk) begin
    cyc <= cyc + 1;
    if (m_tvalid && m_tready) begin
        if (t_first < 0) t_first = cyc;
        t_last = cyc;
        nbeats++;
    end
end
always @(posedge clk) begin
    if (!rst) m_tready <= (urand100() >= bp);
    if (m_tvalid && m_tready) begin
        $fdisplay(fdo, "%0d %0d %0128h 0", m_tlast, popc(m_tkeep), m_tdata);
        if (m_tlast) nfr++;
    end
end

int idle = 0;
always @(posedge clk) begin
    if (wr_done && pay_done) begin
        idle <= m_tvalid ? 0 : idle + 1;
        if (idle > 300 || (nexp != 0 && nfr == nexp && idle > 20)) begin
            $display("TB_DONE wrs=%0d frames=%0d out_beats=%0d cycles=%0d", nwr, nfr, nbeats, t_last - t_first + 1);
            $fclose(fdo);
            $finish;
        end
    end
end

initial begin
    #100ms;
    $display("TB_TIMEOUT frames=%0d", nfr);
    $finish;
end

endmodule
