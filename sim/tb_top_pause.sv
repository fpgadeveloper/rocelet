// SPDX-License-Identifier: MIT
//
// tb_top_pause - 802.3x PAUSE timing of rocelet_top for one link speed / clock / MAC width
// (test_pause.py runs 10G, 25G, 40G and 100G). The clock runs at CLK_KHZ, so the hold is
// measured in nanoseconds against 512 bit times x quanta at LINK_GBPS:
//   * the capability registers (CAPS, CLK_KHZ) and the PAUSE_QCLK reset value;
//   * received quanta (mac_pause_valid pulse with mac_pause_quanta, the CMAC way) for
//     several quanta: the TX gate's length (TB_Q lines; checked by the driver);
//   * an XON (quanta 0) ends a running PAUSE;
//   * PAUSE_QCLK rewritten by firmware (x 2): the hold doubles;
//   * level mode (CTRL.PAUSE_RX_LEVEL, a MAC that times the quanta itself, e.g. omac):
//     the gate follows mac_pause_hold;
//   * the gate really holds TX: a frame offered on the other-traffic port while paused
//     leaves the MAC TX port only after the gate drops.
// Prints TB_CAPS / TB_Q / TB_XON / TB_LEVEL / TB_TXHOLD / TB_DONE lines.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none
`include "axil_bfm.svh"

module tb_top_pause
    import rocelet_regs_pkg::*;
#(
    parameter int CLK_MHZ   = 156,
    parameter int CLK_KHZ   = 156250,
    parameter int LINK_GBPS = 10,
    parameter int MAC_WIDTH = 64
);
localparam int KB = MAC_WIDTH / 8;
localparam realtime HALF = 500000.0 / CLK_KHZ * 1ns;

logic clk = 1'b0, rst = 1'b1;
always #(HALF) clk = ~clk;

logic                 p_hold = 1'b0, p_valid = 1'b0;
logic [15:0]          p_quanta = '0;
wire  logic           p_req;
wire  logic [MAC_WIDTH-1:0] tx_tdata;
wire  logic [KB-1:0]  tx_tkeep;
wire  logic           tx_tvalid, tx_tlast, tx_tuser;
logic [511:0]         o_tdata = '0;
logic [63:0]          o_tkeep = '0;
logic                 o_tvalid = 1'b0, o_tlast = 1'b0;
wire  logic           o_tready;

logic [15:0] c_awaddr, c_araddr;
logic        c_awvalid = 1'b0, c_wvalid = 1'b0, c_bready = 1'b0, c_arvalid = 1'b0, c_rready = 1'b0;
logic [31:0] c_wdata;
logic [3:0]  c_wstrb;
wire  logic  c_awready, c_wready, c_bvalid, c_arready, c_rvalid;
wire  logic [31:0] c_rdata;
wire  logic [1:0]  c_bresp, c_rresp;
`AXIL_BFM(c)

