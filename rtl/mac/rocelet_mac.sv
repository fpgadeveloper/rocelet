// SPDX-License-Identifier: MIT
//
// rocelet_mac - the MAC glue between a 100G CMAC (512-bit AXI-Stream, CMAC user clock) and
// the engine:
//
//   CMAC RX -> rocelet_rx_fifo (store-and-forward; drops bad-FCS / overflow frames: the CMAC
//              cannot be back-pressured, the engine can stall; its fill level drives the
//              802.3x PAUSE requests)
//           -> rocelet_vlan_strip (removes 802.1Q VID-0 priority tags)
//           -> rocelet_rx_cls --> RoCE (UDP 4791)          -> engine
//                             --> ARP / ICMP to my IP       -> rocelet_arp_icmp (or "other")
//                             --> other                     -> m_axis_other (or dropped)
//   engine TX -> rocelet_vlan_ins (optional tag) -> TX FIFO (store-and-forward: the CMAC must
//              not see a gap inside a frame) --+
//   ARP / ICMP replies -> small FIFO ----------+-> rocelet_mac_arb (frame-atomic; held while a
//   s_axis_other -> store-and-forward FIFO ----+   received PAUSE is in force) -> CMAC TX
//   rocelet_pause: received PAUSE -> TX gate; RX FIFO level -> ctl_tx_pause_req.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_mac
    import rocelet_pkg::*;
#(
    parameter bit IPV6_EN             = 1'b0,
    parameter bit VLAN_EN             = 1'b1,
    parameter bit PAUSE_EN            = 1'b1,
    parameter bit ARP_EN              = 1'b1,
    parameter bit OTHER_EN            = 1'b1,
    parameter int RX_FIFO_DEPTH       = 512,
    parameter int TX_FIFO_DEPTH       = 512,
    parameter int OTHER_TX_FIFO_DEPTH = 256,
    parameter int CLK_MHZ             = 322,
    localparam int FW = $clog2(RX_FIFO_DEPTH) + 1
) (
    input  wire logic          clk,
    input  wire logic          rst,

    // configuration
    input  wire logic [47:0]   my_mac,
    input  wire logic [31:0]   my_ip4,
    input  wire logic          rx_en,
    input  wire logic          tx_en,
    input  wire logic          vlan_rx_strip,
    input  wire logic          vlan_tx_tag,
    input  wire logic [15:0]   vlan_tci,
    input  wire logic          arp_int,
    input  wire logic          other_rx_en,
    input  wire logic          pause_rx_en,
    input  wire logic          pause_rx_level,
    input  wire logic          pause_tx_en,
    input  wire logic [15:0]   pause_xoff,
    input  wire logic [15:0]   pause_xon,

    // CMAC
    input  wire logic          mac_rx_reset,
    input  wire logic          mac_tx_reset,
    input  wire logic [511:0]  s_axis_rx_tdata,
    input  wire logic [63:0]   s_axis_rx_tkeep,
    input  wire logic          s_axis_rx_tvalid,
    input  wire logic          s_axis_rx_tlast,
    input  wire logic          s_axis_rx_tuser,
    output wire logic [511:0]  m_axis_tx_tdata,
    output wire logic [63:0]   m_axis_tx_tkeep,
    output wire logic          m_axis_tx_tvalid,
    input  wire logic          m_axis_tx_tready,
    output wire logic          m_axis_tx_tlast,
    input  wire logic [8:0]    stat_rx_pause_req,
    input  wire logic [8:0]    stat_rx_pause_valid,
    input  wire logic [15:0]   stat_rx_pause_quanta8,
    output wire logic [8:0]    ctl_tx_pause_req,

    // engine
    output wire logic [511:0]  m_eng_tdata,
    output wire logic [63:0]   m_eng_tkeep,
    output wire logic          m_eng_tvalid,
    input  wire logic          m_eng_tready,
    output wire logic          m_eng_tlast,
    input  wire logic [511:0]  s_eng_tdata,
    input  wire logic [63:0]   s_eng_tkeep,
    input  wire logic          s_eng_tvalid,
    output wire logic          s_eng_tready,
    input  wire logic          s_eng_tlast,

    // other traffic
    output wire logic [511:0]  m_axis_other_tdata,
    output wire logic [63:0]   m_axis_other_tkeep,
    output wire logic          m_axis_other_tvalid,
    input  wire logic          m_axis_other_tready,
    output wire logic          m_axis_other_tlast,
    input  wire logic [511:0]  s_axis_other_tdata,
    input  wire logic [63:0]   s_axis_other_tkeep,
    input  wire logic          s_axis_other_tvalid,
    output wire logic          s_axis_other_tready,
    input  wire logic          s_axis_other_tlast,

    // status
    output wire logic [FW-1:0] rx_fill,
    output wire logic          pause_gate,
    output wire logic          pause_req,
    output wire logic [15:0]   pause_quanta,
    output wire logic [15:0]   vlan_last_tci,
    output mac_ev_t            ev
);

