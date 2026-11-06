// SPDX-License-Identifier: MIT
//
// tb_top_resp - the responder test (test_resp.py) through the complete IP: rocelet_top with
// its MAC glue (RX FIFO, classifier, TX FIFO, arbiter, PAUSE), AXI-Lite register file
// (all configuration written through AXI-Lite) and AXI4 memory master (axi_slave_model).
// The frames from +dir=/rx.txt are fed to the MAC RX port (no back-pressure, as a MAC);
// the feeder honours the IP's PAUSE requests at frame boundaries, as a link partner does.
// MAC_WIDTH 64 / 128 / 256: the MAC model runs at that width (rx.txt holds MAC_WIDTH/8-byte
// beats, partial last beats), with random tvalid gaps inside frames (+igap= per cent), and
// the IP's width converters in the path; tx.txt logs the MAC-width TX beats.
// Files and logs as tb_core_resp, plus mem.txt (the bytes written to memory).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none
`include "axil_bfm.svh"

module tb_top_resp
    import rocelet_pkg::*;
    import rocelet_regs_pkg::*;
#(
    parameter int NUM_QP       = 8,
    parameter int NUM_MR       = 4,
    parameter bit PMTU_RUNTIME = 1'b1,
    parameter bit IPV6_EN      = 1'b0,
    parameter int READ_DEPTH   = 4,
    parameter int MAC_WIDTH    = 512
);
localparam int KB = MAC_WIDTH / 8;
localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1;

logic clk = 1'b0, rst = 1'b1;
always #1.551 clk = ~clk;

// MAC side
logic [MAC_WIDTH-1:0] rx_tdata = '0;
logic [KB-1:0]        rx_tkeep = '0;
logic                 rx_tvalid = 1'b0, rx_tlast = 1'b0;
wire  logic [MAC_WIDTH-1:0] tx_tdata;
wire  logic [KB-1:0]        tx_tkeep;
wire  logic         tx_tvalid, tx_tlast, tx_tuser;
logic               tx_tready = 1'b0;
wire  logic         pause_req;
// responder streams
wire  logic [511:0] send_tdata;
wire  logic [63:0]  send_tkeep;
wire  logic         send_tvalid, send_tlast, commit_valid, commit_ok;
wire  logic [15:0]  send_tuser;
logic               send_tready = 1'b0;
wire  logic [127:0] rc_tdata;
wire  logic         rc_tvalid;
logic               rc_tready = 1'b0;
logic [NUM_QP-1:0]  send_rnr = '0;
// AXI-Lite
logic [15:0] c_awaddr, c_araddr;
logic        c_awvalid = 1'b0, c_wvalid = 1'b0, c_bready = 1'b0, c_arvalid = 1'b0, c_rready = 1'b0;
logic [31:0] c_wdata;
logic [3:0]  c_wstrb;
wire  logic  c_awready, c_wready, c_bvalid, c_arready, c_rvalid;
wire  logic [31:0] c_rdata;
wire  logic [1:0]  c_bresp, c_rresp;
`AXIL_BFM(c)
// AXI4
wire logic [1:0]  awid, bid, arid, rid, awburst, arburst, bresp, rresp;
wire logic [63:0] awaddr, araddr;
wire logic [7:0]  awlen, arlen;
wire logic [2:0]  awsize, arsize, awprot, arprot;
wire logic [3:0]  awcache, arcache;
wire logic        awlock, arlock, awvalid, awready, wlast, wvalid, wready, bvalid, bready;
wire logic        arvalid, arready, rlast, rvalid, rready;
wire logic [511:0] wdata, rdata;
wire logic [63:0] wstrb;

