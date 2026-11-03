// SPDX-License-Identifier: MIT
//
// tb_top_pair - two complete rocelet_top instances back to back, as two FPGAs on a 100G
// link: A (requester, RTX_MODE under test) writes and sends to B (responder). Each
// direction is a CMAC model: TX frames are taken with random back-pressure, dropped with
// probability +drop=<per mille>, delayed and delivered to the other side's RX port beat by
// beat without back-pressure. 802.3x PAUSE between them: a side's ctl_tx_pause_req[8]
// reaches the other side, after the link delay, as stat_rx_pause_valid[8] with quanta
// 0xFFFF (XOFF, refreshed while held) or 0 (XON). A tags its RoCE frames with a VID-0
// priority tag (B strips it); the testbench injects an ARP request and an ICMP echo
// request into A (A's replies are logged) and sends a frame through A's other-traffic
// port, which must leave B's other-traffic port. All configuration through AXI-Lite;
// memory behind both is axi_slave_model. Files in +dir= as tb_core_pair; logs as
// tb_core_pair plus a_ctl.txt (A's non-RoCE TX frames), b_other.txt, mem.txt (B's memory),
// counters (TB_CNT lines).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none
`include "axil_bfm.svh"

module tb_top_pair
    import rocelet_pkg::*;
    import rocelet_regs_pkg::*;
#(
    parameter int NUM_QP     = 4,
    parameter     RTX_MODE   = "RING",
    parameter int RING_BYTES = 65536,
    parameter int MAX_WR     = 32
);

logic clk = 1'b0, rst = 1'b1;
always #1.551 clk = ~clk;

// ================= the two IPs =================
`define SIDE(X) \
wire  logic [511:0] X``_tx_tdata, X``_other_tdata; \
wire  logic [63:0]  X``_tx_tkeep, X``_other_tkeep; \
wire  logic         X``_tx_tvalid, X``_tx_tlast, X``_tx_tuser, X``_other_tvalid, X``_other_tlast; \
logic               X``_tx_tready = 1'b0; \
logic [511:0]       X``_rx_tdata = '0; \
logic [63:0]        X``_rx_tkeep = '0; \
logic               X``_rx_tvalid = 1'b0, X``_rx_tlast = 1'b0; \
wire  logic [8:0]   X``_pause_out; \
logic [8:0]         X``_pause_in_req = '0, X``_pause_in_valid = '0; \
logic [15:0]        X``_pause_in_quanta = '0; \
logic               X``_pause_in_pulse = 1'b0; \
logic [15:0] X``_awaddr, X``_araddr; \
logic        X``_awvalid = 1'b0, X``_wvalid = 1'b0, X``_bready = 1'b0, X``_arvalid = 1'b0, X``_rready = 1'b0; \
logic [31:0] X``_wdata; \
logic [3:0]  X``_wstrb; \
wire  logic  X``_awready, X``_wready, X``_bvalid, X``_arready, X``_rvalid; \
wire  logic [31:0] X``_rdata; \
wire  logic [1:0]  X``_bresp, X``_rresp; \
wire logic [1:0]  X``_awid, X``_bid, X``_arid, X``_rid, X``_awburst, X``_arburst, X``_mbresp, X``_mrresp; \
wire logic [63:0] X``_mawaddr, X``_maraddr; \
wire logic [7:0]  X``_awlen, X``_arlen; \
wire logic [2:0]  X``_awsize, X``_arsize, X``_awprot, X``_arprot; \
wire logic [3:0]  X``_awcache, X``_arcache; \
wire logic        X``_awlock, X``_arlock, X``_mawvalid, X``_mawready, X``_wlast, X``_mwvalid, X``_mwready; \
wire logic        X``_mbvalid, X``_mbready, X``_marvalid, X``_marready, X``_rlast, X``_mrvalid, X``_mrready; \
wire logic [511:0] X``_mwdata, X``_mrdata; \
wire logic [63:0] X``_wstrb_m; \
`AXIL_BFM(X) \
axi_slave_model #(.ADDR_W(64), .ID_W(2)) X``_mem ( \
    .clk(clk), .rst(rst), \
    .awid(X``_awid), .awaddr(X``_mawaddr), .awlen(X``_awlen), .awsize(X``_awsize), .awburst(X``_awburst), \
    .awvalid(X``_mawvalid), .awready(X``_mawready), .wdata(X``_mwdata), .wstrb(X``_wstrb_m), .wlast(X``_wlast), \
    .wvalid(X``_mwvalid), .wready(X``_mwready), .bid(X``_bid), .bresp(X``_mbresp), .bvalid(X``_mbvalid), \
    .bready(X``_mbready), .arid(X``_arid), .araddr(X``_maraddr), .arlen(X``_arlen), .arsize(X``_arsize), \
    .arburst(X``_arburst), .arvalid(X``_marvalid), .arready(X``_marready), .rid(X``_rid), .rdata(X``_mrdata), \
    .rresp(X``_mrresp), .rlast(X``_rlast), .rvalid(X``_mrvalid), .rready(X``_mrready) \
);

`SIDE(a)
`SIDE(b)

// A: work requests
logic [255:0] wr_tdata;
logic         wr_tvalid = 1'b0;
wire  logic   wr_tready;
logic [511:0] pay_tdata;
logic         pay_tvalid = 1'b0, pay_tlast = 1'b0;
wire  logic   pay_tready;
wire  logic [63:0] wc_tdata;
wire  logic   wc_tvalid;
logic [511:0] ao_tdata = '0;
logic [63:0]  ao_tkeep = '0;
logic         ao_tvalid = 1'b0, ao_tlast = 1'b0;
wire  logic   ao_tready;
// B: responder sinks
wire  logic [511:0] send_tdata;
wire  logic [63:0]  send_tkeep;
wire  logic         send_tvalid, send_tlast, commit_valid, commit_ok;
wire  logic [15:0]  send_tuser;
logic               send_tready = 1'b0;
wire  logic [127:0] rc_tdata;
wire  logic         rc_tvalid;
logic               rc_tready = 1'b0;
logic [NUM_QP-1:0]  send_rnr = '0;

`define TOP_PORTS(X) \
    .clk(clk), .rst(rst), .irq(), \
    .mac_rx_reset(1'b0), .mac_tx_reset(1'b0), .mac_rx_aligned(1'b1), .link_up(1'b1), \
    .s_axis_rx_tdata(X``_rx_tdata), .s_axis_rx_tkeep(X``_rx_tkeep), .s_axis_rx_tvalid(X``_rx_tvalid), \
    .s_axis_rx_tlast(X``_rx_tlast), .s_axis_rx_tuser(1'b0), \
    .m_axis_tx_tdata(X``_tx_tdata), .m_axis_tx_tkeep(X``_tx_tkeep), .m_axis_tx_tvalid(X``_tx_tvalid), \
    .m_axis_tx_tready(X``_tx_tready), .m_axis_tx_tlast(X``_tx_tlast), .m_axis_tx_tuser(X``_tx_tuser), \
    .stat_rx_pause_req(X``_pause_in_req), .stat_rx_pause_valid(X``_pause_in_valid), \
    .stat_rx_pause_quanta8(X``_pause_in_quanta), .stat_rx_pause(X``_pause_in_pulse), .stat_tx_pause(1'b0), \
    .ctl_tx_pause_req(X``_pause_out), \
    .stat_rx_rsfec_corrected_cw_inc(1'b0), .stat_rx_rsfec_uncorrected_cw_inc(1'b0), \
    .m_axi_awid(X``_awid), .m_axi_awaddr(X``_mawaddr), .m_axi_awlen(X``_awlen), .m_axi_awsize(X``_awsize), \
    .m_axi_awburst(X``_awburst), .m_axi_awlock(X``_awlock), .m_axi_awcache(X``_awcache), .m_axi_awprot(X``_awprot), \
    .m_axi_awvalid(X``_mawvalid), .m_axi_awready(X``_mawready), .m_axi_wdata(X``_mwdata), .m_axi_wstrb(X``_wstrb_m), \
    .m_axi_wlast(X``_wlast), .m_axi_wvalid(X``_mwvalid), .m_axi_wready(X``_mwready), .m_axi_bid(X``_bid), \
    .m_axi_bresp(X``_mbresp), .m_axi_bvalid(X``_mbvalid), .m_axi_bready(X``_mbready), .m_axi_arid(X``_arid), \
    .m_axi_araddr(X``_maraddr), .m_axi_arlen(X``_arlen), .m_axi_arsize(X``_arsize), .m_axi_arburst(X``_arburst), \
    .m_axi_arlock(X``_arlock), .m_axi_arcache(X``_arcache), .m_axi_arprot(X``_arprot), \
    .m_axi_arvalid(X``_marvalid), .m_axi_arready(X``_marready), .m_axi_rid(X``_rid), .m_axi_rdata(X``_mrdata), \
    .m_axi_rresp(X``_mrresp), .m_axi_rlast(X``_rlast), .m_axi_rvalid(X``_mrvalid), .m_axi_rready(X``_mrready), \
    .s_axil_awaddr(X``_awaddr), .s_axil_awvalid(X``_awvalid), .s_axil_awready(X``_awready), \
    .s_axil_wdata(X``_wdata), .s_axil_wstrb(X``_wstrb), .s_axil_wvalid(X``_wvalid), .s_axil_wready(X``_wready), \
    .s_axil_bresp(X``_bresp), .s_axil_bvalid(X``_bvalid), .s_axil_bready(X``_bready), \
    .s_axil_araddr(X``_araddr), .s_axil_arvalid(X``_arvalid), .s_axil_arready(X``_arready), \
    .s_axil_rdata(X``_rdata), .s_axil_rresp(X``_rresp), .s_axil_rvalid(X``_rvalid), .s_axil_rready(X``_rready)

