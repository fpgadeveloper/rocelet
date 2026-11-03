// SPDX-License-Identifier: MIT
//
// tb_core_pair - two rocelet_core instances back to back through a lossy link model:
// engine A (requester, RTX_MODE under test) writes into engine B (responder). Every
// frame is dropped with probability +drop=<per mille> in each direction. B's SEND sink
// signals "no receive buffer" (send_rnr) at random (+rnr=<per mille of 64-cycle slots>),
// so A sees RNR NAKs. +ferr_qp / +ferr_at=<completions>: put A's QP ferr_qp into the
// error state once that many completions arrived (its later WRs complete FLUSHED).
// Link loss: +ld_at=<completions> takes the link down (every frame lost both ways) for
// +ld_clk clocks, then keeps losing frames for +ld_silent clocks after A's link_up rose
// (the link partner still coming up); +ld_hold=1 drives A's link_up with the outage
// (ACK timeouts held, +grace ticks of LINK_GRACE), 0 leaves it high (v0.1 behaviour).
// A's timer: +tick clocks per tick, +to ticks ACK timeout.
// Files in +dir=: wr.txt (A's WRs: qp class va rkey len imm id flags), pay.txt (payload
// beats), cfg.txt (per QP: psn pmtu type), mr.txt (B's window).
// Logs: a_cpl.txt, a_err.txt, a_tx.txt, b_wr.txt, b_send.txt, b_cpl.txt, b_err.txt, b_tx.txt.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_core_pair
    import rocelet_pkg::*;
#(
    parameter int NUM_QP     = 4,
    parameter     RTX_MODE   = "RING",
    parameter int RING_BYTES = 65536,
    parameter int MAX_WR     = 32
);
localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1;

logic clk = 1'b0, rst = 1'b1;
always #1.551 clk = ~clk;

localparam logic [47:0] MAC_A = 48'h02_00_00_00_00_0A, MAC_B = 48'h02_00_00_00_00_0B;
localparam logic [31:0] IP_A = 32'hC0A8020A, IP_B = 32'hC0A8020B;

// QP config (same index on both sides)
logic           cfg_we = 1'b0;
logic [QPW-1:0] cfg_qp;
logic [23:0]    cfg_psn;
logic [3:0]     cfg_pmtu;
logic [1:0]     cfg_type;
logic           mr_we = 1'b0;
logic [31:0]    mr_rkey, mr_len;
logic [63:0]    mr_va, mr_laddr;
logic           ferr_we = 1'b0;
logic [QPW-1:0] ferr_qp_r = '0;

// links
logic [511:0] ab_tdata, ba_tdata, a_rx_tdata = '0, b_rx_tdata = '0;
logic [63:0]  ab_tkeep, ba_tkeep, a_rx_tkeep = '0, b_rx_tkeep = '0;
logic         ab_tvalid, ab_tlast, ba_tvalid, ba_tlast;
logic         a_rx_tvalid = 1'b0, a_rx_tlast = 1'b0, b_rx_tvalid = 1'b0, b_rx_tlast = 1'b0;
wire  logic   a_rx_tready, b_rx_tready;
logic         ab_tready = 1'b1, ba_tready = 1'b1;

// A requester side
logic           wr_valid = 1'b0;
wire  logic     wr_ready;
logic [QPW-1:0] wr_qp;
logic [1:0]     wr_class;
logic           wr_se, wr_md;
logic [63:0]    wr_va;
logic [31:0]    wr_rkey, wr_len, wr_imm;
logic [15:0]    wr_id;
logic [511:0]   pay_data;
logic           pay_valid = 1'b0, pay_last = 1'b0;
wire  logic     pay_ready;
wire  logic     a_wc_valid, a_err_valid;
wire  logic [QPW-1:0] a_wc_qp, a_err_qp;
wire  logic [15:0] a_wc_id;
wire  logic [7:0]  a_wc_status, a_err_code;
// requester memory reads (REREAD): memory pattern of the address
wire  logic        qrd_valid; logic qrd_ready = 1'b1;
wire  logic [63:0] qrd_addr; wire logic [12:0] qrd_len;
logic [511:0]      qrd_tdata; logic qrd_tvalid = 1'b0; wire logic qrd_tready;
core_ev_t          a_ev, b_ev;

