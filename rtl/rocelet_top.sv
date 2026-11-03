// SPDX-License-Identifier: MIT
//
// rocelet_top - the rocelet RoCE v2 IP: engine (rocelet_core), MAC glue (rocelet_mac),
// AXI4-Lite register file (rocelet_regs) and AXI4 memory master (rocelet_axi_mem), in one
// clock domain (the 100G CMAC user clock). Port list and parameters: docs/interface.md;
// register map: docs/registers.md; architecture: docs/architecture.md.
//
//   CMAC <-> rocelet_mac <-> rocelet_core <-> rocelet_axi_mem <-> m_axi (FPGA memory)
//                 |               |   ^
//          other traffic     WR / WC  |  SEND / receive completions
//                                     |
//   s_axil -> rocelet_regs -----------+  (configuration, status, counters)
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_top
    import rocelet_pkg::*;
    import rocelet_regs_pkg::*;
#(
    parameter int          NUM_QP              = 16,
    parameter int          NUM_MR              = 16,
    parameter logic [23:0] QPN_BASE            = 24'h000100,
    parameter bit          PMTU_RUNTIME        = 1'b1,
    parameter int          PMTU_LOG2           = 12,
    parameter int          READ_DEPTH          = 16,
    parameter              RTX_MODE            = "RING",
    parameter int          RING_BYTES          = 262144,
    parameter              RING_RAM            = "ultra",
    parameter int          MAX_WR              = 128,
    parameter bit          RX_ICRC_EN          = 1'b1,
    parameter bit          ICRC_SHARE          = 1'b1,
    parameter bit          IPV6_EN             = 1'b0,
    parameter bit          HSB_EN              = 1'b1,
    parameter bit          VLAN_EN             = 1'b1,
    parameter bit          PAUSE_EN            = 1'b1,
    parameter bit          ARP_EN              = 1'b1,
    parameter bit          OTHER_EN            = 1'b1,
    parameter bit          COUNTERS_EN         = 1'b1,
    parameter int          RX_FIFO_DEPTH       = 512,
    parameter int          TX_FIFO_DEPTH       = 512,
    parameter int          OTHER_TX_FIFO_DEPTH = 256,
    parameter int          M_AXI_ADDR_W        = 64,
    parameter int          M_AXI_ID_W          = 2,
    parameter int          MEM_RD_BUF          = 256,
    parameter int          CLK_MHZ             = 322,
    parameter bit          READ_CONT_DEFAULT   = 1'b1
) (
    input  wire logic                    clk,
    input  wire logic                    rst,
    output wire logic                    irq,

    // CMAC side
    input  wire logic                    mac_rx_reset,
    input  wire logic                    mac_tx_reset,
    input  wire logic                    mac_rx_aligned,
    input  wire logic                    link_up,
    input  wire logic [511:0]            s_axis_rx_tdata,
    input  wire logic [63:0]             s_axis_rx_tkeep,
    input  wire logic                    s_axis_rx_tvalid,
    input  wire logic                    s_axis_rx_tlast,
    input  wire logic                    s_axis_rx_tuser,
    output wire logic [511:0]            m_axis_tx_tdata,
    output wire logic [63:0]             m_axis_tx_tkeep,
    output wire logic                    m_axis_tx_tvalid,
    input  wire logic                    m_axis_tx_tready,
    output wire logic                    m_axis_tx_tlast,
    output wire logic                    m_axis_tx_tuser,
    input  wire logic [8:0]              stat_rx_pause_req,
    input  wire logic [8:0]              stat_rx_pause_valid,
    input  wire logic [15:0]             stat_rx_pause_quanta8,
    input  wire logic                    stat_rx_pause,
    input  wire logic                    stat_tx_pause,
    output wire logic [8:0]              ctl_tx_pause_req,
    input  wire logic                    stat_rx_rsfec_corrected_cw_inc,
    input  wire logic                    stat_rx_rsfec_uncorrected_cw_inc,

    // other traffic
    output wire logic [511:0]            m_axis_other_tdata,
    output wire logic [63:0]             m_axis_other_tkeep,
    output wire logic                    m_axis_other_tvalid,
    input  wire logic                    m_axis_other_tready,
    output wire logic                    m_axis_other_tlast,
    input  wire logic [511:0]            s_axis_other_tdata,
    input  wire logic [63:0]             s_axis_other_tkeep,
    input  wire logic                    s_axis_other_tvalid,
    output wire logic                    s_axis_other_tready,
    input  wire logic                    s_axis_other_tlast,

    // work requests / completions
    input  wire logic [255:0]            s_axis_wr_tdata,
    input  wire logic                    s_axis_wr_tvalid,
    output wire logic                    s_axis_wr_tready,
    input  wire logic [511:0]            s_axis_wr_data_tdata,
    input  wire logic                    s_axis_wr_data_tvalid,
    output wire logic                    s_axis_wr_data_tready,
    input  wire logic                    s_axis_wr_data_tlast,
    output wire logic [63:0]             m_axis_wc_tdata,
    output wire logic                    m_axis_wc_tvalid,
    input  wire logic                    m_axis_wc_tready,

    // responder
    output wire logic [511:0]            m_axis_send_tdata,
    output wire logic [63:0]             m_axis_send_tkeep,
    output wire logic                    m_axis_send_tvalid,
    input  wire logic                    m_axis_send_tready,
    output wire logic                    m_axis_send_tlast,
    output wire logic [15:0]             m_axis_send_tuser,
    output wire logic                    send_commit_valid,
    output wire logic                    send_commit_ok,
    input  wire logic [NUM_QP-1:0]       send_rnr,
    output wire logic [127:0]            m_axis_rc_tdata,
    output wire logic                    m_axis_rc_tvalid,
    input  wire logic                    m_axis_rc_tready,

    // memory (AXI4 master)
    output wire logic [M_AXI_ID_W-1:0]   m_axi_awid,
    output wire logic [M_AXI_ADDR_W-1:0] m_axi_awaddr,
    output wire logic [7:0]              m_axi_awlen,
    output wire logic [2:0]              m_axi_awsize,
    output wire logic [1:0]              m_axi_awburst,
    output wire logic                    m_axi_awlock,
    output wire logic [3:0]              m_axi_awcache,
    output wire logic [2:0]              m_axi_awprot,
    output wire logic                    m_axi_awvalid,
    input  wire logic                    m_axi_awready,
    output wire logic [511:0]            m_axi_wdata,
    output wire logic [63:0]             m_axi_wstrb,
    output wire logic                    m_axi_wlast,
    output wire logic                    m_axi_wvalid,
    input  wire logic                    m_axi_wready,
    input  wire logic [M_AXI_ID_W-1:0]   m_axi_bid,
    input  wire logic [1:0]              m_axi_bresp,
    input  wire logic                    m_axi_bvalid,
    output wire logic                    m_axi_bready,
    output wire logic [M_AXI_ID_W-1:0]   m_axi_arid,
    output wire logic [M_AXI_ADDR_W-1:0] m_axi_araddr,
    output wire logic [7:0]              m_axi_arlen,
    output wire logic [2:0]              m_axi_arsize,
    output wire logic [1:0]              m_axi_arburst,
    output wire logic                    m_axi_arlock,
    output wire logic [3:0]              m_axi_arcache,
    output wire logic [2:0]              m_axi_arprot,
    output wire logic                    m_axi_arvalid,
    input  wire logic                    m_axi_arready,
    input  wire logic [M_AXI_ID_W-1:0]   m_axi_rid,
    input  wire logic [511:0]            m_axi_rdata,
    input  wire logic [1:0]              m_axi_rresp,
    input  wire logic                    m_axi_rlast,
    input  wire logic                    m_axi_rvalid,
    output wire logic                    m_axi_rready,

    // control (AXI4-Lite slave)
    input  wire logic [15:0]             s_axil_awaddr,
    input  wire logic                    s_axil_awvalid,
    output wire logic                    s_axil_awready,
    input  wire logic [31:0]             s_axil_wdata,
    input  wire logic [3:0]              s_axil_wstrb,
    input  wire logic                    s_axil_wvalid,
    output wire logic                    s_axil_wready,
    output wire logic [1:0]              s_axil_bresp,
    output wire logic                    s_axil_bvalid,
    input  wire logic                    s_axil_bready,
    input  wire logic [15:0]             s_axil_araddr,
    input  wire logic                    s_axil_arvalid,
    output wire logic                    s_axil_arready,
    output wire logic [31:0]             s_axil_rdata,
    output wire logic [1:0]              s_axil_rresp,
    output wire logic                    s_axil_rvalid,
    input  wire logic                    s_axil_rready
);


localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1;
localparam int MRW = (NUM_MR > 1) ? $clog2(NUM_MR) : 1;
localparam int RTX_ID = (RTX_MODE == "RING") ? 0 : (RTX_MODE == "REREAD") ? 1 : 2;
localparam int FW = $clog2(RX_FIFO_DEPTH) + 1;

// ---------------- registers ----------------
logic           ctl_reset, ctl_rx_en, ctl_tx_en, ctl_read_cont, ctl_loss_fatal, ctl_vlan_rx_strip,
                ctl_vlan_tx_tag, ctl_arp_int, ctl_other_rx_en, ctl_pause_rx_en, ctl_pause_rx_level,
                ctl_pause_tx_en;
logic [47:0]    my_mac;
logic [31:0]    my_ip4;
logic [127:0]   my_ip6;
logic [7:0]     ip_tos, ip_ttl, ackreq_n;
logic [9:0]     tick_div;
logic [19:0]    ack_timeout, rnr_min, rnr_max;
logic [4:0]     rnr_nak_timer;
logic [15:0]    vlan_tci, pause_xoff, pause_xon;
logic [2:0]     retry_cnt, rnr_retry;
logic [19:0]    pace_inc;
logic [15:0]    pace_burst;
logic [23:0]    link_grace;
logic           qp_we, qp_valid, qp_ipv6, err_we, mr_we, mr_valid;
logic [QPW-1:0] qp_idx, err_qp;
logic [1:0]     qp_type, mr_acc;
logic [23:0]    qp_sq_psn, qp_rq_psn, qp_dqpn;
logic [3:0]     qp_pmtu;
logic [47:0]    qp_dmac;
logic [127:0]   qp_dip;
logic [15:0]    qp_sport, qp_dport;
logic [MRW-1:0] mr_idx;
logic [31:0]    mr_rkey, mr_len;
logic [63:0]    mr_va, mr_laddr;