rocelet_top #(
    .NUM_QP(2), .NUM_MR(1), .READ_DEPTH(2), .RTX_MODE("RING"), .RING_BYTES(16384), .RING_RAM("block"),
    .MAX_WR(8), .MEM_RD_BUF(128), .CLK_MHZ(CLK_MHZ), .CLK_KHZ(CLK_KHZ), .LINK_GBPS(LINK_GBPS),
    .MAC_WIDTH(MAC_WIDTH)
) dut (
    .clk(clk), .rst(rst), .irq(),
    .mac_rx_reset(1'b0), .mac_tx_reset(1'b0), .mac_rx_status(1'b1), .link_up(1'b1),
    .s_axis_rx_tdata('0), .s_axis_rx_tkeep('0), .s_axis_rx_tvalid(1'b0), .s_axis_rx_tlast(1'b0),
    .s_axis_rx_tuser(1'b0),
    .m_axis_tx_tdata(tx_tdata), .m_axis_tx_tkeep(tx_tkeep), .m_axis_tx_tvalid(tx_tvalid),
    .m_axis_tx_tready(1'b1), .m_axis_tx_tlast(tx_tlast), .m_axis_tx_tuser(tx_tuser),
    .mac_pause_hold(p_hold), .mac_pause_valid(p_valid), .mac_pause_quanta(p_quanta), .mac_pause_req(p_req),
    .mac_pause_rx_frame(p_valid), .mac_pause_tx_frame(1'b0), .mac_fec_corr_inc(1'b0), .mac_fec_uncorr_inc(1'b0),
    .m_axis_other_tdata(), .m_axis_other_tkeep(), .m_axis_other_tvalid(), .m_axis_other_tready(1'b1),
    .m_axis_other_tlast(),
    .s_axis_other_tdata(o_tdata), .s_axis_other_tkeep(o_tkeep), .s_axis_other_tvalid(o_tvalid),
    .s_axis_other_tready(o_tready), .s_axis_other_tlast(o_tlast),
    .s_axis_wr_tdata('0), .s_axis_wr_tvalid(1'b0), .s_axis_wr_tready(),
    .s_axis_wr_data_tdata('0), .s_axis_wr_data_tvalid(1'b0), .s_axis_wr_data_tready(), .s_axis_wr_data_tlast(1'b0),
    .m_axis_wc_tdata(), .m_axis_wc_tvalid(), .m_axis_wc_tready(1'b1),
    .m_axis_send_tdata(), .m_axis_send_tkeep(), .m_axis_send_tvalid(), .m_axis_send_tready(1'b1),
    .m_axis_send_tlast(), .m_axis_send_tuser(), .send_commit_valid(), .send_commit_ok(), .send_rnr('0),
    .m_axis_rc_tdata(), .m_axis_rc_tvalid(), .m_axis_rc_tready(1'b1),
    .m_axi_awid(), .m_axi_awaddr(), .m_axi_awlen(), .m_axi_awsize(), .m_axi_awburst(), .m_axi_awlock(),
    .m_axi_awcache(), .m_axi_awprot(), .m_axi_awvalid(), .m_axi_awready(1'b1), .m_axi_wdata(), .m_axi_wstrb(),
    .m_axi_wlast(), .m_axi_wvalid(), .m_axi_wready(1'b1), .m_axi_bid('0), .m_axi_bresp('0), .m_axi_bvalid(1'b0),
    .m_axi_bready(), .m_axi_arid(), .m_axi_araddr(), .m_axi_arlen(), .m_axi_arsize(), .m_axi_arburst(),
    .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(), .m_axi_arvalid(), .m_axi_arready(1'b1), .m_axi_rid('0),
    .m_axi_rdata('0), .m_axi_rresp('0), .m_axi_rlast(1'b0), .m_axi_rvalid(1'b0), .m_axi_rready(),
    .s_axil_awaddr(c_awaddr), .s_axil_awvalid(c_awvalid), .s_axil_awready(c_awready), .s_axil_wdata(c_wdata),
    .s_axil_wstrb(c_wstrb), .s_axil_wvalid(c_wvalid), .s_axil_wready(c_wready), .s_axil_bresp(c_bresp),
    .s_axil_bvalid(c_bvalid), .s_axil_bready(c_bready), .s_axil_araddr(c_araddr), .s_axil_arvalid(c_arvalid),
    .s_axil_arready(c_arready), .s_axil_rdata(c_rdata), .s_axil_rresp(c_rresp), .s_axil_rvalid(c_rvalid),
    .s_axil_rready(c_rready)
);

wire logic gate = dut.u_mac.pause_gate;

// gate high time of the next PAUSE
realtime t_rise, t_fall;
task automatic measure(output realtime dur);
    @(posedge gate);
    t_rise = $realtime;
    @(negedge gate);
    t_fall = $realtime;
    dur = t_fall - t_rise;
endtask

task automatic pulse(input logic [15:0] q);
    @(posedge clk);
    p_quanta <= q; p_valid <= 1'b1;
    @(posedge clk);
    p_valid <= 1'b0;
endtask

int nerr = 0;
initial begin
    logic [31:0] rd, qclk;
    realtime d;
    int qs [6] = '{1, 7, 100, 1000, 20000, 65535};
    repeat (10) @(posedge clk);
    rst <= 1'b0;
    repeat (10) @(posedge clk);
    c_read(R_VERSION, rd);
    $display("TB_CAPS version=%08h", rd);
    c_read(R_CAPS, rd);
    $display("TB_CAPS caps=%08h", rd);
    c_read(R_CLK_KHZ, rd);
    $display("TB_CAPS clk_khz=%0d", rd);
    c_read(R_PAUSE_QCLK, qclk);
    $display("TB_CAPS pause_qclk=%0d", qclk);
    // received quanta
    foreach (qs[i]) begin
        fork
            measure(d);
            pulse(16'(qs[i]));
        join
        $display("TB_Q q=%0d ns=%0.3f", qs[i], d / 1ns);
        repeat (20) @(posedge clk);
    end
    c_read(R_PAUSE_STATUS, rd);
    if (rd[15:0] != 16'd65535) begin nerr++; $display("TB_ERROR PAUSE_STATUS.QUANTA %08h", rd); end
    // XON ends a running PAUSE
    fork
        measure(d);
        begin
            pulse(16'hFFFF);
            repeat (200) @(posedge clk);
            pulse(16'h0000);
        end
    join
    $display("TB_XON ns=%0.3f clocks=%0.1f", d / 1ns, d / (2 * HALF));
    repeat (20) @(posedge clk);
    // firmware rewrites PAUSE_QCLK (x 2): the hold doubles
    c_write(R_PAUSE_QCLK, 2 * qclk);
    fork
        measure(d);
        pulse(16'd1000);
    join
    $display("TB_Q2 q=1000 ns=%0.3f", d / 1ns);
    c_write(R_PAUSE_QCLK, qclk);
    repeat (20) @(posedge clk);
    // level mode
    c_read(R_CTRL, rd);
    c_write(R_CTRL, rd | 32'h400);
    fork
        measure(d);
        begin
            @(posedge clk); p_hold <= 1'b1;
            repeat (500) @(posedge clk); p_hold <= 1'b0;
        end
    join
    $display("TB_LEVEL clocks=%0.1f", d / (2 * HALF));
    repeat (20) @(posedge clk);
    // TX held while paused: a frame offered on the other-traffic port during a PAUSE
    fork
        measure(d);
        begin
            pulse(16'd2000);
            repeat (20) @(posedge clk);
            o_tdata <= {448'd0, 16'hB588, 48'h02_00_00_00_00_01}; o_tkeep <= 64'hFFFF_FFFF_FFFF_FFFF;
            o_tlast <= 1'b1; o_tvalid <= 1'b1;
            @(posedge clk);
            while (!o_tready) @(posedge clk);
            o_tvalid <= 1'b0;
        end
    join
    @(posedge clk iff tx_tvalid);
    $display("TB_TXHOLD first_tx_after_gate_ns=%0.3f", ($realtime - t_fall) / 1ns);
    repeat (50) @(posedge clk);
    $display("TB_DONE errors=%0d", nerr);
    $finish;
end

// the gate must not drop the frame-level hold: no TX beat while the gate is high
always @(posedge clk) if (gate && tx_tvalid && !$isunknown(tx_tvalid) && t_rise > 0 && $realtime - t_rise > 20 * 2 * HALF)
    $display("TB_ERROR TX beat while paused at %0t", $realtime);

initial begin
    #20ms;
    $display("TB_TIMEOUT");
    $finish;
end

endmodule