// ================= RX =================
wire logic [511:0] x_tdata, v_tdata;
wire logic [63:0]  x_tkeep, v_tkeep;
wire logic         x_tvalid, x_tready, x_tlast, v_tvalid, v_tready, v_tlast;
wire logic         ev_rx_frame, ev_rx_err, ev_rx_drop;

rocelet_rx_fifo #(.DEPTH(RX_FIFO_DEPTH)) u_rxf (
    .clk(clk), .rst(rst), .s_abort(mac_rx_reset), .s_hold(mac_tx_reset || !rx_en),
    .s_tdata(s_axis_rx_tdata), .s_tkeep(s_axis_rx_tkeep), .s_tvalid(s_axis_rx_tvalid),
    .s_tlast(s_axis_rx_tlast), .s_tuser(s_axis_rx_tuser),
    .m_axis_tdata(x_tdata), .m_axis_tkeep(x_tkeep), .m_axis_tvalid(x_tvalid), .m_axis_tready(x_tready),
    .m_axis_tlast(x_tlast),
    .fill(rx_fill), .ev_frame(ev_rx_frame), .ev_err(ev_rx_err), .ev_drop(ev_rx_drop)
);

logic        ev_vstrip, ev_vother;
logic [15:0] last_tci;
if (VLAN_EN) begin : g_vstrip
    rocelet_vlan_strip u_vstrip (
        .clk(clk), .rst(rst), .enable(vlan_rx_strip),
        .s_axis_tdata(x_tdata), .s_axis_tkeep(x_tkeep), .s_axis_tvalid(x_tvalid), .s_axis_tready(x_tready),
        .s_axis_tlast(x_tlast),
        .m_axis_tdata(v_tdata), .m_axis_tkeep(v_tkeep), .m_axis_tvalid(v_tvalid), .m_axis_tready(v_tready),
        .m_axis_tlast(v_tlast),
        .ev_strip(ev_vstrip), .ev_tagged(ev_vother), .last_tci(last_tci)
    );
end else begin : g_novstrip
    assign v_tdata = x_tdata; assign v_tkeep = x_tkeep; assign v_tvalid = x_tvalid;
    assign x_tready = v_tready; assign v_tlast = x_tlast;
    assign ev_vstrip = 1'b0; assign ev_vother = 1'b0; assign last_tci = '0;
end
assign vlan_last_tci = last_tci;

wire logic [511:0] c_tdata, o_tdata;
wire logic [63:0]  c_tkeep, o_tkeep;
wire logic         c_tvalid, c_tready, c_tlast, o_tvalid, o_tready, o_tlast;
logic              ev_roce, ev_arp, ev_icmp, ev_oth, ev_oth_drop;

rocelet_rx_cls #(.IPV6_EN(IPV6_EN)) u_cls (
    .clk(clk), .rst(rst), .my_ip4(my_ip4), .arp_int(ARP_EN && arp_int), .other_en(OTHER_EN && other_rx_en),
    .s_axis_tdata(v_tdata), .s_axis_tkeep(v_tkeep), .s_axis_tvalid(v_tvalid), .s_axis_tready(v_tready),
    .s_axis_tlast(v_tlast),
    .m_roce_tdata(m_eng_tdata), .m_roce_tkeep(m_eng_tkeep), .m_roce_tvalid(m_eng_tvalid),
    .m_roce_tready(m_eng_tready), .m_roce_tlast(m_eng_tlast),
    .m_ctl_tdata(c_tdata), .m_ctl_tkeep(c_tkeep), .m_ctl_tvalid(c_tvalid), .m_ctl_tready(c_tready),
    .m_ctl_tlast(c_tlast),
    .m_oth_tdata(o_tdata), .m_oth_tkeep(o_tkeep), .m_oth_tvalid(o_tvalid), .m_oth_tready(o_tready),
    .m_oth_tlast(o_tlast),
    .ev_roce(ev_roce), .ev_arp(ev_arp), .ev_icmp(ev_icmp), .ev_other(ev_oth), .ev_other_drop(ev_oth_drop)
);

if (OTHER_EN) begin : g_orx
    assign m_axis_other_tdata  = o_tdata;
    assign m_axis_other_tkeep  = o_tkeep;
    assign m_axis_other_tvalid = o_tvalid;
    assign m_axis_other_tlast  = o_tlast;
    assign o_tready = m_axis_other_tready;