wire  logic [NUM_QP-1:0] qp_err_req, qp_err_resp;
wire  logic           req_err_valid, resp_err_valid;
wire  logic [QPW-1:0] req_err_qp, resp_err_qp;
wire  logic [7:0]     req_err_code, resp_err_code;
wire  logic [15:0]    wr_outstanding;
wire  logic [23:0]    ring_used;
wire  logic [FW-1:0]  rx_fill;
wire  logic           pause_gate, pause_req;
wire  logic [15:0]    pause_quanta, vlan_last_tci;
logic [NCNT-1:0]      ev_cnt;
core_ev_t             cev;
mac_ev_t              mev;

// link state for the requester's ACK-timeout hold (CMAC stat_rx_aligned or stat_rx_status;
// synchronised here, as the CMAC status may come from the RX clock domain)
(* ASYNC_REG = "TRUE" *) logic link_s0 = 1'b0, link_s1 = 1'b0;
always_ff @(posedge clk) begin
    link_s0 <= link_up;
    link_s1 <= link_s0;
end
wire logic timer_hold;

// engine / MAC glue reset: rst or CTRL.RESET (register values are kept)
logic eng_rst = 1'b1;
always_ff @(posedge clk) eng_rst <= rst || ctl_reset;

rocelet_regs #(
    .NUM_QP(NUM_QP), .NUM_MR(NUM_MR), .QPN_BASE(QPN_BASE), .READ_DEPTH(READ_DEPTH), .RTX_MODE_ID(RTX_ID),
    .RING_BYTES(RING_BYTES), .MAX_WR(MAX_WR), .PMTU_LOG2(PMTU_LOG2), .PMTU_RUNTIME(PMTU_RUNTIME),
    .RX_ICRC_EN(RX_ICRC_EN), .IPV6_EN(IPV6_EN), .HSB_EN(HSB_EN), .VLAN_EN(VLAN_EN), .PAUSE_EN(PAUSE_EN),
    .ARP_EN(ARP_EN), .OTHER_EN(OTHER_EN), .COUNTERS_EN(COUNTERS_EN), .RX_FIFO_DEPTH(RX_FIFO_DEPTH),
    .TX_FIFO_DEPTH(TX_FIFO_DEPTH), .CLK_MHZ(CLK_MHZ), .READ_CONT_DEFAULT(READ_CONT_DEFAULT)
) u_regs (
    .clk(clk), .rst(rst),
    .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid),
    .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid),
    .s_axil_bready(s_axil_bready), .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid),
    .s_axil_arready(s_axil_arready), .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
    .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
    .ctl_reset(ctl_reset), .ctl_rx_en(ctl_rx_en), .ctl_tx_en(ctl_tx_en), .ctl_read_cont(ctl_read_cont),
    .ctl_loss_fatal(ctl_loss_fatal), .ctl_vlan_rx_strip(ctl_vlan_rx_strip), .ctl_vlan_tx_tag(ctl_vlan_tx_tag),
    .ctl_arp_int(ctl_arp_int), .ctl_other_rx_en(ctl_other_rx_en), .ctl_pause_rx_en(ctl_pause_rx_en),
    .ctl_pause_rx_level(ctl_pause_rx_level), .ctl_pause_tx_en(ctl_pause_tx_en),
    .my_mac(my_mac), .my_ip4(my_ip4), .my_ip6(my_ip6), .ip_tos(ip_tos), .ip_ttl(ip_ttl),
    .tick_div(tick_div), .ack_timeout(ack_timeout), .rnr_min(rnr_min), .rnr_max(rnr_max),
    .rnr_nak_timer(rnr_nak_timer), .ackreq_n(ackreq_n), .vlan_tci(vlan_tci), .pause_xoff(pause_xoff),
    .pause_xon(pause_xon), .retry_cnt(retry_cnt), .rnr_retry(rnr_retry), .pace_inc(pace_inc),
    .pace_burst(pace_burst), .link_grace(link_grace),
    .qp_we(qp_we), .qp_idx(qp_idx), .qp_valid(qp_valid), .qp_type(qp_type), .qp_sq_psn(qp_sq_psn),
    .qp_rq_psn(qp_rq_psn), .qp_pmtu(qp_pmtu), .qp_ipv6(qp_ipv6), .qp_dmac(qp_dmac), .qp_dip(qp_dip),
    .qp_dqpn(qp_dqpn), .qp_sport(qp_sport), .qp_dport(qp_dport), .err_we(err_we), .err_qp(err_qp),
    .mr_we(mr_we), .mr_idx(mr_idx), .mr_valid(mr_valid), .mr_acc(mr_acc), .mr_rkey(mr_rkey), .mr_va(mr_va),
    .mr_len(mr_len), .mr_laddr(mr_laddr),
    .st_in_reset(eng_rst), .st_mac_aligned(mac_rx_aligned), .st_link_up(link_s1), .st_timer_hold(timer_hold),
    .st_pause_gate(pause_gate), .st_pause_req(pause_req),
    .st_pause_quanta(pause_quanta), .st_rx_fill(16'(rx_fill)), .st_wr_outstanding(wr_outstanding),
    .st_ring_used(ring_used), .st_vlan_last_tci(vlan_last_tci),
    .st_qp_err_req(qp_err_req), .st_qp_err_resp(qp_err_resp),
    .req_err_valid(req_err_valid), .req_err_qp(req_err_qp), .req_err_code(req_err_code),
    .resp_err_valid(resp_err_valid), .resp_err_qp(resp_err_qp), .resp_err_code(resp_err_code),
    .ev(ev_cnt), .rx_bytes_add(mev.rx_bytes), .tx_bytes_add(mev.tx_bytes), .irq(irq)
);

