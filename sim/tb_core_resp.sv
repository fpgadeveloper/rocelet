// SPDX-License-Identifier: MIT
//
// tb_core_resp - xsim testbench for the responder of rocelet_core. Files in +dir=:
//   cfg_qp.txt  qp valid epsn pmtu ipv6 dmac dip dqpn sport   (hex)
//   cfg_mr.txt  idx valid rkey va len laddr acc                (hex)
//   rx.txt      received frames, one line per beat: last nbytes data(hex) rnr_mask(hex) sync
// send_rnr follows the rnr_mask column; before a frame whose mask differs from the
// current one the testbench waits until the receive path is idle, so every frame is
// judged with its own mask. sync = 1 on a frame: wait until the engine is completely
// idle first (every READ response sent, so the requester may issue READ_DEPTH new
// READs); sync = 2 + n: wait until the engine has sent at least n frames (a closed-loop
// requester model reacting to response n-1, test_read_reissue.py). +read_cont=0/1 sets
// the READ continuation mode.
// Logs: tx.txt (frames sent), wr.txt (memory writes: "C addr len" + "D" data beats),
// send.txt (SEND stream beats + "E ok" verdicts), cpl.txt, ack.txt, err.txt.
// Memory read data is a pattern of the byte address: byte(a) = a ^ (a >> 8) ^ 0x5A.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_core_resp
    import rocelet_pkg::*;
#(
    parameter int NUM_QP       = 8,
    parameter int NUM_MR       = 4,
    parameter bit PMTU_RUNTIME = 1'b1,
    parameter bit IPV6_EN      = 1'b0,
    parameter int READ_DEPTH   = 4
);
localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1;
localparam int MRW = (NUM_MR > 1) ? $clog2(NUM_MR) : 1;

logic clk = 1'b0, rst = 1'b1;
always #1.551 clk = ~clk;

logic             cfg_qp_we = 1'b0, cfg_mr_we = 1'b0;
logic [QPW-1:0]   cfg_qp;
logic             cfg_qp_valid, cfg_qp_ipv6, cfg_mr_valid;
logic [23:0]      cfg_qp_epsn, cfg_qp_dqpn;
logic [3:0]       cfg_qp_pmtu;
logic [47:0]      cfg_qp_dmac;
logic [127:0]     cfg_qp_dip;
logic [15:0]      cfg_qp_sport;
logic [MRW-1:0]   cfg_mr_idx;
logic [31:0]      cfg_mr_rkey, cfg_mr_len;
logic [63:0]      cfg_mr_va, cfg_mr_laddr;
logic [1:0]       cfg_mr_acc;
logic             read_cont = 1'b1;
logic [NUM_QP-1:0] send_rnr = '0;
logic [19:0]       pace_inc = '0;

logic [511:0] rx_tdata = '0;
logic [63:0]  rx_tkeep = '0;
logic         rx_tvalid = 1'b0, rx_tlast = 1'b0;
wire  logic   rx_tready;
wire  logic [511:0] tx_tdata;
wire  logic [63:0]  tx_tkeep;
wire  logic         tx_tvalid, tx_tlast;
logic               tx_tready = 1'b0;

wire  logic         wcmd_valid; logic wcmd_ready = 1'b0;
wire  logic [63:0]  wcmd_addr;  wire logic [12:0] wcmd_len;
wire  logic [511:0] wdat_tdata; wire logic [63:0] wdat_tkeep;
wire  logic         wdat_tvalid, wdat_tlast; logic wdat_tready = 1'b0;
wire  logic         rcmd_valid; logic rcmd_ready = 1'b0;
wire  logic [63:0]  rcmd_addr;  wire logic [12:0] rcmd_len;
logic [511:0]       rdat_tdata; logic rdat_tvalid = 1'b0; wire logic rdat_tready;
wire  logic [511:0] send_tdata; wire logic [63:0] send_tkeep;
wire  logic         send_tvalid, send_tlast, send_som, send_eom; logic send_tready = 1'b0;
wire  logic [QPW-1:0] send_qp, cpl_qp, err_qp;
wire  logic         cpl_valid, cpl_send, cpl_has_imm; logic cpl_ready = 1'b0;
wire  logic [31:0]  cpl_imm, cpl_len;
wire  logic         err_valid;
wire  logic [7:0]   err_syn;
wire  logic         send_end_valid, send_end_ok;
core_ev_t           ev;