// B responder side
wire  logic         wcmd_valid; logic wcmd_ready = 1'b1;
wire  logic [63:0]  wcmd_addr;  wire logic [12:0] wcmd_len;
wire  logic [511:0] wdat_tdata; wire logic [63:0] wdat_tkeep;
wire  logic         wdat_tvalid, wdat_tlast; logic wdat_tready = 1'b1;
wire  logic [511:0] send_tdata; wire logic [63:0] send_tkeep;
wire  logic         send_tvalid, send_tlast, send_som, send_eom, send_end_valid, send_end_ok;
wire  logic [QPW-1:0] send_qp, b_cpl_qp, b_err_qp;
wire  logic         b_cpl_valid, b_cpl_send, b_cpl_has_imm, b_err_valid;
wire  logic [31:0]  b_cpl_imm, b_cpl_len;
wire  logic [7:0]   b_err_syn;
logic [NUM_QP-1:0]  send_rnr = '0;
logic [19:0]        pace_inc = '0;
logic [4:0]         b_rnr_code = 5'd1;
logic [19:0]        a_rnr_max = 20'd2000;
logic [9:0]         a_tick = 10'd16;
logic [19:0]        a_to = 20'd300;
logic [23:0]        a_grace = '0;
logic               a_link = 1'b1;
wire  logic         a_hold;