// ---------------- MAC glue ----------------
wire logic [511:0] erx_tdata, etx_tdata;
wire logic [63:0]  erx_tkeep, etx_tkeep;
wire logic         erx_tvalid, erx_tready, erx_tlast, etx_tvalid, etx_tready, etx_tlast;

rocelet_mac #(
    .IPV6_EN(IPV6_EN), .VLAN_EN(VLAN_EN), .PAUSE_EN(PAUSE_EN), .ARP_EN(ARP_EN), .OTHER_EN(OTHER_EN),
    .RX_FIFO_DEPTH(RX_FIFO_DEPTH), .TX_FIFO_DEPTH(TX_FIFO_DEPTH), .OTHER_TX_FIFO_DEPTH(OTHER_TX_FIFO_DEPTH),
    .CLK_MHZ(CLK_MHZ)
) u_mac (
    .clk(clk), .rst(eng_rst),
    .my_mac(my_mac), .my_ip4(my_ip4), .rx_en(ctl_rx_en), .tx_en(ctl_tx_en),
    .vlan_rx_strip(ctl_vlan_rx_strip), .vlan_tx_tag(ctl_vlan_tx_tag), .vlan_tci(vlan_tci),
    .arp_int(ctl_arp_int), .other_rx_en(ctl_other_rx_en), .pause_rx_en(ctl_pause_rx_en),
    .pause_rx_level(ctl_pause_rx_level), .pause_tx_en(ctl_pause_tx_en), .pause_xoff(pause_xoff),
    .pause_xon(pause_xon),
    .mac_rx_reset(mac_rx_reset), .mac_tx_reset(mac_tx_reset),
    .s_axis_rx_tdata(s_axis_rx_tdata), .s_axis_rx_tkeep(s_axis_rx_tkeep), .s_axis_rx_tvalid(s_axis_rx_tvalid),
    .s_axis_rx_tlast(s_axis_rx_tlast), .s_axis_rx_tuser(s_axis_rx_tuser),
    .m_axis_tx_tdata(m_axis_tx_tdata), .m_axis_tx_tkeep(m_axis_tx_tkeep), .m_axis_tx_tvalid(m_axis_tx_tvalid),
    .m_axis_tx_tready(m_axis_tx_tready), .m_axis_tx_tlast(m_axis_tx_tlast),
    .stat_rx_pause_req(stat_rx_pause_req), .stat_rx_pause_valid(stat_rx_pause_valid),
    .stat_rx_pause_quanta8(stat_rx_pause_quanta8), .ctl_tx_pause_req(ctl_tx_pause_req),
    .m_eng_tdata(erx_tdata), .m_eng_tkeep(erx_tkeep), .m_eng_tvalid(erx_tvalid), .m_eng_tready(erx_tready),
    .m_eng_tlast(erx_tlast),
    .s_eng_tdata(etx_tdata), .s_eng_tkeep(etx_tkeep), .s_eng_tvalid(etx_tvalid), .s_eng_tready(etx_tready),
    .s_eng_tlast(etx_tlast),
    .m_axis_other_tdata(m_axis_other_tdata), .m_axis_other_tkeep(m_axis_other_tkeep),
    .m_axis_other_tvalid(m_axis_other_tvalid), .m_axis_other_tready(m_axis_other_tready),
    .m_axis_other_tlast(m_axis_other_tlast),
    .s_axis_other_tdata(s_axis_other_tdata), .s_axis_other_tkeep(s_axis_other_tkeep),
    .s_axis_other_tvalid(s_axis_other_tvalid), .s_axis_other_tready(s_axis_other_tready),
    .s_axis_other_tlast(s_axis_other_tlast),
    .rx_fill(rx_fill), .pause_gate(pause_gate), .pause_req(pause_req), .pause_quanta(pause_quanta),
    .vlan_last_tci(vlan_last_tci), .ev(mev)
);
assign m_axis_tx_tuser = 1'b0;