end else begin : g_noorx
    assign m_axis_other_tdata = '0; assign m_axis_other_tkeep = '0; assign m_axis_other_tvalid = 1'b0;
    assign m_axis_other_tlast = 1'b0; assign o_tready = 1'b1;
end

// ================= TX sources =================
logic [511:0] arb_tdata [3];
logic [63:0]  arb_tkeep [3];
logic [2:0]   arb_tvalid, arb_tready, arb_tlast, tx_src;

// 0: ARP / ICMP replies
if (ARP_EN) begin : g_arp
    wire logic [511:0] a_tdata;
    wire logic [63:0]  a_tkeep;
    wire logic         a_tvalid, a_tready, a_tlast;
    rocelet_arp_icmp u_arp (
        .clk(clk), .rst(rst), .my_mac(my_mac), .my_ip4(my_ip4),
        .s_axis_tdata(c_tdata), .s_axis_tkeep(c_tkeep), .s_axis_tvalid(c_tvalid), .s_axis_tready(c_tready),
        .s_axis_tlast(c_tlast),
        .m_axis_tdata(a_tdata), .m_axis_tkeep(a_tkeep), .m_axis_tvalid(a_tvalid), .m_axis_tready(a_tready),
        .m_axis_tlast(a_tlast),
        .ev_arp(), .ev_icmp()
    );
    rocelet_pkt_fifo #(.DEPTH(32), .RAM_STYLE("distributed")) u_arpf (
        .clk(clk), .rst(rst),
        .s_axis_tdata(a_tdata), .s_axis_tkeep(a_tkeep), .s_axis_tvalid(a_tvalid), .s_axis_tready(a_tready),
        .s_axis_tlast(a_tlast),
        .m_axis_tdata(arb_tdata[0]), .m_axis_tkeep(arb_tkeep[0]), .m_axis_tvalid(arb_tvalid[0]),
        .m_axis_tready(arb_tready[0]), .m_axis_tlast(arb_tlast[0])
    );
end else begin : g_noarp
    assign c_tready = 1'b1;
    assign arb_tdata[0] = '0; assign arb_tkeep[0] = '0; assign arb_tvalid[0] = 1'b0; assign arb_tlast[0] = 1'b0;
end

// 1: other traffic
if (OTHER_EN) begin : g_otx
    rocelet_pkt_fifo #(.DEPTH(OTHER_TX_FIFO_DEPTH), .RAM_STYLE("block")) u_othf (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_axis_other_tdata), .s_axis_tkeep(s_axis_other_tkeep), .s_axis_tvalid(s_axis_other_tvalid),
        .s_axis_tready(s_axis_other_tready), .s_axis_tlast(s_axis_other_tlast),
        .m_axis_tdata(arb_tdata[1]), .m_axis_tkeep(arb_tkeep[1]), .m_axis_tvalid(arb_tvalid[1]),
        .m_axis_tready(arb_tready[1]), .m_axis_tlast(arb_tlast[1])
    );
end else begin : g_nootx
    assign s_axis_other_tready = 1'b1;
    assign arb_tdata[1] = '0; assign arb_tkeep[1] = '0; assign arb_tvalid[1] = 1'b0; assign arb_tlast[1] = 1'b0;
end

// 2: the engine
wire logic [511:0] j_tdata;
wire logic [63:0]  j_tkeep;
wire logic         j_tvalid, j_tready, j_tlast;
logic              ev_vtag;
if (VLAN_EN) begin : g_vins
    rocelet_vlan_ins u_vins (
        .clk(clk), .rst(rst), .enable(vlan_tx_tag), .tci(vlan_tci),
        .s_axis_tdata(s_eng_tdata), .s_axis_tkeep(s_eng_tkeep), .s_axis_tvalid(s_eng_tvalid),
        .s_axis_tready(s_eng_tready), .s_axis_tlast(s_eng_tlast),
        .m_axis_tdata(j_tdata), .m_axis_tkeep(j_tkeep), .m_axis_tvalid(j_tvalid), .m_axis_tready(j_tready),
        .m_axis_tlast(j_tlast), .ev_tag(ev_vtag)
    );
end else begin : g_novins
    assign j_tdata = s_eng_tdata; assign j_tkeep = s_eng_tkeep; assign j_tvalid = s_eng_tvalid;
    assign s_eng_tready = j_tready; assign j_tlast = s_eng_tlast; assign ev_vtag = 1'b0;