rocelet_top #(
    .NUM_QP(NUM_QP), .NUM_MR(NUM_MR), .PMTU_RUNTIME(PMTU_RUNTIME), .IPV6_EN(IPV6_EN), .READ_DEPTH(READ_DEPTH),
    .QPN_BASE(24'h000100), .RTX_MODE("RING"), .RING_BYTES(65536), .RING_RAM("block"), .MAX_WR(16),
    .MEM_RD_BUF(128), .CLK_MHZ(16), .MAC_WIDTH(MAC_WIDTH)
) dut (
    .clk(clk), .rst(rst), .irq(),
    .mac_rx_reset(1'b0), .mac_tx_reset(1'b0), .mac_rx_status(1'b1), .link_up(1'b1),
    .s_axis_rx_tdata(rx_tdata), .s_axis_rx_tkeep(rx_tkeep), .s_axis_rx_tvalid(rx_tvalid),
    .s_axis_rx_tlast(rx_tlast), .s_axis_rx_tuser(1'b0),
    .m_axis_tx_tdata(tx_tdata), .m_axis_tx_tkeep(tx_tkeep), .m_axis_tx_tvalid(tx_tvalid),
    .m_axis_tx_tready(tx_tready), .m_axis_tx_tlast(tx_tlast), .m_axis_tx_tuser(tx_tuser),
    .mac_pause_hold(1'b0), .mac_pause_valid(1'b0), .mac_pause_quanta('0), .mac_pause_req(pause_req),
    .mac_pause_rx_frame(1'b0), .mac_pause_tx_frame(1'b0), .mac_fec_corr_inc(1'b0), .mac_fec_uncorr_inc(1'b0),
    .m_axis_other_tdata(), .m_axis_other_tkeep(), .m_axis_other_tvalid(), .m_axis_other_tready(1'b1),
    .m_axis_other_tlast(),
    .s_axis_other_tdata('0), .s_axis_other_tkeep('0), .s_axis_other_tvalid(1'b0), .s_axis_other_tready(),
    .s_axis_other_tlast(1'b0),
    .s_axis_wr_tdata('0), .s_axis_wr_tvalid(1'b0), .s_axis_wr_tready(),
    .s_axis_wr_data_tdata('0), .s_axis_wr_data_tvalid(1'b0), .s_axis_wr_data_tready(), .s_axis_wr_data_tlast(1'b0),
    .m_axis_wc_tdata(), .m_axis_wc_tvalid(), .m_axis_wc_tready(1'b1),
    .m_axis_send_tdata(send_tdata), .m_axis_send_tkeep(send_tkeep), .m_axis_send_tvalid(send_tvalid),
    .m_axis_send_tready(send_tready), .m_axis_send_tlast(send_tlast), .m_axis_send_tuser(send_tuser),
    .send_commit_valid(commit_valid), .send_commit_ok(commit_ok), .send_rnr(send_rnr),
    .m_axis_rc_tdata(rc_tdata), .m_axis_rc_tvalid(rc_tvalid), .m_axis_rc_tready(rc_tready),
    .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
    .m_axi_awlock(awlock), .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awvalid(awvalid),
    .m_axi_awready(awready), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
    .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
    .m_axi_arlock(arlock), .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arvalid(arvalid),
    .m_axi_arready(arready), .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid), .m_axi_rready(rready),
    .s_axil_awaddr(c_awaddr), .s_axil_awvalid(c_awvalid), .s_axil_awready(c_awready), .s_axil_wdata(c_wdata),
    .s_axil_wstrb(c_wstrb), .s_axil_wvalid(c_wvalid), .s_axil_wready(c_wready), .s_axil_bresp(c_bresp),
    .s_axil_bvalid(c_bvalid), .s_axil_bready(c_bready), .s_axil_araddr(c_araddr), .s_axil_arvalid(c_arvalid),
    .s_axil_arready(c_arready), .s_axil_rdata(c_rdata), .s_axil_rresp(c_rresp), .s_axil_rvalid(c_rvalid),
    .s_axil_rready(c_rready)
);

axi_slave_model #(.ADDR_W(64), .ID_W(2)) u_mem (
    .clk(clk), .rst(rst),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid),
    .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arvalid(arvalid),
    .arready(arready), .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
);

// received ACKs and responder errors, taken from inside the engine
wire logic           ack_valid = dut.u_core.ack_valid;
wire logic [QPW-1:0] ack_qp    = dut.u_core.ack_qp;
wire logic [23:0]    ack_psn   = dut.u_core.ack_psn;
wire logic [23:0]    ack_msn   = dut.u_core.ack_msn;
wire logic [7:0]     ack_syn   = dut.u_core.ack_syn;
wire logic           err_valid = dut.u_core.m_resp_err_valid;
wire logic [QPW-1:0] err_qp    = dut.u_core.m_resp_err_qp;
wire logic [7:0]     err_syn   = dut.u_core.m_resp_err_code;

string  dir;
integer seed, gap, igap, bp, r, f_tx, f_send, f_cpl, f_ack, f_err, rc;
int     nframes = 0;
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
    logic [47:0] dm; logic [127:0] di; logic [31:0] rk, ln, rd; logic [63:0] va, la;
    if (!$value$plusargs("dir=%s", dir)) dir = ".";
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("gap=%d", gap)) gap = 20;
    if (!$value$plusargs("igap=%d", igap)) igap = 0;
    if (!$value$plusargs("bp=%d", bp)) bp = 20;
    if (!$value$plusargs("read_cont=%d", rc)) rc = 1;
    r = $urandom(seed);
    f_tx = $fopen({dir, "/tx.txt"}, "w");
    f_send = $fopen({dir, "/send.txt"}, "w");
    f_cpl = $fopen({dir, "/cpl.txt"}, "w");
    f_ack = $fopen({dir, "/ack.txt"}, "w");
    f_err = $fopen({dir, "/err.txt"}, "w");
    repeat (8) @(posedge clk);
    rst <= 1'b0;
    repeat (8) @(posedge clk);
    c_read(R_ID, rd);
    if (rd != 32'h52434C54) $display("TB_ERROR ID register %08h", rd);
    c_write(R_MAC_LO, 32'h00_00_00_01); c_write(R_MAC_HI, 32'h0000_0200);
    c_write(R_IP4, 32'hC0A80201);
    c_write(R_IP6_0, 32'hC0A80201); c_write(R_IP6_1, 32'h0); c_write(R_IP6_2, 32'h0); c_write(R_IP6_3, 32'hFE800000);
    c_write(R_IP_HDR, 32'h0000_4002);
    c_write(R_TICK_DIV, 32'd16);
    c_write(R_RNR_NAK_TIMER, 32'd14);
    c_write(R_ACKREQ_N, 32'd0);
    c_write(R_PAUSE_WM, {16'd32, 16'd96});
    c_read(R_CTRL, rd);
    c_write(R_CTRL, (rd & ~32'h8) | (rc[0] ? 32'h8 : 32'h0));
    fd = $fopen({dir, "/cfg_qp.txt"}, "r");
    while ($fscanf(fd, "%h %h %h %h %h %h %h %h %h\n", q, v, ps, pm, v6, dm, di, dq, sp) == 9) begin
        c_write(R_QP_INDEX, q); c_write(R_QP_FLAGS, {29'd0, 2'd0, v[0]}); c_write(R_QP_RQ_PSN, ps);
        c_write(R_QP_SQ_PSN, 32'd0); c_write(R_QP_PMTU, pm); c_write(R_QP_IPV6, v6);
        c_write(R_QP_DMAC_LO, dm[31:0]); c_write(R_QP_DMAC_HI, dm[47:32]);
        c_write(R_QP_DIP0, di[31:0]); c_write(R_QP_DIP1, di[63:32]); c_write(R_QP_DIP2, di[95:64]);
        c_write(R_QP_DIP3, di[127:96]); c_write(R_QP_DQPN, dq); c_write(R_QP_UDP, {16'd0, sp[15:0]});
        c_write(R_QP_COMMIT, 32'd1);
    end
    $fclose(fd);
    fd = $fopen({dir, "/cfg_mr.txt"}, "r");
    while ($fscanf(fd, "%h %h %h %h %h %h %h\n", ix, v, rk, va, ln, la, ac) == 7) begin
        c_write(R_MR_INDEX, ix); c_write(R_MR_FLAGS, {29'd0, ac[1:0], v[0]}); c_write(R_MR_RKEY, rk);
        c_write(R_MR_VA_LO, va[31:0]); c_write(R_MR_VA_HI, va[63:32]); c_write(R_MR_LEN, ln);
        c_write(R_MR_LADDR_LO, la[31:0]); c_write(R_MR_LADDR_HI, la[63:32]); c_write(R_MR_COMMIT, 32'd1);
    end
    $fclose(fd);
    cfg_done = 1;
end

// receive path idle; all idle (also no response queued or being sent)
int quiet = 0, still = 0;
always @(posedge clk) begin
    if (dut.u_core.u_rx.st != 0 || dut.u_core.c_tvalid || dut.u_core.h_valid || dut.u_core.p_tvalid ||
        dut.erx_tvalid || dut.rx_fill != 0 || rx_tvalid) quiet <= 0;
    else quiet <= quiet + 1;
    if (dut.u_core.u_rx.st != 0 || dut.u_core.c_tvalid || dut.u_core.h_valid || dut.u_core.p_tvalid ||
        dut.erx_tvalid || dut.rx_fill != 0 || rx_tvalid || dut.u_core.rs_valid || dut.u_core.u_rtx.q_valid ||
        dut.u_core.u_rtx.hv || tx_tvalid || dut.u_core.b_valid || dut.etx_tvalid || arvalid || rvalid ||
        dut.u_mem.rs != 0)
        still <= 0;
    else still <= still + 1;
end

// RX frames (MAC: no back-pressure; PAUSE honoured between frames; tvalid gaps inside frames
// with +igap)
int n_paused = 0;
initial begin
    integer fd, rl, rn, sy;
    logic [511:0] d;
    logic [255:0] m;
    bit first;
    wait (cfg_done);
    first = 1;
    fd = $fopen({dir, "/rx.txt"}, "r");
    while ($fscanf(fd, "%d %d %h %h %d\n", rl, rn, d, m, sy) == 5) begin
        if (first) begin
            if (sy[0]) begin
                rx_tvalid <= 1'b0;
                @(posedge clk);
                while (still < 200) @(posedge clk);
            end
            if (m[NUM_QP-1:0] != send_rnr) begin
                rx_tvalid <= 1'b0;
                @(posedge clk);
                while (quiet < 40) @(posedge clk);
                send_rnr <= m[NUM_QP-1:0];
                repeat (4) @(posedge clk);
            end
            while (urand100() < gap) begin rx_tvalid <= 1'b0; @(posedge clk); end
            if (pause_req) n_paused++;
            while (pause_req) begin rx_tvalid <= 1'b0; @(posedge clk); end
        end else begin
            while (urand100() < igap) begin rx_tvalid <= 1'b0; @(posedge clk); end
        end
        rx_tdata <= MAC_WIDTH'(d); rx_tlast <= rl[0]; rx_tvalid <= 1'b1;
        for (int i = 0; i < KB; i++) rx_tkeep[i] <= (i < rn);
        @(posedge clk);
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
        send_tready <= (urand100() >= bp);
        rc_tready   <= (urand100() >= bp);
    end
    if (tx_tvalid && tx_tready) $fdisplay(f_tx, "%0d %0d %0128h 0", tx_tlast, popc(64'(tx_tkeep)), 512'(tx_tdata));
    if (send_tvalid && send_tready)
        $fdisplay(f_send, "%0d %0d %0128h %0d %0d %0d", send_tlast, popc(send_tkeep), send_tdata, send_tuser[7:0],
                  send_tuser[8], send_tuser[9]);
    if (commit_valid) $fdisplay(f_send, "E %0d", commit_ok);
    if (rc_tvalid && rc_tready)
        $fdisplay(f_cpl, "%0d %0d %0d %08h %0d", rc_tdata[71:64], rc_tdata[72], rc_tdata[73], rc_tdata[31:0],
                  rc_tdata[63:32]);
    if (ack_valid) $fdisplay(f_ack, "%0d %06h %02h %06h", ack_qp, ack_psn, ack_syn, ack_msn);
    if (err_valid) $fdisplay(f_err, "%0d %02h", err_qp, err_syn);
end

int idle = 0;
initial begin
    logic [31:0] v [NCNT];
    wait (rx_done);
    while (still < 600) @(posedge clk);
    for (int i = 0; i < NCNT; i++) c_read(R_CNT_BASE + 16'(4 * i), v[i]);
    u_mem.dump({dir, "/mem.txt"});
    $display("TB_DONE frames_in=%0d paused=%0d cnp=%0d drop=%0d cont=%0d rnr=%0d fifo_drop=%0d underrun=%0d axi_err=%0d",
             nframes, n_paused, v[C_RX_CNP], v[C_RX_PARSE_DROP], v[C_RX_READ_CONT], v[C_RX_RNR_SENT],
             v[C_RX_FIFO_DROP], v[C_TX_UNDERRUN], u_mem.errors + v[C_AXI_WR_ERR] + v[C_AXI_RD_ERR]);
    $fclose(f_tx); $fclose(f_send); $fclose(f_cpl); $fclose(f_ack); $fclose(f_err);
    $finish;
end

initial begin
    #200ms;
    $display("TB_TIMEOUT");
    $finish;
end

endmodule