// ---------------- engine ----------------
wire logic           wcmd_valid, wcmd_ready, wdat_tvalid, wdat_tready, wdat_tlast;
wire logic [63:0]    wcmd_addr, rcmd_addr, qrd_addr;
wire logic [12:0]    wcmd_len, rcmd_len, qrd_len;
wire logic [511:0]   wdat_tdata, rdat_tdata, qrdd_tdata;
wire logic [63:0]    wdat_tkeep;
wire logic           rcmd_valid, rcmd_ready, rdat_tvalid, rdat_tready;
wire logic           qrd_valid, qrd_ready, qrdd_tvalid, qrdd_tready;
wire logic           wc_valid, rc_valid, rc_send, rc_has_imm;
wire logic [QPW-1:0] wc_qp, rc_qp, send_qp;
wire logic [15:0]    wc_id;
wire logic [7:0]     wc_status;
wire logic [31:0]    rc_imm, rc_len;
wire logic           send_som, send_eom;

rocelet_core #(
    .NUM_QP(NUM_QP), .NUM_MR(NUM_MR), .QPN_BASE(QPN_BASE), .PMTU_RUNTIME(PMTU_RUNTIME), .PMTU_LOG2(PMTU_LOG2),
    .READ_DEPTH(READ_DEPTH), .RTX_MODE(RTX_MODE), .RING_BYTES(RING_BYTES), .RING_RAM(RING_RAM), .MAX_WR(MAX_WR),
    .RX_ICRC_EN(RX_ICRC_EN), .ICRC_SHARE(ICRC_SHARE), .IPV6_EN(IPV6_EN), .HSB_EN(HSB_EN), .CONT_EN(1'b1)
) u_core (
    .clk(clk), .rst(eng_rst),
    .my_mac(my_mac), .my_ip4(my_ip4), .my_ip6(my_ip6), .ip_tos(ip_tos), .ip_ttl(ip_ttl),
    .cfg_tick_div(tick_div), .cfg_timeout(ack_timeout), .cfg_rnr_min(rnr_min), .cfg_rnr_max(rnr_max),
    .cfg_retry_cnt(retry_cnt), .cfg_rnr_retry(rnr_retry), .cfg_rnr_timer(rnr_nak_timer),
    .cfg_ackreq_n(ackreq_n), .cfg_read_cont(ctl_read_cont), .cfg_loss_fatal(ctl_loss_fatal),
    .cfg_pace_inc(pace_inc), .cfg_pace_burst(pace_burst),
    .cfg_link_grace(link_grace), .link_up(link_s1), .stat_timer_hold(timer_hold),
    .cfg_qp_we(qp_we), .cfg_qp(qp_idx), .cfg_qp_valid(qp_valid), .cfg_qp_type(qp_type),
    .cfg_qp_sq_psn(qp_sq_psn), .cfg_qp_rq_psn(qp_rq_psn), .cfg_qp_pmtu(qp_pmtu), .cfg_qp_ipv6(qp_ipv6),
    .cfg_qp_dmac(qp_dmac), .cfg_qp_dip(qp_dip), .cfg_qp_dqpn(qp_dqpn), .cfg_qp_sport(qp_sport),
    .cfg_qp_dport(qp_dport), .cfg_err_we(err_we), .cfg_err_qp(err_qp),
    .cfg_mr_we(mr_we), .cfg_mr_idx(mr_idx), .cfg_mr_valid(mr_valid), .cfg_mr_rkey(mr_rkey), .cfg_mr_va(mr_va),
    .cfg_mr_len(mr_len), .cfg_mr_laddr(mr_laddr), .cfg_mr_acc(mr_acc),
    .s_rx_tdata(erx_tdata), .s_rx_tkeep(erx_tkeep), .s_rx_tvalid(erx_tvalid), .s_rx_tready(erx_tready),
    .s_rx_tlast(erx_tlast),
    .m_tx_tdata(etx_tdata), .m_tx_tkeep(etx_tkeep), .m_tx_tvalid(etx_tvalid), .m_tx_tready(etx_tready),
    .m_tx_tlast(etx_tlast),
    .s_wr_valid(s_axis_wr_tvalid), .s_wr_ready(s_axis_wr_tready), .s_wr_qp(s_axis_wr_tdata[QPW-1:0]),
    .s_wr_class(s_axis_wr_tdata[9:8]), .s_wr_se(s_axis_wr_tdata[12]), .s_wr_md(s_axis_wr_tdata[13]),
    .s_wr_va(s_axis_wr_tdata[127:64]), .s_wr_rkey(s_axis_wr_tdata[159:128]), .s_wr_len(s_axis_wr_tdata[63:32]),
    .s_wr_imm(s_axis_wr_tdata[191:160]), .s_wr_laddr(s_axis_wr_tdata[255:192]), .s_wr_id(s_axis_wr_tdata[31:16]),
    .s_wpay_tdata(s_axis_wr_data_tdata), .s_wpay_tvalid(s_axis_wr_data_tvalid),
    .s_wpay_tready(s_axis_wr_data_tready), .s_wpay_tlast(s_axis_wr_data_tlast),
    .m_wc_valid(wc_valid), .m_wc_ready(m_axis_wc_tready), .m_wc_qp(wc_qp), .m_wc_id(wc_id),
    .m_wc_status(wc_status),
    .m_qrd_valid(qrd_valid), .m_qrd_ready(qrd_ready), .m_qrd_addr(qrd_addr), .m_qrd_len(qrd_len),
    .s_qrd_tdata(qrdd_tdata), .s_qrd_tvalid(qrdd_tvalid), .s_qrd_tready(qrdd_tready),
    .m_wcmd_valid(wcmd_valid), .m_wcmd_ready(wcmd_ready), .m_wcmd_addr(wcmd_addr), .m_wcmd_len(wcmd_len),
    .m_wdat_tdata(wdat_tdata), .m_wdat_tkeep(wdat_tkeep), .m_wdat_tvalid(wdat_tvalid),
    .m_wdat_tready(wdat_tready), .m_wdat_tlast(wdat_tlast),
    .m_rcmd_valid(rcmd_valid), .m_rcmd_ready(rcmd_ready), .m_rcmd_addr(rcmd_addr), .m_rcmd_len(rcmd_len),
    .s_rdat_tdata(rdat_tdata), .s_rdat_tvalid(rdat_tvalid), .s_rdat_tready(rdat_tready),
    .m_send_tdata(m_axis_send_tdata), .m_send_tkeep(m_axis_send_tkeep), .m_send_tvalid(m_axis_send_tvalid),
    .m_send_tready(m_axis_send_tready), .m_send_tlast(m_axis_send_tlast), .m_send_qp(send_qp),
    .m_send_som(send_som), .m_send_eom(send_eom),
    .m_send_end_valid(send_commit_valid), .m_send_end_ok(send_commit_ok), .send_rnr(send_rnr),
    .m_rc_valid(rc_valid), .m_rc_ready(m_axis_rc_tready), .m_rc_qp(rc_qp), .m_rc_send(rc_send),
    .m_rc_has_imm(rc_has_imm), .m_rc_imm(rc_imm), .m_rc_len(rc_len),
    .qp_err_req(qp_err_req), .qp_err_resp(qp_err_resp),
    .m_req_err_valid(req_err_valid), .m_req_err_qp(req_err_qp), .m_req_err_code(req_err_code),
    .m_resp_err_valid(resp_err_valid), .m_resp_err_qp(resp_err_qp), .m_resp_err_code(resp_err_code),
    .stat_wr_outstanding(wr_outstanding), .stat_ring_used(ring_used), .ev(cev)
);