end
rocelet_pkt_fifo #(.DEPTH(TX_FIFO_DEPTH), .RAM_STYLE("block")) u_txf (
    .clk(clk), .rst(rst),
    .s_axis_tdata(j_tdata), .s_axis_tkeep(j_tkeep), .s_axis_tvalid(j_tvalid), .s_axis_tready(j_tready),
    .s_axis_tlast(j_tlast),
    .m_axis_tdata(arb_tdata[2]), .m_axis_tkeep(arb_tkeep[2]), .m_axis_tvalid(arb_tvalid[2]),
    .m_axis_tready(arb_tready[2]), .m_axis_tlast(arb_tlast[2])
);

// ================= PAUSE and the TX arbiter =================
logic gate, ev_pload, ev_pxoff;
if (PAUSE_EN) begin : g_pause
    logic        req;
    logic [15:0] lq;
    rocelet_pause #(.CLK_MHZ(CLK_MHZ), .FILL_W(FW)) u_pause (
        .clk(clk), .rst(rst),
        .honour_en(pause_rx_en), .level_en(pause_rx_level), .req_en(pause_tx_en),
        .xoff(pause_xoff), .xon(pause_xon), .fill(rx_fill),
        .stat_rx_pause_req(stat_rx_pause_req), .stat_rx_pause_valid(stat_rx_pause_valid),
        .stat_rx_pause_quanta8(stat_rx_pause_quanta8), .ctl_tx_pause_req(ctl_tx_pause_req),
        .gate(gate), .req(req), .last_quanta(lq), .ev_load(ev_pload), .ev_xoff(ev_pxoff)
    );
    assign pause_req    = req;
    assign pause_quanta = lq;
end else begin : g_nopause
    assign ctl_tx_pause_req = '0;
    assign gate = 1'b0; assign ev_pload = 1'b0; assign ev_pxoff = 1'b0;
    assign pause_req = 1'b0; assign pause_quanta = '0;
end
assign pause_gate = gate;

logic hold = 1'b1;
always_ff @(posedge clk) hold <= gate || !tx_en || rst;

logic [511:0] t_tdata;
logic [63:0]  t_tkeep;
logic         t_tvalid, t_tlast;
rocelet_mac_arb #(.N(3)) u_arb (
    .clk(clk), .rst(rst), .hold(hold),
    .s_tdata(arb_tdata), .s_tkeep(arb_tkeep), .s_tvalid(arb_tvalid), .s_tready(arb_tready), .s_tlast(arb_tlast),
    .m_tdata(t_tdata), .m_tkeep(t_tkeep), .m_tvalid(t_tvalid), .m_tready(m_axis_tx_tready), .m_tlast(t_tlast),
    .m_src(tx_src)
);
assign m_axis_tx_tdata  = t_tdata;
assign m_axis_tx_tkeep  = t_tkeep;
assign m_axis_tx_tvalid = t_tvalid;
assign m_axis_tx_tlast  = t_tlast;

// ================= events =================
wire logic [6:0] rx_n, tx_n;
rocelet_keep2n #(.KW(64)) u_rxn (.keep(s_axis_rx_tkeep), .n(rx_n));
rocelet_keep2n #(.KW(64)) u_txn (.keep(t_tkeep), .n(tx_n));
logic tx_first = 1'b1;
wire  logic tx_fire = t_tvalid && m_axis_tx_tready;
always_ff @(posedge clk) begin
    if (tx_fire) tx_first <= t_tlast;
    if (rst) tx_first <= 1'b1;
end
always_ff @(posedge clk) begin
    ev.rx_frame      <= ev_rx_frame;
    ev.rx_fcs_err    <= ev_rx_err;
    ev.rx_fifo_drop  <= ev_rx_drop;
    ev.rx_roce       <= ev_roce;
    ev.rx_arp        <= ev_arp;
    ev.rx_icmp       <= ev_icmp;
    ev.rx_other      <= ev_oth;
    ev.rx_other_drop <= ev_oth_drop;
    ev.rx_vlan_strip <= ev_vstrip;
    ev.rx_vlan_other <= ev_vother;
    ev.tx_frame      <= tx_fire && tx_first;
    ev.tx_arp_icmp   <= tx_fire && tx_first && tx_src[0];
    ev.tx_other      <= tx_fire && tx_first && tx_src[1];
    ev.tx_underrun   <= !tx_first && !t_tvalid;
    ev.tx_vlan_tag   <= ev_vtag;
    ev.pause_load    <= ev_pload;
    ev.pause_xoff    <= ev_pxoff;
    ev.rx_bytes      <= s_axis_rx_tvalid ? rx_n : 7'd0;
    ev.tx_bytes      <= tx_fire ? tx_n : 7'd0;
end

endmodule

`resetall