rocelet_core #(
    .NUM_QP(NUM_QP), .NUM_MR(NUM_MR), .PMTU_RUNTIME(PMTU_RUNTIME), .IPV6_EN(IPV6_EN),
    .READ_DEPTH(READ_DEPTH), .RX_ICRC_EN(1'b1), .QPN_BASE(24'h000100), .RTX_MODE("REREAD"), .MAX_WR(16)
) dut (
    .clk(clk), .rst(rst),
    .my_mac(48'h02_00_00_00_00_01), .my_ip4(32'hC0A80201),
    .my_ip6(128'hFE80_0000_0000_0000_0000_0000_C0A8_0201), .ip_tos(8'h02), .ip_ttl(8'd64),
    .cfg_tick_div(10'd16), .cfg_timeout(20'd1000), .cfg_rnr_min(20'd1), .cfg_rnr_max(20'd1000),
    .cfg_retry_cnt(3'd7), .cfg_rnr_retry(3'd7), .cfg_rnr_timer(5'd14), .cfg_ackreq_n(8'd0),
    .cfg_read_cont(read_cont), .cfg_loss_fatal(1'b0), .cfg_pace_inc(pace_inc), .cfg_pace_burst(16'd16384),
    .cfg_link_grace('0), .link_up(1'b1), .stat_timer_hold(),
    .cfg_qp_we(cfg_qp_we), .cfg_qp(cfg_qp), .cfg_qp_valid(cfg_qp_valid), .cfg_qp_type(QPT_RC),
    .cfg_qp_sq_psn('0), .cfg_qp_rq_psn(cfg_qp_epsn), .cfg_qp_pmtu(cfg_qp_pmtu), .cfg_qp_ipv6(cfg_qp_ipv6),
    .cfg_qp_dmac(cfg_qp_dmac), .cfg_qp_dip(cfg_qp_dip), .cfg_qp_dqpn(cfg_qp_dqpn),
    .cfg_qp_sport(cfg_qp_sport), .cfg_qp_dport(16'd0), .cfg_err_we(1'b0), .cfg_err_qp('0),
    .cfg_mr_we(cfg_mr_we), .cfg_mr_idx(cfg_mr_idx), .cfg_mr_valid(cfg_mr_valid),
    .cfg_mr_rkey(cfg_mr_rkey), .cfg_mr_va(cfg_mr_va), .cfg_mr_len(cfg_mr_len),
    .cfg_mr_laddr(cfg_mr_laddr), .cfg_mr_acc(cfg_mr_acc),
    .s_rx_tdata(rx_tdata), .s_rx_tkeep(rx_tkeep), .s_rx_tvalid(rx_tvalid), .s_rx_tready(rx_tready),
    .s_rx_tlast(rx_tlast),
    .m_tx_tdata(tx_tdata), .m_tx_tkeep(tx_tkeep), .m_tx_tvalid(tx_tvalid), .m_tx_tready(tx_tready),
    .m_tx_tlast(tx_tlast),
    .s_wr_valid(1'b0), .s_wr_ready(), .s_wr_qp('0), .s_wr_class('0), .s_wr_se(1'b0), .s_wr_md(1'b0),
    .s_wr_va('0), .s_wr_rkey('0), .s_wr_len('0), .s_wr_imm('0), .s_wr_laddr('0), .s_wr_id('0),
    .s_wpay_tdata('0), .s_wpay_tvalid(1'b0), .s_wpay_tready(), .s_wpay_tlast(1'b0),
    .m_wc_valid(), .m_wc_ready(1'b1), .m_wc_qp(), .m_wc_id(), .m_wc_status(),
    .m_qrd_valid(), .m_qrd_ready(1'b1), .m_qrd_addr(), .m_qrd_len(),
    .s_qrd_tdata('0), .s_qrd_tvalid(1'b0), .s_qrd_tready(),
    .m_wcmd_valid(wcmd_valid), .m_wcmd_ready(wcmd_ready), .m_wcmd_addr(wcmd_addr), .m_wcmd_len(wcmd_len),
    .m_wdat_tdata(wdat_tdata), .m_wdat_tkeep(wdat_tkeep), .m_wdat_tvalid(wdat_tvalid),
    .m_wdat_tready(wdat_tready), .m_wdat_tlast(wdat_tlast),
    .m_rcmd_valid(rcmd_valid), .m_rcmd_ready(rcmd_ready), .m_rcmd_addr(rcmd_addr), .m_rcmd_len(rcmd_len),
    .s_rdat_tdata(rdat_tdata), .s_rdat_tvalid(rdat_tvalid), .s_rdat_tready(rdat_tready),
    .m_send_tdata(send_tdata), .m_send_tkeep(send_tkeep), .m_send_tvalid(send_tvalid),
    .m_send_tready(send_tready), .m_send_tlast(send_tlast), .m_send_qp(send_qp),
    .m_send_som(send_som), .m_send_eom(send_eom),
    .m_send_end_valid(send_end_valid), .m_send_end_ok(send_end_ok), .send_rnr(send_rnr),
    .m_rc_valid(cpl_valid), .m_rc_ready(cpl_ready), .m_rc_qp(cpl_qp), .m_rc_send(cpl_send),
    .m_rc_has_imm(cpl_has_imm), .m_rc_imm(cpl_imm), .m_rc_len(cpl_len),
    .qp_err_req(), .qp_err_resp(),
    .m_req_err_valid(), .m_req_err_qp(), .m_req_err_code(),
    .m_resp_err_valid(err_valid), .m_resp_err_qp(err_qp), .m_resp_err_code(err_syn),
    .stat_wr_outstanding(), .stat_ring_used(), .ev(ev)
);

// received ACKs (the engine as requester) are taken from inside the engine
wire logic           ack_valid = dut.ack_valid;
wire logic [QPW-1:0] ack_qp    = dut.ack_qp;
wire logic [23:0]    ack_psn   = dut.ack_psn;
wire logic [23:0]    ack_msn   = dut.ack_msn;
wire logic [7:0]     ack_syn   = dut.ack_syn;

string  dir;
integer seed, gap, bp, r, f_tx, f_wr, f_send, f_cpl, f_ack, f_err, rc;
int     nin = 0, nframes = 0, n_cnp = 0, n_pdrop = 0, n_cont = 0, n_rnr = 0, n_txf = 0, n_stall = 0;
bit     cfg_done = 0, rx_done = 0;

function automatic int urand100();
    return $urandom_range(99, 0);
endfunction

function automatic int popc(input logic [63:0] k);
    int c = 0;
    for (int i = 0; i < 64; i++) c += k[i];
    return c;
endfunction

initial begin
    integer fd, q, v, ps, pm, v6, dq, sp, ix, ac;
    logic [47:0] dm; logic [127:0] di; logic [31:0] rk, ln; logic [63:0] va, la;
    if (!$value$plusargs("dir=%s", dir)) dir = ".";
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("gap=%d", gap)) gap = 20;
    if (!$value$plusargs("bp=%d", bp)) bp = 20;
    if (!$value$plusargs("read_cont=%d", rc)) rc = 1;
    read_cont = rc[0];
    r = $urandom(seed);
    f_tx = $fopen({dir, "/tx.txt"}, "w");
    f_wr = $fopen({dir, "/wr.txt"}, "w");
    f_send = $fopen({dir, "/send.txt"}, "w");
    f_cpl = $fopen({dir, "/cpl.txt"}, "w");
    f_ack = $fopen({dir, "/ack.txt"}, "w");
    f_err = $fopen({dir, "/err.txt"}, "w");
    repeat (8) @(posedge clk);
    rst <= 1'b0;
    repeat (4) @(posedge clk);
    fd = $fopen({dir, "/cfg_qp.txt"}, "r");
    while ($fscanf(fd, "%h %h %h %h %h %h %h %h %h\n", q, v, ps, pm, v6, dm, di, dq, sp) == 9) begin
        cfg_qp_we <= 1'b1; cfg_qp <= q; cfg_qp_valid <= v[0]; cfg_qp_epsn <= ps; cfg_qp_pmtu <= pm;
        cfg_qp_ipv6 <= v6[0]; cfg_qp_dmac <= dm; cfg_qp_dip <= di; cfg_qp_dqpn <= dq; cfg_qp_sport <= sp;
        @(posedge clk); cfg_qp_we <= 1'b0; repeat (6) @(posedge clk);
    end
    $fclose(fd);
    fd = $fopen({dir, "/cfg_mr.txt"}, "r");
    while ($fscanf(fd, "%h %h %h %h %h %h %h\n", ix, v, rk, va, ln, la, ac) == 7) begin
        cfg_mr_we <= 1'b1; cfg_mr_idx <= ix; cfg_mr_valid <= v[0]; cfg_mr_rkey <= rk; cfg_mr_va <= va;
        cfg_mr_len <= ln; cfg_mr_laddr <= la; cfg_mr_acc <= ac;
        @(posedge clk); cfg_mr_we <= 1'b0; repeat (2) @(posedge clk);
    end
    $fclose(fd);
    cfg_done = 1;
end

// receive path idle: nothing between the input and the responder state machine;
// all idle: also no response queued or being sent
int quiet = 0, still = 0;
always @(posedge clk) begin
    if (dut.u_rx.st != 0 || dut.c_tvalid || dut.h_valid || dut.p_tvalid || rx_tvalid) quiet <= 0;
    else quiet <= quiet + 1;
    if (dut.u_rx.st != 0 || dut.c_tvalid || dut.h_valid || dut.p_tvalid || rx_tvalid || dut.rs_valid ||
        dut.u_rtx.q_valid || dut.u_rtx.hv || tx_tvalid || rdat_tvalid || rq_addr.size() != 0 || dut.b_valid)
        still <= 0;
    else still <= still + 1;
end

// RX frames
initial begin
    integer fd, rl, rn, sy;
    logic [511:0] d;
    logic [255:0] m;
    bit first;
    wait (cfg_done);
    first = 1;
    fd = $fopen({dir, "/rx.txt"}, "r");
    while ($fscanf(fd, "%d %d %h %h %d\n", rl, rn, d, m, sy) == 5) begin
        if (first && sy == 1) begin
            rx_tvalid <= 1'b0;
            @(posedge clk);
            while (still < 200) @(posedge clk);
        end else if (first && sy >= 2) begin
            rx_tvalid <= 1'b0;
            @(posedge clk);
            while (n_txf < sy - 2 && still < 4000) @(posedge clk);
            if (n_txf < sy - 2) begin
                $display("TB_SYNC_STALL waiting for frame %0d, %0d sent", sy - 2, n_txf);
                n_stall++;
            end
        end
        if (first && m[NUM_QP-1:0] != send_rnr) begin
            rx_tvalid <= 1'b0;
            @(posedge clk);
            while (quiet < 40) @(posedge clk);
            send_rnr <= m[NUM_QP-1:0];
            repeat (4) @(posedge clk);
        end
        while (urand100() < gap) begin rx_tvalid <= 1'b0; @(posedge clk); end
        rx_tdata <= d; rx_tlast <= rl[0]; rx_tvalid <= 1'b1;
        for (int i = 0; i < 64; i++) rx_tkeep[i] <= (i < rn);
        @(posedge clk);
        while (!rx_tready) @(posedge clk);
        nin++;
        first = rl[0];
        if (rl[0]) nframes++;
    end
    rx_tvalid <= 1'b0;
    $fclose(fd);
    rx_done = 1;
end

// sinks with random back-pressure
always @(posedge clk) begin
    if (!rst) begin
        tx_tready   <= (urand100() >= bp);
        wcmd_ready  <= (urand100() >= bp);
        wdat_tready <= (urand100() >= bp);
        rcmd_ready  <= (urand100() >= bp);
        send_tready <= (urand100() >= bp);
        cpl_ready   <= (urand100() >= bp);
    end
    if (tx_tvalid && tx_tready) $fdisplay(f_tx, "%0d %0d %0128h 0", tx_tlast, popc(tx_tkeep), tx_tdata);
    if (tx_tvalid && tx_tready && tx_tlast) n_txf++;
    if (wcmd_valid && wcmd_ready) $fdisplay(f_wr, "C %0h %0h", wcmd_addr, wcmd_len);
    if (wdat_tvalid && wdat_tready) $fdisplay(f_wr, "D %0d %0d %0128h", wdat_tlast, popc(wdat_tkeep), wdat_tdata);
    if (send_tvalid && send_tready)
        $fdisplay(f_send, "%0d %0d %0128h %0d %0d %0d", send_tlast, popc(send_tkeep), send_tdata, send_qp, send_som, send_eom);
    if (send_end_valid) $fdisplay(f_send, "E %0d", send_end_ok);
    if (cpl_valid && cpl_ready) $fdisplay(f_cpl, "%0d %0d %0d %08h %0d", cpl_qp, cpl_send, cpl_has_imm, cpl_imm, cpl_len);
    if (ack_valid) $fdisplay(f_ack, "%0d %06h %02h %06h", ack_qp, ack_psn, ack_syn, ack_msn);
    if (err_valid) $fdisplay(f_err, "%0d %02h", err_qp, err_syn);
    if (ev.rx_cnp) n_cnp++;
    if (ev.rx_parse_drop) n_pdrop++;
    if (ev.rx_read_cont) n_cont++;
    if (ev.rx_rnr_sent) n_rnr++;
end

// memory read model: queue of commands, data = byte pattern of the address
logic [63:0] rq_addr [$];
logic [12:0] rq_len  [$];
always @(posedge clk) begin
    if (rcmd_valid && rcmd_ready) begin
        rq_addr.push_back(rcmd_addr);
        rq_len.push_back(rcmd_len);
    end
end
initial begin
    logic [63:0] a; logic [12:0] l; int nb;
    forever begin
        @(posedge clk);
        if (rq_addr.size() > 0) begin
            a = rq_addr.pop_front(); l = rq_len.pop_front();
            nb = (l + 63) / 64;
            for (int b = 0; b < nb; b++) begin
                while (urand100() < gap) begin rdat_tvalid <= 1'b0; @(posedge clk); end
                for (int j = 0; j < 64; j++) begin
                    logic [63:0] ba;
                    ba = a + 64 * b + j;
                    rdat_tdata[j*8 +: 8] <= ba[7:0] ^ ba[15:8] ^ 8'h5A;
                end
                rdat_tvalid <= 1'b1;
                @(posedge clk);
                while (!rdat_tready) @(posedge clk);
            end
            rdat_tvalid <= 1'b0;
        end
    end
end

longint cyc = 0, r_first = -1, r_last = 0, r_beats = 0;
always @(posedge clk) begin
    cyc <= cyc + 1;
    if (rx_tvalid && rx_tready) begin
        if (r_first < 0) r_first = cyc;
        r_last = cyc;
        r_beats++;
    end
end

int idle = 0;
always @(posedge clk) begin
    if (rx_done) begin
        idle <= (tx_tvalid || wdat_tvalid || send_tvalid || rcmd_valid || rdat_tvalid) ? 0 : idle + 1;
        if (idle > 400) begin
            $display("TB_DONE frames_in=%0d cnp=%0d drop=%0d cont=%0d rnr=%0d in_beats=%0d in_cycles=%0d", nframes,
                     n_cnp, n_pdrop, n_cont, n_rnr, r_beats, r_last - r_first + 1);
            $fclose(f_tx); $fclose(f_wr); $fclose(f_send); $fclose(f_cpl); $fclose(f_ack); $fclose(f_err);
            $finish;
        end
    end
end

initial begin
    #100ms;
    $display("TB_TIMEOUT");
    $finish;
end

endmodule