assign m_axis_wc_tdata   = {32'd0, wc_status, 8'(wc_qp), wc_id};
assign m_axis_wc_tvalid  = wc_valid;
assign m_axis_rc_tdata   = {54'd0, rc_has_imm, rc_send, 8'(rc_qp), rc_len, rc_imm};
assign m_axis_rc_tvalid  = rc_valid;
assign m_axis_send_tuser = {6'd0, send_eom, send_som, 8'(send_qp)};

// ---------------- memory ----------------
wire logic ev_axi_wr_err, ev_axi_rd_err;
rocelet_axi_mem #(.ADDR_W(M_AXI_ADDR_W), .ID_W(M_AXI_ID_W), .RD_BUF(MEM_RD_BUF), .RD1_EN(RTX_ID == 1)) u_mem (
    .clk(clk), .rst(eng_rst),
    .s_wcmd_valid(wcmd_valid), .s_wcmd_ready(wcmd_ready), .s_wcmd_addr(wcmd_addr), .s_wcmd_len(wcmd_len),
    .s_wdat_tdata(wdat_tdata), .s_wdat_tkeep(wdat_tkeep), .s_wdat_tvalid(wdat_tvalid), .s_wdat_tready(wdat_tready),
    .s_wdat_tlast(wdat_tlast),
    .s_r0cmd_valid(rcmd_valid), .s_r0cmd_ready(rcmd_ready), .s_r0cmd_addr(rcmd_addr), .s_r0cmd_len(rcmd_len),
    .m_r0dat_tdata(rdat_tdata), .m_r0dat_tvalid(rdat_tvalid), .m_r0dat_tready(rdat_tready),
    .s_r1cmd_valid(qrd_valid), .s_r1cmd_ready(qrd_ready), .s_r1cmd_addr(qrd_addr), .s_r1cmd_len(qrd_len),
    .m_r1dat_tdata(qrdd_tdata), .m_r1dat_tvalid(qrdd_tvalid), .m_r1dat_tready(qrdd_tready),
    .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
    .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock), .m_axi_awcache(m_axi_awcache),
    .m_axi_awprot(m_axi_awprot), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wready(m_axi_wready), .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bready(m_axi_bready),
    .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache),
    .m_axi_arprot(m_axi_arprot), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
    .ev_wr_err(ev_axi_wr_err), .ev_rd_err(ev_axi_rd_err)
);