rocelet_top #(
    .NUM_QP(NUM_QP), .NUM_MR(1), .QPN_BASE(24'h000100), .READ_DEPTH(4), .RTX_MODE(RTX_MODE),
    .RING_BYTES(RING_BYTES), .RING_RAM("block"), .MAX_WR(MAX_WR), .MEM_RD_BUF(128), .CLK_MHZ(16)
) dut_a (
    `TOP_PORTS(a),
    .m_axis_other_tdata(a_other_tdata), .m_axis_other_tkeep(a_other_tkeep), .m_axis_other_tvalid(a_other_tvalid),
    .m_axis_other_tready(1'b1), .m_axis_other_tlast(a_other_tlast),
    .s_axis_other_tdata(ao_tdata), .s_axis_other_tkeep(ao_tkeep), .s_axis_other_tvalid(ao_tvalid),
    .s_axis_other_tready(ao_tready), .s_axis_other_tlast(ao_tlast),
    .s_axis_wr_tdata(wr_tdata), .s_axis_wr_tvalid(wr_tvalid), .s_axis_wr_tready(wr_tready),
    .s_axis_wr_data_tdata(pay_tdata), .s_axis_wr_data_tvalid(pay_tvalid), .s_axis_wr_data_tready(pay_tready),
    .s_axis_wr_data_tlast(pay_tlast),
    .m_axis_wc_tdata(wc_tdata), .m_axis_wc_tvalid(wc_tvalid), .m_axis_wc_tready(1'b1),
    .m_axis_send_tdata(), .m_axis_send_tkeep(), .m_axis_send_tvalid(), .m_axis_send_tready(1'b1),
    .m_axis_send_tlast(), .m_axis_send_tuser(), .send_commit_valid(), .send_commit_ok(), .send_rnr('0),
    .m_axis_rc_tdata(), .m_axis_rc_tvalid(), .m_axis_rc_tready(1'b1)
);

rocelet_top #(
    .NUM_QP(NUM_QP), .NUM_MR(1), .QPN_BASE(24'h000200), .READ_DEPTH(4), .RTX_MODE("RING"),
    .RING_BYTES(65536), .RING_RAM("block"), .MAX_WR(16), .MEM_RD_BUF(128), .CLK_MHZ(16)
) dut_b (
    `TOP_PORTS(b),
    .m_axis_other_tdata(b_other_tdata), .m_axis_other_tkeep(b_other_tkeep), .m_axis_other_tvalid(b_other_tvalid),
    .m_axis_other_tready(1'b1), .m_axis_other_tlast(b_other_tlast),
    .s_axis_other_tdata('0), .s_axis_other_tkeep('0), .s_axis_other_tvalid(1'b0), .s_axis_other_tready(),
    .s_axis_other_tlast(1'b0),
    .s_axis_wr_tdata('0), .s_axis_wr_tvalid(1'b0), .s_axis_wr_tready(),
    .s_axis_wr_data_tdata('0), .s_axis_wr_data_tvalid(1'b0), .s_axis_wr_data_tready(), .s_axis_wr_data_tlast(1'b0),
    .m_axis_wc_tdata(), .m_axis_wc_tvalid(), .m_axis_wc_tready(1'b1),
    .m_axis_send_tdata(send_tdata), .m_axis_send_tkeep(send_tkeep), .m_axis_send_tvalid(send_tvalid),
    .m_axis_send_tready(send_tready), .m_axis_send_tlast(send_tlast), .m_axis_send_tuser(send_tuser),
    .send_commit_valid(commit_valid), .send_commit_ok(commit_ok), .send_rnr(send_rnr),
    .m_axis_rc_tdata(rc_tdata), .m_axis_rc_tvalid(rc_tvalid), .m_axis_rc_tready(rc_tready)
);

// ================= test control =================
string  dir;
integer seed, drop, rnr, r, nwr_exp, f_cpl, f_err, f_send, f_bcpl, f_berr, f_ctl, f_oth, ferr_qp, ferr_at;
int     n_cpl = 0;
bit     cfg_done = 0, wr_done = 0, ctl_done = 0;
localparam logic [47:0] MAC_A = 48'h02_00_00_00_00_0A, MAC_B = 48'h02_00_00_00_00_0B;
localparam logic [31:0] IP_A = 32'hC0A8020A, IP_B = 32'hC0A8020B;

function automatic int urand1000();
    return $urandom_range(999, 0);
endfunction
function automatic int popc(input logic [63:0] k);
    int c = 0;
    for (int i = 0; i < 64; i++) c += k[i];
    return c;
endfunction

task automatic cfg_common(input bit side_b);
    logic [31:0] rd;
    if (!side_b) begin
        a_read(R_ID, rd);
        if (rd != 32'h52434C54) $display("TB_ERROR ID register %08h", rd);
        // v0.2: version, link-loss hold registers and status (link_up tied high: up, no hold)
        a_read(R_VERSION, rd);
        if (rd != 32'h00000202) $display("TB_ERROR VERSION %08h", rd);
        a_read(R_LINK_GRACE, rd);
        if (rd != RST_LINK_GRACE) $display("TB_ERROR LINK_GRACE reset value %08h", rd);
        a_write(R_LINK_GRACE, 32'hFF123456);
        a_read(R_LINK_GRACE, rd);
        if (rd != 32'h00123456) $display("TB_ERROR LINK_GRACE read back %08h", rd);
        a_write(R_LINK_GRACE, RST_LINK_GRACE);
        a_read(R_STATUS, rd);
        if (rd[6:5] != 2'b01) $display("TB_ERROR STATUS %08h: LINK_UP / TIMER_HOLD", rd);
        a_write(R_MAC_LO, MAC_A[31:0]); a_write(R_MAC_HI, MAC_A[47:32]); a_write(R_IP4, IP_A);
        a_write(R_TICK_DIV, 32'd16); a_write(R_ACK_TIMEOUT, 32'd300); a_write(R_RNR_MIN, 32'd1);
        a_write(R_RNR_MAX, 32'd2000); a_write(R_ACKREQ_N, 32'd4); a_write(R_PAUSE_WM, {16'd32, 16'd96});
        a_write(R_VLAN_TCI, 32'h6000);
        a_read(R_CTRL, rd);
        a_write(R_CTRL, rd | 32'h40);                       // VLAN_TX_TAG
    end else begin
        b_write(R_MAC_LO, MAC_B[31:0]); b_write(R_MAC_HI, MAC_B[47:32]); b_write(R_IP4, IP_B);
        b_write(R_TICK_DIV, 32'd16); b_write(R_RNR_NAK_TIMER, 32'd1); b_write(R_ACKREQ_N, 32'd0);
        b_write(R_PAUSE_WM, {16'd32, 16'd96});
        b_read(R_CTRL, rd);
        b_write(R_CTRL, rd | 32'h100);                      // OTHER_RX_EN
    end
endtask

initial begin
    integer fd, q, ps, pm, ty;
    logic [31:0] mr_rkey, mr_len;
    logic [63:0] mr_va, mr_laddr;
    if (!$value$plusargs("dir=%s", dir)) dir = ".";
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("drop=%d", drop)) drop = 20;
    if (!$value$plusargs("rnr=%d", rnr)) rnr = 0;
    if (!$value$plusargs("nwr=%d", nwr_exp)) nwr_exp = 0;
    if (!$value$plusargs("ferr_qp=%d", ferr_qp)) ferr_qp = -1;
    if (!$value$plusargs("ferr_at=%d", ferr_at)) ferr_at = 0;
    r = $urandom(seed);
    f_cpl = $fopen({dir, "/a_cpl.txt"}, "w"); f_err = $fopen({dir, "/a_err.txt"}, "w");
    f_send = $fopen({dir, "/b_send.txt"}, "w"); f_bcpl = $fopen({dir, "/b_cpl.txt"}, "w");
    f_berr = $fopen({dir, "/b_err.txt"}, "w"); f_ctl = $fopen({dir, "/a_ctl.txt"}, "w");
    f_oth = $fopen({dir, "/b_other.txt"}, "w");
    repeat (8) @(posedge clk);
    rst <= 1'b0;
    repeat (8) @(posedge clk);
    fork cfg_common(0); cfg_common(1); join
    fd = $fopen({dir, "/cfg.txt"}, "r");
    while ($fscanf(fd, "%h %h %h %h\n", q, ps, pm, ty) == 4) begin
        fork
            begin
                a_write(R_QP_INDEX, q); a_write(R_QP_FLAGS, {29'd0, ty[1:0], 1'b1}); a_write(R_QP_SQ_PSN, ps);
                a_write(R_QP_RQ_PSN, 0); a_write(R_QP_PMTU, pm); a_write(R_QP_DMAC_LO, MAC_B[31:0]);
                a_write(R_QP_DMAC_HI, MAC_B[47:32]); a_write(R_QP_DIP0, IP_B); a_write(R_QP_DQPN, 32'h200 + q);
                a_write(R_QP_UDP, 32'hC000 + q); a_write(R_QP_COMMIT, 1);
            end
            begin
                b_write(R_QP_INDEX, q); b_write(R_QP_FLAGS, 32'd1); b_write(R_QP_SQ_PSN, 0);
                b_write(R_QP_RQ_PSN, ps); b_write(R_QP_PMTU, pm); b_write(R_QP_DMAC_LO, MAC_A[31:0]);
                b_write(R_QP_DMAC_HI, MAC_A[47:32]); b_write(R_QP_DIP0, IP_A); b_write(R_QP_DQPN, 32'h100 + q);
                b_write(R_QP_UDP, 32'hD000 + q); b_write(R_QP_COMMIT, 1);
            end
        join
    end
    $fclose(fd);
    fd = $fopen({dir, "/mr.txt"}, "r");
    r = $fscanf(fd, "%h %h %h %h\n", mr_rkey, mr_va, mr_len, mr_laddr);
    $fclose(fd);
    b_write(R_MR_INDEX, 0); b_write(R_MR_FLAGS, 32'h7); b_write(R_MR_RKEY, mr_rkey);
    b_write(R_MR_VA_LO, mr_va[31:0]); b_write(R_MR_VA_HI, mr_va[63:32]); b_write(R_MR_LEN, mr_len);
    b_write(R_MR_LADDR_LO, mr_laddr[31:0]); b_write(R_MR_LADDR_HI, mr_laddr[63:32]); b_write(R_MR_COMMIT, 1);
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
        wr_tdata  <= {64'h0000_1000_0000_0000 + 64'(id) * 64'h10000, im, rk, va, ln, id, 2'b00, fl[1:0],
                      2'b00, c[1:0], 8'(q)};
        wr_tvalid <= 1'b1;
        @(posedge clk);
        while (!wr_tready) @(posedge clk);
        wr_tvalid <= 1'b0;
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
        pay_tvalid <= 1'b1; pay_tdata <= d; pay_tlast <= l[0];
        @(posedge clk);
        while (!pay_tready) @(posedge clk);
    end
    pay_tvalid <= 1'b0;
    $fclose(fd);
end

// B: no receive buffer now and then (64-cycle slots per QP)
int slot = 0;
always @(posedge clk) begin
    slot <= (slot == 63) ? 0 : slot + 1;
    if (slot == 0 && rnr > 0) for (int q = 0; q < NUM_QP; q++) send_rnr[q] <= (urand1000() < rnr);
end

// ================= links =================
// TX side of each direction: frames collected, then dropped or queued with a due time
logic [511:0] qd_ab [$], qd_ba [$], fd_ab [$], fd_ba [$];
logic [63:0]  qk_ab [$], qk_ba [$], fk_ab [$], fk_ba [$];
logic         ql_ab [$], ql_ba [$], fl_ab [$], fl_ba [$];
longint       qt_ab [$], qt_ba [$];
longint       cyc = 0;
int           n_ab = 0, n_ba = 0, d_ab = 0, d_ba = 0;
localparam int LINK_DELAY = 60;
always @(posedge clk) cyc <= cyc + 1;

function automatic bit is_roce(input logic [511:0] d);
    // IPv4 UDP 4791, with or without one 802.1Q tag
    if (d[12*8 +: 8] == 8'h81 && d[13*8 +: 8] == 8'h00) return d[16*8 +: 8] == 8'h08 && d[40*8 +: 8] == 8'h12 &&
                                                              d[41*8 +: 8] == 8'hB7;
    return d[12*8 +: 8] == 8'h08 && d[13*8 +: 8] == 8'h00 && d[36*8 +: 8] == 8'h12 && d[37*8 +: 8] == 8'hB7;
endfunction

logic a_first = 1'b1, a_roce = 1'b0;
always @(posedge clk) begin
    a_tx_tready <= (urand1000() >= 50);
    b_tx_tready <= (urand1000() >= 50);
    if (a_tx_tvalid && a_tx_tready) begin
        logic roce;
        roce = a_first ? is_roce(a_tx_tdata) : a_roce;
        if (a_first) a_roce <= roce;
        a_first <= a_tx_tlast;
        if (!roce) $fdisplay(f_ctl, "%0d %0d %0128h 0", a_tx_tlast, popc(a_tx_tkeep), a_tx_tdata);
        fd_ab.push_back(a_tx_tdata); fk_ab.push_back(a_tx_tkeep); fl_ab.push_back(a_tx_tlast);
        if (a_tx_tlast) begin
            n_ab++;
            if (urand1000() >= drop || !roce) begin
                while (fd_ab.size()) begin
                    qd_ab.push_back(fd_ab.pop_front()); qk_ab.push_back(fk_ab.pop_front());
                    ql_ab.push_back(fl_ab.pop_front()); qt_ab.push_back(cyc + LINK_DELAY);
                end
            end else begin
                d_ab++; fd_ab.delete(); fk_ab.delete(); fl_ab.delete();
            end
        end
    end
    if (b_tx_tvalid && b_tx_tready) begin
        fd_ba.push_back(b_tx_tdata); fk_ba.push_back(b_tx_tkeep); fl_ba.push_back(b_tx_tlast);
        if (b_tx_tlast) begin
            n_ba++;
            if (urand1000() >= drop) begin
                while (fd_ba.size()) begin
                    qd_ba.push_back(fd_ba.pop_front()); qk_ba.push_back(fk_ba.pop_front());
                    ql_ba.push_back(fl_ba.pop_front()); qt_ba.push_back(cyc + LINK_DELAY);
                end
            end else begin
                d_ba++; fd_ba.delete(); fk_ba.delete(); fl_ba.delete();
            end
        end
    end
end

// RX side: a frame starts when it is due and then streams without gaps (CMAC RX)
bit ab_in = 0, ba_in = 0;
always @(posedge clk) begin
    b_rx_tvalid <= 1'b0;
    if (qd_ab.size() && (ab_in || qt_ab[0] <= cyc)) begin
        b_rx_tdata <= qd_ab.pop_front(); b_rx_tkeep <= qk_ab.pop_front(); b_rx_tlast <= ql_ab[0];
        ab_in = !ql_ab.pop_front(); void'(qt_ab.pop_front());
        b_rx_tvalid <= 1'b1;
    end
    a_rx_tvalid <= 1'b0;
    if (qd_ba.size() && (ba_in || qt_ba[0] <= cyc)) begin
        a_rx_tdata <= qd_ba.pop_front(); a_rx_tkeep <= qk_ba.pop_front(); a_rx_tlast <= ql_ba[0];
        ba_in = !ql_ba.pop_front(); void'(qt_ba.pop_front());
        a_rx_tvalid <= 1'b1;
    end
end

// the TB's own frames towards A (ARP request, ICMP echo request): into the B->A link
task automatic inject_ba(input byte unsigned fr [], input int len);
    for (int i = 0; i < len; i += 64) begin
        logic [511:0] d; logic [63:0] k;
        d = '0; k = '0;
        for (int j = 0; j < 64 && i + j < len; j++) begin d[j*8 +: 8] = fr[i + j]; k[j] = 1'b1; end
        qd_ba.push_back(d); qk_ba.push_back(k); ql_ba.push_back(i + 64 >= len); qt_ba.push_back(cyc + 1);
    end
endtask

// 802.3x PAUSE between the two sides (link delay, XOFF refresh while held)
`define PAUSE_LINK(FROM, TO) \
logic [LINK_DELAY-1:0] FROM``_pdl = '0; \
int FROM``_refresh = 0; \
always @(posedge clk) begin \
    logic now_req, was_req; \
    FROM``_pdl <= {FROM``_pdl[LINK_DELAY-2:0], FROM``_pause_out[8]}; \
    now_req = FROM``_pdl[LINK_DELAY-1]; \
    was_req = TO``_pause_in_req[8]; \
    TO``_pause_in_req <= {now_req, 8'd0}; \
    TO``_pause_in_valid <= '0; \
    TO``_pause_in_pulse <= 1'b0; \
    FROM``_refresh <= (now_req && FROM``_refresh < 8000) ? FROM``_refresh + 1 : 0; \
    if (now_req != was_req || FROM``_refresh == 8000) begin \
        TO``_pause_in_valid <= {1'b1, 8'd0}; \
        TO``_pause_in_quanta <= now_req ? 16'hFFFF : 16'h0000; \
        TO``_pause_in_pulse <= 1'b1; \
    end \
end
`PAUSE_LINK(a, b)
`PAUSE_LINK(b, a)

// ================= logs =================
always @(posedge clk) begin
    send_tready <= (urand1000() >= 100);
    rc_tready   <= (urand1000() >= 100);
    if (wc_tvalid) begin $fdisplay(f_cpl, "%0d %0d %0d", wc_tdata[23:16], wc_tdata[15:0], wc_tdata[31:24]); n_cpl++; end
    if (dut_a.u_core.m_req_err_valid) $fdisplay(f_err, "%0d %02h", dut_a.u_core.m_req_err_qp, dut_a.u_core.m_req_err_code);
    if (send_tvalid && send_tready)
        $fdisplay(f_send, "%0d %0d %0128h %0d %0d %0d", send_tlast, popc(send_tkeep), send_tdata, send_tuser[7:0],
                  send_tuser[8], send_tuser[9]);
    if (commit_valid) $fdisplay(f_send, "E %0d", commit_ok);
    if (rc_tvalid && rc_tready)
        $fdisplay(f_bcpl, "%0d %0d %0d %08h %0d", rc_tdata[71:64], rc_tdata[72], rc_tdata[73], rc_tdata[31:0],
                  rc_tdata[63:32]);
    if (dut_b.u_core.m_resp_err_valid) $fdisplay(f_berr, "%0d %02h", dut_b.u_core.m_resp_err_qp, dut_b.u_core.m_resp_err_code);
    if (b_other_tvalid) $fdisplay(f_oth, "%0d %0d %0128h 0", b_other_tlast, popc(b_other_tkeep), b_other_tdata);
end

function automatic logic [15:0] csum(input byte unsigned f [], input int off, input int len);
    logic [31:0] s = 0;
    for (int i = 0; i < len; i += 2) s += {f[off + i], f[off + i + 1]};
    while (s[31:16] != 0) s = s[15:0] + s[31:16];
    return ~s[15:0];
endfunction

// ARP / ICMP towards A and a frame through A's other-traffic port, once traffic runs
initial begin
    byte unsigned arp [];
    byte unsigned icmp [];
    logic [15:0] ck;
    wait (cfg_done);
    repeat (3000) @(posedge clk);
    arp = new[60];
    foreach (arp[i]) arp[i] = 0;
    for (int i = 0; i < 6; i++) begin arp[i] = 8'hFF; arp[6 + i] = 8'h10 + i; arp[22 + i] = 8'h10 + i; end
    arp[12] = 8'h08; arp[13] = 8'h06; arp[14] = 0; arp[15] = 1; arp[16] = 8'h08; arp[17] = 0; arp[18] = 6; arp[19] = 4;
    arp[20] = 0; arp[21] = 1;
    arp[28] = 192; arp[29] = 168; arp[30] = 2; arp[31] = 1;
    arp[38] = 192; arp[39] = 168; arp[40] = 2; arp[41] = 10;
    inject_ba(arp, 60);
    repeat (500) @(posedge clk);
    icmp = new[98];
    foreach (icmp[i]) icmp[i] = 8'(i * 7);
    for (int i = 0; i < 6; i++) begin icmp[i] = MAC_A[(5-i)*8 +: 8]; icmp[6 + i] = 8'h10 + i; end
    icmp[12] = 8'h08; icmp[13] = 8'h00; icmp[14] = 8'h45; icmp[15] = 0; icmp[16] = 0; icmp[17] = 84;
    icmp[18] = 0; icmp[19] = 1; icmp[20] = 8'h40; icmp[21] = 0; icmp[22] = 64; icmp[23] = 1; icmp[24] = 0; icmp[25] = 0;
    icmp[26] = 192; icmp[27] = 168; icmp[28] = 2; icmp[29] = 1;
    icmp[30] = 192; icmp[31] = 168; icmp[32] = 2; icmp[33] = 10;
    icmp[34] = 8; icmp[35] = 0; icmp[36] = 0; icmp[37] = 0; icmp[38] = 0; icmp[39] = 1; icmp[40] = 0; icmp[41] = 1;
    ck = csum(icmp, 14, 20);
    icmp[24] = ck[15:8]; icmp[25] = ck[7:0];
    ck = csum(icmp, 34, 64);
    icmp[36] = ck[15:8]; icmp[37] = ck[7:0];
    inject_ba(icmp, 98);
    repeat (500) @(posedge clk);
    // other traffic: a 200-byte frame through A's s_axis_other, slowly (gaps between beats)
    for (int b = 0; b < 4; b++) begin
        for (int j = 0; j < 64; j++) ao_tdata[j*8 +: 8] <= 8'(b * 64 + j + 3);
        if (b == 0) begin
            for (int j = 0; j < 6; j++) begin ao_tdata[j*8 +: 8] <= MAC_B[(5-j)*8 +: 8]; ao_tdata[(6+j)*8 +: 8] <= MAC_A[(5-j)*8 +: 8]; end
            ao_tdata[12*8 +: 8] <= 8'h88; ao_tdata[13*8 +: 8] <= 8'hB5;
        end
        ao_tkeep <= (b == 3) ? 64'h0000_00FF : '1;
        ao_tlast <= (b == 3);
        ao_tvalid <= 1'b1;
        @(posedge clk);
        while (!ao_tready) @(posedge clk);
        ao_tvalid <= 1'b0;
        repeat (20) @(posedge clk);
    end
    repeat (2000) @(posedge clk);
    ctl_done = 1;
end

// forced QP error on A (QP_ERR_CMD) once ferr_at completions arrived
initial begin
    wait (cfg_done);
    if (ferr_qp >= 0) begin
        while (n_cpl < ferr_at) @(posedge clk);
        a_write(R_QP_ERR_CMD, ferr_qp);
    end
end

// ================= end =================
int idle = 0;
always @(posedge clk) begin
    if (wr_done) idle <= (a_tx_tvalid || b_tx_tvalid || qd_ab.size() || qd_ba.size()) ? 0 : idle + 1;
end
initial begin
    logic [31:0] va [NCNT], vb [NCNT];
    wait (wr_done && ctl_done);
    while (!((nwr_exp != 0 && n_cpl >= nwr_exp && idle > 300) || idle > 60000)) @(posedge clk);
    for (int i = 0; i < NCNT; i++) begin a_read(R_CNT_BASE + 16'(4 * i), va[i]); b_read(R_CNT_BASE + 16'(4 * i), vb[i]); end
    for (int i = 0; i < NCNT; i++) $display("TB_CNT %0d %0d %0d", i, va[i], vb[i]);
    b_mem.dump({dir, "/mem.txt"});
    $display("TB_DONE cpl=%0d frames_ab=%0d dropped_ab=%0d frames_ba=%0d dropped_ba=%0d rtx=%0d rnr_sent=%0d rnr_rx=%0d pause_a=%0d pause_b=%0d axi_err=%0d",
             n_cpl, n_ab, d_ab, n_ba, d_ba, va[C_REQ_RTX], vb[C_RX_RNR_SENT], va[C_RX_RNR_NAK],
             va[C_PAUSE_GATE], vb[C_PAUSE_GATE], a_mem.errors + b_mem.errors);
    $fclose(f_cpl); $fclose(f_err); $fclose(f_send); $fclose(f_bcpl); $fclose(f_berr); $fclose(f_ctl); $fclose(f_oth);
    $finish;
end

initial begin
    #400ms;
    $display("TB_TIMEOUT cpl=%0d", n_cpl);
    $finish;
end

endmodule