rocelet_core #(
    .NUM_QP(NUM_QP), .NUM_MR(1), .QPN_BASE(24'h000100), .READ_DEPTH(4), .RTX_MODE(RTX_MODE),
    .RING_BYTES(RING_BYTES), .RING_RAM("block"), .MAX_WR(MAX_WR), .HSB_EN(1'b1)
) eng_a (
    .clk(clk), .rst(rst), .my_mac(MAC_A), .my_ip4(IP_A), .my_ip6('0), .ip_tos(8'h00), .ip_ttl(8'd64),
    .cfg_tick_div(a_tick), .cfg_timeout(a_to), .cfg_rnr_min(20'd1), .cfg_rnr_max(a_rnr_max),
    .cfg_retry_cnt(3'd7), .cfg_rnr_retry(3'd7), .cfg_rnr_timer(5'd1), .cfg_ackreq_n(8'd4),
    .cfg_read_cont(1'b1), .cfg_loss_fatal(1'b0), .cfg_pace_inc(pace_inc), .cfg_pace_burst(16'd16384),
    .cfg_link_grace(a_grace), .link_up(a_link), .stat_timer_hold(a_hold),
    .cfg_qp_we(cfg_we), .cfg_qp(cfg_qp), .cfg_qp_valid(1'b1), .cfg_qp_type(cfg_type),
    .cfg_qp_sq_psn(cfg_psn), .cfg_qp_rq_psn('0), .cfg_qp_pmtu(cfg_pmtu), .cfg_qp_ipv6(1'b0),
    .cfg_qp_dmac(MAC_B), .cfg_qp_dip({96'd0, IP_B}), .cfg_qp_dqpn(24'h000200 + 24'(cfg_qp)),
    .cfg_qp_sport(16'hC000 + 16'(cfg_qp)), .cfg_qp_dport(16'd0),
    .cfg_err_we(ferr_we), .cfg_err_qp(ferr_qp_r),
    .cfg_mr_we(1'b0), .cfg_mr_idx('0), .cfg_mr_valid(1'b0), .cfg_mr_rkey('0), .cfg_mr_va('0),
    .cfg_mr_len('0), .cfg_mr_laddr('0), .cfg_mr_acc('0),
    .s_rx_tdata(a_rx_tdata), .s_rx_tkeep(a_rx_tkeep), .s_rx_tvalid(a_rx_tvalid), .s_rx_tready(a_rx_tready),
    .s_rx_tlast(a_rx_tlast),
    .m_tx_tdata(ab_tdata), .m_tx_tkeep(ab_tkeep), .m_tx_tvalid(ab_tvalid), .m_tx_tready(ab_tready),
    .m_tx_tlast(ab_tlast),
    .s_wr_valid(wr_valid), .s_wr_ready(wr_ready), .s_wr_qp(wr_qp), .s_wr_class(wr_class),
    .s_wr_se(wr_se), .s_wr_md(wr_md), .s_wr_va(wr_va), .s_wr_rkey(wr_rkey), .s_wr_len(wr_len),
    .s_wr_imm(wr_imm), .s_wr_laddr(64'h0000_1000_0000_0000 + 64'(wr_id) * 64'h10000), .s_wr_id(wr_id),
    .s_wpay_tdata(pay_data), .s_wpay_tvalid(pay_valid), .s_wpay_tready(pay_ready), .s_wpay_tlast(pay_last),
    .m_wc_valid(a_wc_valid), .m_wc_ready(1'b1), .m_wc_qp(a_wc_qp), .m_wc_id(a_wc_id),
    .m_wc_status(a_wc_status),
    .m_qrd_valid(qrd_valid), .m_qrd_ready(qrd_ready), .m_qrd_addr(qrd_addr), .m_qrd_len(qrd_len),
    .s_qrd_tdata(qrd_tdata), .s_qrd_tvalid(qrd_tvalid), .s_qrd_tready(qrd_tready),
    .m_wcmd_valid(), .m_wcmd_ready(1'b1), .m_wcmd_addr(), .m_wcmd_len(),
    .m_wdat_tdata(), .m_wdat_tkeep(), .m_wdat_tvalid(), .m_wdat_tready(1'b1), .m_wdat_tlast(),
    .m_rcmd_valid(), .m_rcmd_ready(1'b1), .m_rcmd_addr(), .m_rcmd_len(),
    .s_rdat_tdata('0), .s_rdat_tvalid(1'b0), .s_rdat_tready(),
    .m_send_tdata(), .m_send_tkeep(), .m_send_tvalid(), .m_send_tready(1'b1), .m_send_tlast(),
    .m_send_qp(), .m_send_som(), .m_send_eom(), .m_send_end_valid(), .m_send_end_ok(),
    .send_rnr('0),
    .m_rc_valid(), .m_rc_ready(1'b1), .m_rc_qp(), .m_rc_send(), .m_rc_has_imm(), .m_rc_imm(), .m_rc_len(),
    .qp_err_req(), .qp_err_resp(),
    .m_req_err_valid(a_err_valid), .m_req_err_qp(a_err_qp), .m_req_err_code(a_err_code),
    .m_resp_err_valid(), .m_resp_err_qp(), .m_resp_err_code(),
    .stat_wr_outstanding(), .stat_ring_used(), .ev(a_ev)
);

rocelet_core #(
    .NUM_QP(NUM_QP), .NUM_MR(1), .QPN_BASE(24'h000200), .READ_DEPTH(4), .RTX_MODE("RING"),
    .RING_BYTES(65536), .RING_RAM("block"), .MAX_WR(16)
) eng_b (
    .clk(clk), .rst(rst), .my_mac(MAC_B), .my_ip4(IP_B), .my_ip6('0), .ip_tos(8'h00), .ip_ttl(8'd64),
    .cfg_tick_div(10'd16), .cfg_timeout(20'd300), .cfg_rnr_min(20'd1), .cfg_rnr_max(20'd2000),
    .cfg_retry_cnt(3'd7), .cfg_rnr_retry(3'd7), .cfg_rnr_timer(b_rnr_code), .cfg_ackreq_n(8'd0),
    .cfg_read_cont(1'b1), .cfg_loss_fatal(1'b0), .cfg_pace_inc(pace_inc), .cfg_pace_burst(16'd16384),
    .cfg_link_grace('0), .link_up(1'b1), .stat_timer_hold(),
    .cfg_qp_we(cfg_we), .cfg_qp(cfg_qp), .cfg_qp_valid(1'b1), .cfg_qp_type(QPT_RC),
    .cfg_qp_sq_psn('0), .cfg_qp_rq_psn(cfg_psn), .cfg_qp_pmtu(cfg_pmtu), .cfg_qp_ipv6(1'b0),
    .cfg_qp_dmac(MAC_A), .cfg_qp_dip({96'd0, IP_A}), .cfg_qp_dqpn(24'h000100 + 24'(cfg_qp)),
    .cfg_qp_sport(16'hD000 + 16'(cfg_qp)), .cfg_qp_dport(16'd0),
    .cfg_err_we(1'b0), .cfg_err_qp('0),
    .cfg_mr_we(mr_we), .cfg_mr_idx('0), .cfg_mr_valid(1'b1), .cfg_mr_rkey(mr_rkey), .cfg_mr_va(mr_va),
    .cfg_mr_len(mr_len), .cfg_mr_laddr(mr_laddr), .cfg_mr_acc(2'b11),
    .s_rx_tdata(b_rx_tdata), .s_rx_tkeep(b_rx_tkeep), .s_rx_tvalid(b_rx_tvalid), .s_rx_tready(b_rx_tready),
    .s_rx_tlast(b_rx_tlast),
    .m_tx_tdata(ba_tdata), .m_tx_tkeep(ba_tkeep), .m_tx_tvalid(ba_tvalid), .m_tx_tready(ba_tready),
    .m_tx_tlast(ba_tlast),
    .s_wr_valid(1'b0), .s_wr_ready(), .s_wr_qp('0), .s_wr_class('0), .s_wr_se(1'b0), .s_wr_md(1'b0),
    .s_wr_va('0), .s_wr_rkey('0), .s_wr_len('0), .s_wr_imm('0), .s_wr_laddr('0), .s_wr_id('0),
    .s_wpay_tdata('0), .s_wpay_tvalid(1'b0), .s_wpay_tready(), .s_wpay_tlast(1'b0),
    .m_wc_valid(), .m_wc_ready(1'b1), .m_wc_qp(), .m_wc_id(), .m_wc_status(),
    .m_qrd_valid(), .m_qrd_ready(1'b1), .m_qrd_addr(), .m_qrd_len(),
    .s_qrd_tdata('0), .s_qrd_tvalid(1'b0), .s_qrd_tready(),
    .m_wcmd_valid(wcmd_valid), .m_wcmd_ready(wcmd_ready), .m_wcmd_addr(wcmd_addr), .m_wcmd_len(wcmd_len),
    .m_wdat_tdata(wdat_tdata), .m_wdat_tkeep(wdat_tkeep), .m_wdat_tvalid(wdat_tvalid),
    .m_wdat_tready(wdat_tready), .m_wdat_tlast(wdat_tlast),
    .m_rcmd_valid(), .m_rcmd_ready(1'b1), .m_rcmd_addr(), .m_rcmd_len(),
    .s_rdat_tdata('0), .s_rdat_tvalid(1'b0), .s_rdat_tready(),
    .m_send_tdata(send_tdata), .m_send_tkeep(send_tkeep), .m_send_tvalid(send_tvalid),
    .m_send_tready(1'b1), .m_send_tlast(send_tlast), .m_send_qp(send_qp), .m_send_som(send_som),
    .m_send_eom(send_eom), .m_send_end_valid(send_end_valid), .m_send_end_ok(send_end_ok),
    .send_rnr(send_rnr),
    .m_rc_valid(b_cpl_valid), .m_rc_ready(1'b1), .m_rc_qp(b_cpl_qp), .m_rc_send(b_cpl_send),
    .m_rc_has_imm(b_cpl_has_imm), .m_rc_imm(b_cpl_imm), .m_rc_len(b_cpl_len),
    .qp_err_req(), .qp_err_resp(),
    .m_req_err_valid(), .m_req_err_qp(), .m_req_err_code(),
    .m_resp_err_valid(b_err_valid), .m_resp_err_qp(b_err_qp), .m_resp_err_code(b_err_syn),
    .stat_wr_outstanding(), .stat_ring_used(), .ev(b_ev)
);

string  dir;
integer seed, drop, rnr, r, fa_cpl, fa_err, fb_wr, fb_send, fb_cpl, fb_err, nwr_exp, fa_tx, fb_tx;
integer ferr_qp, ferr_at, pace, rnr_code, rnr_max, ld_at, ld_hold, tick, to, grace;
longint ld_clk, ld_silent;
int     n_ab = 0, n_ba = 0, d_ab = 0, d_ba = 0, n_cpl = 0;
int     n_rnr_rx = 0, n_rnr_tx = 0, n_rtx = 0, n_to = 0, n_cont = 0, n_ld = 0;
longint ab_bytes = 0, ab_first = -1, ab_last = 0, cyc = 0;
bit     cfg_done = 0, wr_done = 0, ferr_done = 0;

function automatic int urand1000();
    return $urandom_range(999, 0);
endfunction

function automatic int popc(input logic [63:0] k);
    int c = 0;
    for (int i = 0; i < 64; i++) c += k[i];
    return c;
endfunction

initial begin
    integer fd, q, ps, pm, ty;
    if (!$value$plusargs("dir=%s", dir)) dir = ".";
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("drop=%d", drop)) drop = 20;
    if (!$value$plusargs("rnr=%d", rnr)) rnr = 0;
    if (!$value$plusargs("nwr=%d", nwr_exp)) nwr_exp = 0;
    if (!$value$plusargs("ferr_qp=%d", ferr_qp)) ferr_qp = -1;
    if (!$value$plusargs("ferr_at=%d", ferr_at)) ferr_at = 0;
    if (!$value$plusargs("pace=%d", pace)) pace = 0;
    if (!$value$plusargs("rnr_code=%d", rnr_code)) rnr_code = 1;
    if (!$value$plusargs("rnr_max=%d", rnr_max)) rnr_max = 2000;
    if (!$value$plusargs("ld_at=%d", ld_at)) ld_at = -1;
    if (!$value$plusargs("ld_clk=%d", ld_clk)) ld_clk = 0;
    if (!$value$plusargs("ld_silent=%d", ld_silent)) ld_silent = 0;
    if (!$value$plusargs("ld_hold=%d", ld_hold)) ld_hold = 1;
    if (!$value$plusargs("tick=%d", tick)) tick = 16;
    if (!$value$plusargs("to=%d", to)) to = 300;
    if (!$value$plusargs("grace=%d", grace)) grace = 0;
    a_tick = tick;
    a_to = to;
    a_grace = grace;
    pace_inc = pace;
    b_rnr_code = rnr_code;
    a_rnr_max = rnr_max;
    r = $urandom(seed);
    fa_cpl = $fopen({dir, "/a_cpl.txt"}, "w"); fa_err = $fopen({dir, "/a_err.txt"}, "w");
    fb_wr = $fopen({dir, "/b_wr.txt"}, "w"); fb_send = $fopen({dir, "/b_send.txt"}, "w");
    fb_cpl = $fopen({dir, "/b_cpl.txt"}, "w"); fb_err = $fopen({dir, "/b_err.txt"}, "w");
    fa_tx = $fopen({dir, "/a_tx.txt"}, "w"); fb_tx = $fopen({dir, "/b_tx.txt"}, "w");
    repeat (8) @(posedge clk);
    rst <= 1'b0;
    repeat (4) @(posedge clk);
    fd = $fopen({dir, "/cfg.txt"}, "r");
    while ($fscanf(fd, "%h %h %h %h\n", q, ps, pm, ty) == 4) begin
        cfg_we <= 1'b1; cfg_qp <= q; cfg_psn <= ps; cfg_pmtu <= pm; cfg_type <= ty;
        @(posedge clk); cfg_we <= 1'b0; repeat (6) @(posedge clk);
    end
    $fclose(fd);
    fd = $fopen({dir, "/mr.txt"}, "r");
    r = $fscanf(fd, "%h %h %h %h\n", mr_rkey, mr_va, mr_len, mr_laddr);
    $fclose(fd);
    mr_we <= 1'b1; @(posedge clk); mr_we <= 1'b0; repeat (4) @(posedge clk);
    cfg_done = 1;
end

// A: work requests and payload
initial begin
    integer fd, q, c, fl;
    logic [63:0] va; logic [31:0] rk, ln, im; logic [15:0] id;
    wait (cfg_done);
    fd = $fopen({dir, "/wr.txt"}, "r");
    while ($fscanf(fd, "%h %h %h %h %h %h %h %h\n", q, c, va, rk, ln, im, id, fl) == 8) begin
        while (urand1000() < 200) @(posedge clk);
        wr_valid <= 1'b1; wr_qp <= q; wr_class <= c; wr_va <= va; wr_rkey <= rk; wr_len <= ln;
        wr_imm <= im; wr_id <= id; wr_se <= fl[0]; wr_md <= fl[1];
        @(posedge clk);
        while (!wr_ready) @(posedge clk);
        wr_valid <= 1'b0;
    end
    $fclose(fd);
    wr_done = 1;
end
initial begin
    integer fd, l;
    logic [511:0] d;
    wait (cfg_done);
    fd = $fopen({dir, "/pay.txt"}, "r");
    while ($fscanf(fd, "%d %h\n", l, d) == 2) begin
        pay_valid <= 1'b1; pay_data <= d; pay_last <= l[0];
        @(posedge clk);
        while (!pay_ready) @(posedge clk);
    end
    pay_valid <= 1'b0;
    $fclose(fd);
end

// A memory reads (REREAD): data = pattern of the local address (wr_id * 64K + offset)
logic [63:0] qa [$];
logic [12:0] ql [$];
always @(posedge clk) if (qrd_valid && qrd_ready) begin qa.push_back(qrd_addr); ql.push_back(qrd_len); end
initial begin
    logic [63:0] a; logic [12:0] l;
    forever begin
        @(posedge clk);
        if (qa.size() > 0) begin
            a = qa.pop_front(); l = ql.pop_front();
            for (int b = 0; b < (l + 63) / 64; b++) begin
                for (int j = 0; j < 64; j++) begin
                    logic [63:0] ba; ba = a + 64 * b + j;
                    qrd_tdata[j*8 +: 8] <= ba[7:0] ^ ba[23:16] ^ 8'h3C;
                end
                qrd_tvalid <= 1'b1;
                @(posedge clk);
                while (!qrd_tready) @(posedge clk);
            end
            qrd_tvalid <= 1'b0;
        end
    end
end

// B: no receive buffer now and then (64-cycle slots per QP)
int slot = 0;
always @(posedge clk) begin
    slot <= (slot == 63) ? 0 : slot + 1;
    if (slot == 0 && rnr > 0) begin
        for (int q = 0; q < NUM_QP; q++) send_rnr[q] <= (urand1000() < rnr);
    end
end

// forced error on A
always @(posedge clk) begin
    ferr_we <= 1'b0;
    if (!ferr_done && ferr_qp >= 0 && n_cpl >= ferr_at && cfg_done) begin
        ferr_we   <= 1'b1;
        ferr_qp_r <= ferr_qp;
        ferr_done = 1;
    end
end

// ---------------- link loss: 0 up, 1 down, 2 up at A but the partner silent, 3 up again ----------------
int     ld_ph = 0, to_hold = 0, to_after = 0, ld_lost = 0, hold_seen = 0;
longint ld_t0 = 0, t_unhold = -1, to_lat = -1;
logic   a_hold_q = 1'b0;
always @(posedge clk) begin
    case (ld_ph)
        0: if (ld_at >= 0 && n_cpl >= ld_at && cfg_done) begin ld_ph = 1; ld_t0 = cyc; end
        1: if (cyc - ld_t0 >= ld_clk) begin ld_ph = 2; ld_t0 = cyc; end
        2: if (cyc - ld_t0 >= ld_silent) ld_ph = 3;
        default: ;
    endcase
    a_link <= !(ld_hold && ld_ph == 1);
    if (a_ev.req_timeout) begin
        if (ld_ph == 1 || ld_ph == 2) to_hold++;
        if (ld_ph == 3) to_after++;
    end
    if (a_hold) hold_seen = 1;
    a_hold_q <= a_hold;
    if (a_hold_q && !a_hold) t_unhold = cyc;              // hold ended (grace expired)
    if (a_ev.req_timeout && t_unhold >= 0 && to_lat < 0) to_lat = cyc - t_unhold;
end
wire logic link_dead = (ld_ph == 1 || ld_ph == 2);

// ---------------- lossy links (frame granularity) ----------------
// (separate queues per field: xsim mangles 512-bit members of queued structs)
logic [511:0] qd_ab [$], qd_ba [$], fd_ab [$], fd_ba [$];
logic [63:0]  qk_ab [$], qk_ba [$], fk_ab [$], fk_ba [$];
logic         ql_ab [$], ql_ba [$], fl_ab [$], fl_ba [$];
always @(posedge clk) begin
    if (ab_tvalid && ab_tready) begin
        fd_ab.push_back(ab_tdata); fk_ab.push_back(ab_tkeep); fl_ab.push_back(ab_tlast);
        if (ab_tlast) begin
            n_ab++;
            if (link_dead) begin
                ld_lost++; fd_ab.delete(); fk_ab.delete(); fl_ab.delete();
            end else if (urand1000() >= drop) begin
                while (fd_ab.size()) begin
                    qd_ab.push_back(fd_ab.pop_front()); qk_ab.push_back(fk_ab.pop_front()); ql_ab.push_back(fl_ab.pop_front());
                end
            end else begin
                d_ab++; fd_ab.delete(); fk_ab.delete(); fl_ab.delete();
            end
        end
    end
    if (ba_tvalid && ba_tready) begin
        fd_ba.push_back(ba_tdata); fk_ba.push_back(ba_tkeep); fl_ba.push_back(ba_tlast);
        if (ba_tlast) begin
            n_ba++;
            if (link_dead) begin
                ld_lost++; fd_ba.delete(); fk_ba.delete(); fl_ba.delete();
            end else if (urand1000() >= drop) begin
                while (fd_ba.size()) begin
                    qd_ba.push_back(fd_ba.pop_front()); qk_ba.push_back(fk_ba.pop_front()); ql_ba.push_back(fl_ba.pop_front());
                end
            end else begin
                d_ba++; fd_ba.delete(); fk_ba.delete(); fl_ba.delete();
            end
        end
    end
end
always @(posedge clk) begin
    if (!b_rx_tvalid || b_rx_tready) begin
        if (qd_ab.size()) begin
            b_rx_tdata <= qd_ab.pop_front(); b_rx_tkeep <= qk_ab.pop_front(); b_rx_tlast <= ql_ab.pop_front();
            b_rx_tvalid <= 1'b1;
        end else b_rx_tvalid <= 1'b0;
    end
    if (!a_rx_tvalid || a_rx_tready) begin
        if (qd_ba.size()) begin
            a_rx_tdata <= qd_ba.pop_front(); a_rx_tkeep <= qk_ba.pop_front(); a_rx_tlast <= ql_ba.pop_front();
            a_rx_tvalid <= 1'b1;
        end else a_rx_tvalid <= 1'b0;
    end
end

// ---------------- logs ----------------
always @(posedge clk) begin
    cyc <= cyc + 1;
    if (ab_tvalid && ab_tready) begin
        ab_bytes += popc(ab_tkeep);
        if (ab_first < 0) ab_first = cyc;
        ab_last = cyc;
    end
end
always @(posedge clk) begin
    if (ab_tvalid && ab_tready) $fdisplay(fa_tx, "%0d %0d %0128h 0", ab_tlast, popc(ab_tkeep), ab_tdata);
    if (ba_tvalid && ba_tready) $fdisplay(fb_tx, "%0d %0d %0128h 0", ba_tlast, popc(ba_tkeep), ba_tdata);
    if (a_wc_valid) begin $fdisplay(fa_cpl, "%0d %0d %0d", a_wc_qp, a_wc_id, a_wc_status); n_cpl++; end
    if (a_err_valid) $fdisplay(fa_err, "%0d %02h", a_err_qp, a_err_code);
    if (wcmd_valid && wcmd_ready) $fdisplay(fb_wr, "C %0h %0h", wcmd_addr, wcmd_len);
    if (wdat_tvalid && wdat_tready) $fdisplay(fb_wr, "D %0d %0d %0128h", wdat_tlast, popc(wdat_tkeep), wdat_tdata);
    if (send_tvalid) $fdisplay(fb_send, "%0d %0d %0128h %0d %0d %0d", send_tlast, popc(send_tkeep), send_tdata, send_qp, send_som, send_eom);
    if (send_end_valid) $fdisplay(fb_send, "E %0d", send_end_ok);
    if (b_cpl_valid) $fdisplay(fb_cpl, "%0d %0d %0d %08h %0d", b_cpl_qp, b_cpl_send, b_cpl_has_imm, b_cpl_imm, b_cpl_len);
    if (b_err_valid) $fdisplay(fb_err, "%0d %02h", b_err_qp, b_err_syn);
    if (a_ev.rx_rnr_nak) n_rnr_rx++;
    if (b_ev.rx_rnr_sent) n_rnr_tx++;
    if (a_ev.req_rtx) n_rtx++;
    if (a_ev.req_timeout) n_to++;
    if (a_ev.link_down) n_ld++;
end

// RNR wait measured on A, per QP: from a received RNR NAK to the retransmission it causes
longint t_rnr [NUM_QP], rnr_w_min = 64'd1 << 40, rnr_w_max = 0;
initial for (int q = 0; q < NUM_QP; q++) t_rnr[q] = -1;
always @(posedge clk) begin
    if (eng_a.ack_valid && eng_a.ack_syn[7:5] == 3'b001) t_rnr[eng_a.ack_qp] = cyc;
`ifdef RNR_DEBUG
    if (eng_a.ack_valid) $display("%0d A ack qp=%0d psn=%06h syn=%02h", cyc, eng_a.ack_qp, eng_a.ack_psn, eng_a.ack_syn);
    if (eng_a.x_valid && eng_a.xr_ready) $display("%0d A rtx qp=%0d psn=%06h", cyc, eng_a.x_qp, eng_a.x_psn);
    if (eng_a.u_ack.ph == 2 && eng_a.u_ack.b_rtx) $display("%0d A ackproc rtx push qp=%0d ev=%0d", cyc, eng_a.u_ack.a_qp, eng_a.u_ack.a_ev);
`endif
    if (eng_a.x_valid && eng_a.xr_ready && t_rnr[eng_a.x_qp] >= 0) begin
        if (cyc - t_rnr[eng_a.x_qp] < rnr_w_min) rnr_w_min = cyc - t_rnr[eng_a.x_qp];
        if (cyc - t_rnr[eng_a.x_qp] > rnr_w_max) rnr_w_max = cyc - t_rnr[eng_a.x_qp];
        t_rnr[eng_a.x_qp] = -1;
    end
end

int idle = 0;
always @(posedge clk) begin
    if (wr_done) begin
        idle <= (ab_tvalid || ba_tvalid || link_dead || a_hold) ? 0 : idle + 1;
        if (((nwr_exp != 0 && n_cpl >= nwr_exp && idle > 200) || idle > 60000) && !link_dead) begin
            $display("TB_DONE cpl=%0d frames_ab=%0d dropped_ab=%0d frames_ba=%0d dropped_ba=%0d rtx=%0d timeouts=%0d rnr_sent=%0d rnr_rx=%0d rate_x100=%0d rnr_wait=%0d..%0d",
                     n_cpl, n_ab, d_ab, n_ba, d_ba, n_rtx, n_to, n_rnr_tx, n_rnr_rx,
                     (ab_bytes * 100) / (ab_last - ab_first + 1), rnr_w_min, rnr_w_max);
            if (ld_at >= 0)
                $display("TB_LINK phase=%0d lost=%0d timeouts_held=%0d timeouts_after=%0d hold_seen=%0d link_down_ev=%0d to_lat=%0d",
                         ld_ph, ld_lost, to_hold, to_after, hold_seen, n_ld, to_lat);
            $fclose(fa_cpl); $fclose(fa_err); $fclose(fb_wr); $fclose(fb_send); $fclose(fb_cpl); $fclose(fb_err);
            $fclose(fa_tx); $fclose(fb_tx);
            $finish;
        end
    end
end

initial begin
    longint maxus;
    if ($value$plusargs("maxus=%d", maxus)) begin #(maxus * 1us); $display("TB_TIMEOUT cpl=%0d", n_cpl); $finish; end
    #400ms;
    $display("TB_TIMEOUT cpl=%0d", n_cpl);
    $finish;
end

endmodule