// ---------------- statistics ----------------
logic pause_rx_r = 1'b0, pause_tx_r = 1'b0, fec_c_r = 1'b0, fec_u_r = 1'b0;
logic wr_fire_r = 1'b0, wc_fire_r = 1'b0, wc_err_r = 1'b0, rc_fire_r = 1'b0;
always_ff @(posedge clk) begin
    pause_rx_r <= stat_rx_pause;
    pause_tx_r <= stat_tx_pause;
    fec_c_r    <= stat_rx_rsfec_corrected_cw_inc;
    fec_u_r    <= stat_rx_rsfec_uncorrected_cw_inc;
    wr_fire_r  <= s_axis_wr_tvalid && s_axis_wr_tready;
    wc_fire_r  <= wc_valid && m_axis_wc_tready;
    wc_err_r   <= wc_valid && m_axis_wc_tready && (wc_status != 8'd0);
    rc_fire_r  <= rc_valid && m_axis_rc_tready;
end
always_comb begin
    ev_cnt = '0;
    ev_cnt[C_RX_FRAMES]     = mev.rx_frame;
    ev_cnt[C_RX_FCS_ERR]    = mev.rx_fcs_err;
    ev_cnt[C_RX_FIFO_DROP]  = mev.rx_fifo_drop;
    ev_cnt[C_RX_ROCE]       = mev.rx_roce;
    ev_cnt[C_RX_ARP]        = mev.rx_arp;
    ev_cnt[C_RX_ICMP]       = mev.rx_icmp;
    ev_cnt[C_RX_OTHER]      = mev.rx_other;
    ev_cnt[C_RX_OTHER_DROP] = mev.rx_other_drop;
    ev_cnt[C_RX_VLAN_STRIP] = mev.rx_vlan_strip;
    ev_cnt[C_RX_VLAN_OTHER] = mev.rx_vlan_other;
    ev_cnt[C_RX_ICRC_BAD]   = cev.rx_icrc_bad;
    ev_cnt[C_RX_PARSE_DROP] = cev.rx_parse_drop;
    ev_cnt[C_RX_CNP]        = cev.rx_cnp;
    ev_cnt[C_RX_ACK]        = cev.rx_ack;
    ev_cnt[C_RX_NAK_SEQ]    = cev.rx_nak_seq;
    ev_cnt[C_RX_RNR_NAK]    = cev.rx_rnr_nak;
    ev_cnt[C_RX_NAK_FATAL]  = cev.rx_nak_fatal;
    ev_cnt[C_RX_REQ]        = cev.rx_req;
    ev_cnt[C_RX_DUP]        = cev.rx_dup;
    ev_cnt[C_RX_OOS]        = cev.rx_oos;
    ev_cnt[C_RX_QP_DROP]    = cev.rx_qp_drop;
    ev_cnt[C_RX_READ]       = cev.rx_read;
    ev_cnt[C_RX_READ_CONT]  = cev.rx_read_cont;
    ev_cnt[C_RX_RNR_SENT]   = cev.rx_rnr_sent;
    ev_cnt[C_RX_CPL]        = rc_fire_r;
    ev_cnt[C_TX_FRAMES]     = mev.tx_frame;
    ev_cnt[C_TX_REQ]        = cev.tx_req;
    ev_cnt[C_TX_ACK]        = cev.tx_ack;
    ev_cnt[C_TX_NAK]        = cev.tx_nak;
    ev_cnt[C_TX_READ_RESP]  = cev.tx_read_resp;
    ev_cnt[C_TX_ARP_ICMP]   = mev.tx_arp_icmp;
    ev_cnt[C_TX_OTHER]      = mev.tx_other;
    ev_cnt[C_TX_UNDERRUN]   = mev.tx_underrun;
    ev_cnt[C_TX_VLAN_TAG]   = mev.tx_vlan_tag;
    ev_cnt[C_REQ_WR]        = wr_fire_r;
    ev_cnt[C_REQ_WC]        = wc_fire_r;
    ev_cnt[C_REQ_WC_ERR]    = wc_err_r;
    ev_cnt[C_REQ_RTX]       = cev.req_rtx;
    ev_cnt[C_REQ_TIMEOUT]   = cev.req_timeout;
    ev_cnt[C_REQ_REX]       = cev.req_rex;
    ev_cnt[C_PAUSE_RX]      = pause_rx_r;
    ev_cnt[C_PAUSE_TX]      = pause_tx_r;
    ev_cnt[C_PAUSE_GATE]    = mev.pause_load;
    ev_cnt[C_PAUSE_XOFF]    = mev.pause_xoff;
    ev_cnt[C_RSFEC_CORR]    = fec_c_r;
    ev_cnt[C_RSFEC_UNCORR]  = fec_u_r;
    ev_cnt[C_AXI_WR_ERR]    = ev_axi_wr_err;
    ev_cnt[C_AXI_RD_ERR]    = ev_axi_rd_err;
    ev_cnt[C_WR_DATA_ERR]   = cev.wr_data_err;
    ev_cnt[C_LINK_DOWN]     = cev.link_down;
end

endmodule

`resetall
