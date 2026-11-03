// SPDX-License-Identifier: MIT
//
// rocelet_core - the rocelet RoCE v2 engine (RC requester + RC responder) with native
// ports: Ethernet frames in and out (512-bit AXI-Stream, after / before the MAC glue),
// configuration and status ports, work requests and completions, and per-packet memory
// command + data ports (DataMover style). rocelet_top wraps it with the MAC glue, the
// AXI-Lite register file and the AXI4 memory master; designs that attach on-chip memory
// directly can instantiate this module instead.
//
//   RX: rocelet_icrc_rx -> rocelet_rx_parser -> rocelet_resp_rx --+--> responder memory / SEND
//                                                                 +--> ACK/NAK -> rocelet_ack_proc
//   TX: rocelet_resp_tx (ACK / NAK / READ responses) --+
//       rocelet_req_ctrl (requester packets) ----------+-> rocelet_tx_arb -> rocelet_tx_builder
//                                                          -> rocelet_icrc_tx
//   requester reliability: rocelet_retx_desc (outstanding-WR ring, completions, go-back-N
//   re-issue), rocelet_ack_proc (window, ACK/NAK, timers), payload from rocelet_retx_ring
//   (RTX_MODE "RING"), from memory (m_qrd, "REREAD") or straight from the WR stream
//   ("LOSSY", lossy resume).
// One clock domain (the CMAC user clock); no CDC, no interconnect, no vendor IP.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_core
    import rocelet_pkg::*;
#(
    parameter int          NUM_QP       = 16,
    parameter int          NUM_MR       = 16,
    parameter logic [23:0] QPN_BASE     = 24'h000100,
    parameter bit          PMTU_RUNTIME = 1'b1,
    parameter int          PMTU_LOG2    = 12,
    parameter int          READ_DEPTH   = 16,
    parameter              RTX_MODE     = "RING",     // "RING" | "REREAD" | "LOSSY"
    parameter int          RING_BYTES   = 262144,
    parameter              RING_RAM     = "ultra",
    parameter int          MAX_WR       = 128,
    parameter bit          RX_ICRC_EN   = 1'b1,
    parameter bit          ICRC_SHARE   = 1'b1,
    parameter bit          IPV6_EN      = 1'b0,
    parameter bit          HSB_EN       = 1'b1,
    parameter bit          CONT_EN      = 1'b1,
    localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1,
    localparam int MRW = (NUM_MR > 1) ? $clog2(NUM_MR) : 1
) (
    input  wire logic             clk,
    input  wire logic             rst,

    // ---------------- global configuration ----------------
    input  wire logic [47:0]      my_mac,
    input  wire logic [31:0]      my_ip4,
    input  wire logic [127:0]     my_ip6,
    input  wire logic [7:0]       ip_tos,
    input  wire logic [7:0]       ip_ttl,
    input  wire logic [9:0]       cfg_tick_div,
    input  wire logic [19:0]      cfg_timeout,
    input  wire logic [19:0]      cfg_rnr_min,
    input  wire logic [19:0]      cfg_rnr_max,
    input  wire logic [2:0]       cfg_retry_cnt,
    input  wire logic [2:0]       cfg_rnr_retry,
    input  wire logic [4:0]       cfg_rnr_timer,
    input  wire logic [7:0]       cfg_ackreq_n,
    input  wire logic             cfg_read_cont,
    input  wire logic             cfg_loss_fatal,
    input  wire logic [19:0]      cfg_pace_inc,       // requester rate limit: credit per clock (1/256 B), 0 = off
    input  wire logic [15:0]      cfg_pace_burst,     // bucket size, bytes
    input  wire logic [23:0]      cfg_link_grace,     // ticks after link_up rises with ACK timeouts held
    input  wire logic             link_up,            // synchronous; 0 = link down (ACK timeouts held)
    output wire logic             stat_timer_hold,    // ACK timeouts held

    // ---------------- QP configuration (one write resets the QP) ----------------
    input  wire logic             cfg_qp_we,
    input  wire logic [QPW-1:0]   cfg_qp,
    input  wire logic             cfg_qp_valid,
    input  wire logic [1:0]       cfg_qp_type,
    input  wire logic [23:0]      cfg_qp_sq_psn,
    input  wire logic [23:0]      cfg_qp_rq_psn,
    input  wire logic [3:0]       cfg_qp_pmtu,
    input  wire logic             cfg_qp_ipv6,
    input  wire logic [47:0]      cfg_qp_dmac,
    input  wire logic [127:0]     cfg_qp_dip,
    input  wire logic [23:0]      cfg_qp_dqpn,
    input  wire logic [15:0]      cfg_qp_sport,
    input  wire logic [15:0]      cfg_qp_dport,
    input  wire logic             cfg_err_we,         // force QP cfg_err_qp into the error state
    input  wire logic [QPW-1:0]   cfg_err_qp,
    input  wire logic             cfg_mr_we,
    input  wire logic [MRW-1:0]   cfg_mr_idx,
    input  wire logic             cfg_mr_valid,
    input  wire logic [31:0]      cfg_mr_rkey,
    input  wire logic [63:0]      cfg_mr_va,
    input  wire logic [31:0]      cfg_mr_len,
    input  wire logic [63:0]      cfg_mr_laddr,
    input  wire logic [1:0]       cfg_mr_acc,

    // ---------------- frames (RoCE only; from / to the MAC glue) ----------------
    input  wire logic [511:0]     s_rx_tdata,
    input  wire logic [63:0]      s_rx_tkeep,
    input  wire logic             s_rx_tvalid,
    output wire logic             s_rx_tready,
    input  wire logic             s_rx_tlast,
    output wire logic [511:0]     m_tx_tdata,
    output wire logic [63:0]      m_tx_tkeep,
    output wire logic             m_tx_tvalid,
    input  wire logic             m_tx_tready,
    output wire logic             m_tx_tlast,

    // ---------------- requester: work requests, payload, completions ----------------
    input  wire logic             s_wr_valid,
    output wire logic             s_wr_ready,
    input  wire logic [QPW-1:0]   s_wr_qp,
    input  wire logic [1:0]       s_wr_class,
    input  wire logic             s_wr_se,
    input  wire logic             s_wr_md,
    input  wire logic [63:0]      s_wr_va,
    input  wire logic [31:0]      s_wr_rkey,
    input  wire logic [31:0]      s_wr_len,
    input  wire logic [31:0]      s_wr_imm,
    input  wire logic [63:0]      s_wr_laddr,
    input  wire logic [15:0]      s_wr_id,
    input  wire logic [511:0]     s_wpay_tdata,
    input  wire logic             s_wpay_tvalid,
    output wire logic             s_wpay_tready,
    input  wire logic             s_wpay_tlast,
    output wire logic             m_wc_valid,
    input  wire logic             m_wc_ready,
    output wire logic [QPW-1:0]   m_wc_qp,
    output wire logic [15:0]      m_wc_id,
    output wire logic [7:0]       m_wc_status,
    // payload reads (RTX_MODE "REREAD")
    output wire logic             m_qrd_valid,
    input  wire logic             m_qrd_ready,
    output wire logic [63:0]      m_qrd_addr,
    output wire logic [12:0]      m_qrd_len,
    input  wire logic [511:0]     s_qrd_tdata,
    input  wire logic             s_qrd_tvalid,
    output wire logic             s_qrd_tready,

    // ---------------- responder: memory, SEND sink, receive completions ----------------
    output wire logic             m_wcmd_valid,
    input  wire logic             m_wcmd_ready,
    output wire logic [63:0]      m_wcmd_addr,
    output wire logic [12:0]      m_wcmd_len,
    output wire logic [511:0]     m_wdat_tdata,
    output wire logic [63:0]      m_wdat_tkeep,
    output wire logic             m_wdat_tvalid,
    input  wire logic             m_wdat_tready,
    output wire logic             m_wdat_tlast,
    output wire logic             m_rcmd_valid,
    input  wire logic             m_rcmd_ready,
    output wire logic [63:0]      m_rcmd_addr,
    output wire logic [12:0]      m_rcmd_len,
    input  wire logic [511:0]     s_rdat_tdata,
    input  wire logic             s_rdat_tvalid,
    output wire logic             s_rdat_tready,
    output wire logic [511:0]     m_send_tdata,
    output wire logic [63:0]      m_send_tkeep,
    output wire logic             m_send_tvalid,
    input  wire logic             m_send_tready,
    output wire logic             m_send_tlast,
    output wire logic [QPW-1:0]   m_send_qp,
    output wire logic             m_send_som,
    output wire logic             m_send_eom,
    output wire logic             m_send_end_valid,
    output wire logic             m_send_end_ok,
    input  wire logic [NUM_QP-1:0] send_rnr,
    output wire logic             m_rc_valid,
    input  wire logic             m_rc_ready,
    output wire logic [QPW-1:0]   m_rc_qp,
    output wire logic             m_rc_send,
    output wire logic             m_rc_has_imm,
    output wire logic [31:0]      m_rc_imm,
    output wire logic [31:0]      m_rc_len,

    // ---------------- status ----------------
    output wire logic [NUM_QP-1:0] qp_err_req,
    output wire logic [NUM_QP-1:0] qp_err_resp,
    output wire logic             m_req_err_valid,
    output wire logic [QPW-1:0]   m_req_err_qp,
    output wire logic [7:0]       m_req_err_code,
    output wire logic             m_resp_err_valid,
    output wire logic [QPW-1:0]   m_resp_err_qp,
    output wire logic [7:0]       m_resp_err_code,
    output wire logic [15:0]      stat_wr_outstanding,
    output wire logic [23:0]      stat_ring_used,
    output core_ev_t              ev
);

localparam bit RING   = (RTX_MODE == "RING");
localparam bit REREAD = (RTX_MODE == "REREAD");
localparam bit LOSSY  = !RING && !REREAD;
localparam bit GBN    = !LOSSY;                   // go-back-N (ack_proc MODE 1)

// registered inputs from outside the engine
logic [NUM_QP-1:0] send_rnr_r = '0;
always_ff @(posedge clk) send_rnr_r <= send_rnr;

// =====================================================================
// RX: ICRC -> parser -> responder / ACK intake
// =====================================================================
wire logic           ack_valid, ack_room;
wire logic [QPW-1:0] ack_qp;
wire logic [23:0]    ack_psn, ack_msn;
wire logic [7:0]     ack_syn;

wire logic           rs_valid, rs_ready, rs_read, rs_cont, rs_dup;
wire logic [QPW-1:0] rs_qp;
wire logic [23:0]    rs_psn, rs_msn;
wire logic [7:0]     rs_syn;
wire logic [63:0]    rs_laddr;
wire logic [31:0]    rs_len;
wire logic [3:0]     rs_pmtu;
wire logic           dn_valid;
wire logic [QPW-1:0] dn_qp;

wire logic [511:0] c_tdata;
wire logic [63:0]  c_tkeep;
wire logic         c_tvalid, c_tready, c_tlast, c_tuser;
wire logic         icrc_v, icrc_ok;
if (RX_ICRC_EN) begin : g_icrc
    rocelet_icrc_rx #(.GRAN(4), .REM(2), .PASS_DATA(1'b1), .IPV6_EN(IPV6_EN), .CRC_SHARE(ICRC_SHARE)) u_icrc_rx (
        .clk(clk), .rst(rst), .l3_off(6'd14),
        .s_axis_tdata(s_rx_tdata), .s_axis_tkeep(s_rx_tkeep), .s_axis_tvalid(s_rx_tvalid),
        .s_axis_tready(s_rx_tready), .s_axis_tlast(s_rx_tlast),
        .m_axis_tdata(c_tdata), .m_axis_tkeep(c_tkeep), .m_axis_tvalid(c_tvalid),
        .m_axis_tready(c_tready), .m_axis_tlast(c_tlast), .m_axis_tuser(c_tuser),
        .m_verdict_valid(icrc_v), .m_verdict_ok(icrc_ok)
    );
end else begin : g_noicrc
    assign c_tdata = s_rx_tdata; assign c_tkeep = s_rx_tkeep; assign c_tvalid = s_rx_tvalid;
    assign s_rx_tready = c_tready; assign c_tlast = s_rx_tlast; assign c_tuser = 1'b0;
    assign icrc_v = 1'b0; assign icrc_ok = 1'b0;
end

wire logic          h_valid, h_ready, h_ackreq, h_mal;
wire logic [7:0]    h_op, h_syn;
wire logic [23:0]   h_dqpn, h_psn, h_msn;
wire logic [63:0]   h_va;
wire logic [31:0]   h_rkey, h_dmalen, h_imm;
wire logic [15:0]   h_pl;
wire logic [511:0]  p_tdata;
wire logic [63:0]   p_tkeep;
wire logic          p_tvalid, p_tready, p_tlast, pe_valid, pe_ok;
wire logic          ev_cnp, ev_pdrop;

rocelet_rx_parser #(.IPV6_EN(IPV6_EN)) u_parse (
    .clk(clk), .rst(rst), .my_ip4(my_ip4), .my_ip6(my_ip6),
    .s_axis_tdata(c_tdata), .s_axis_tkeep(c_tkeep), .s_axis_tvalid(c_tvalid),
    .s_axis_tready(c_tready), .s_axis_tlast(c_tlast), .s_axis_tuser(c_tuser),
    .m_hdr_valid(h_valid), .m_hdr_ready(h_ready), .m_hdr_ipv6(), .m_hdr_sip(),
    .m_hdr_opcode(h_op), .m_hdr_se(), .m_hdr_padcnt(), .m_hdr_dqpn(h_dqpn),
    .m_hdr_ackreq(h_ackreq), .m_hdr_psn(h_psn), .m_hdr_va(h_va), .m_hdr_rkey(h_rkey),
    .m_hdr_dmalen(h_dmalen), .m_hdr_syndrome(h_syn), .m_hdr_msn(h_msn), .m_hdr_imm(h_imm),
    .m_hdr_paylen(h_pl), .m_hdr_malformed(h_mal),
    .m_pay_tdata(p_tdata), .m_pay_tkeep(p_tkeep), .m_pay_tvalid(p_tvalid),
    .m_pay_tready(p_tready), .m_pay_tlast(p_tlast),
    .m_end_valid(pe_valid), .m_end_ok(pe_ok), .ev_cnp(ev_cnp), .ev_drop(ev_pdrop)
);

wire logic rs_ev_req, rs_ev_dup, rs_ev_seq, rs_ev_drop, rs_ev_read, rs_ev_cont, rs_ev_rnr;
rocelet_resp_rx #(
    .NUM_QP(NUM_QP), .NUM_MR(NUM_MR), .PMTU_RUNTIME(PMTU_RUNTIME), .PMTU_LOG2(PMTU_LOG2),
    .QPN_BASE(QPN_BASE), .READ_EN(1'b1), .READ_DEPTH(READ_DEPTH), .CONT_EN(CONT_EN), .SEND_EN(1'b1)
) u_rx (
    .clk(clk), .rst(rst),
    .cfg_read_cont(cfg_read_cont), .cfg_rnr_timer(cfg_rnr_timer), .send_rnr(send_rnr_r),
    .cfg_qp_we(cfg_qp_we), .cfg_qp(cfg_qp), .cfg_qp_valid(cfg_qp_valid),
    .cfg_qp_epsn(cfg_qp_rq_psn), .cfg_qp_pmtu(cfg_qp_pmtu),
    .cfg_err_we(cfg_err_we), .cfg_err_qp(cfg_err_qp),
    .cfg_mr_we(cfg_mr_we), .cfg_mr_idx(cfg_mr_idx), .cfg_mr_valid(cfg_mr_valid),
    .cfg_mr_rkey(cfg_mr_rkey), .cfg_mr_va(cfg_mr_va), .cfg_mr_len(cfg_mr_len),
    .cfg_mr_laddr(cfg_mr_laddr), .cfg_mr_acc(cfg_mr_acc),
    .s_hdr_valid(h_valid), .s_hdr_ready(h_ready), .s_hdr_opcode(h_op), .s_hdr_dqpn(h_dqpn),
    .s_hdr_ackreq(h_ackreq), .s_hdr_psn(h_psn), .s_hdr_va(h_va), .s_hdr_rkey(h_rkey),
    .s_hdr_dmalen(h_dmalen), .s_hdr_syndrome(h_syn), .s_hdr_msn(h_msn), .s_hdr_imm(h_imm),
    .s_hdr_paylen(h_pl), .s_hdr_malformed(h_mal),
    .s_pay_tdata(p_tdata), .s_pay_tkeep(p_tkeep), .s_pay_tvalid(p_tvalid),
    .s_pay_tready(p_tready), .s_pay_tlast(p_tlast), .s_end_valid(pe_valid), .s_end_ok(pe_ok),
    .m_wcmd_valid(m_wcmd_valid), .m_wcmd_ready(m_wcmd_ready), .m_wcmd_addr(m_wcmd_addr),
    .m_wcmd_len(m_wcmd_len), .m_wdat_tdata(m_wdat_tdata), .m_wdat_tkeep(m_wdat_tkeep),
    .m_wdat_tvalid(m_wdat_tvalid), .m_wdat_tready(m_wdat_tready), .m_wdat_tlast(m_wdat_tlast),
    .m_wend_valid(), .m_wend_ok(),
    .m_send_tdata(m_send_tdata), .m_send_tkeep(m_send_tkeep), .m_send_tvalid(m_send_tvalid),
    .m_send_tready(m_send_tready), .m_send_tlast(m_send_tlast), .m_send_qp(m_send_qp),
    .m_send_som(m_send_som), .m_send_eom(m_send_eom),
    .m_send_end_valid(m_send_end_valid), .m_send_end_ok(m_send_end_ok),
    .m_cpl_valid(m_rc_valid), .m_cpl_ready(m_rc_ready), .m_cpl_qp(m_rc_qp),
    .m_cpl_send(m_rc_send), .m_cpl_has_imm(m_rc_has_imm), .m_cpl_imm(m_rc_imm), .m_cpl_len(m_rc_len),
    .m_rsp_valid(rs_valid), .m_rsp_ready(rs_ready), .m_rsp_read(rs_read), .m_rsp_cont(rs_cont),
    .m_rsp_dup(rs_dup),
    .m_rsp_qp(rs_qp), .m_rsp_psn(rs_psn), .m_rsp_syndrome(rs_syn), .m_rsp_msn(rs_msn),
    .m_rsp_laddr(rs_laddr), .m_rsp_len(rs_len), .m_rsp_pmtu(rs_pmtu),
    .s_rddone_valid(dn_valid), .s_rddone_qp(dn_qp),
    .ack_room(ack_room),
    .m_ack_valid(ack_valid), .m_ack_qp(ack_qp), .m_ack_psn(ack_psn),
    .m_ack_syndrome(ack_syn), .m_ack_msn(ack_msn),
    .m_err_valid(m_resp_err_valid), .m_err_qp(m_resp_err_qp), .m_err_syndrome(m_resp_err_code),
    .qp_err(qp_err_resp),
    .ev_req(rs_ev_req), .ev_dup(rs_ev_dup), .ev_seq(rs_ev_seq), .ev_drop(rs_ev_drop),
    .ev_read(rs_ev_read), .ev_read_cont(rs_ev_cont), .ev_rnr(rs_ev_rnr)
);

// =====================================================================
// TX source 0: responses (ACK / NAK / READ responses)
// =====================================================================
wire logic           r0_valid, r0_ready;
tx_desc_t            r0_desc;
wire logic [QPW-1:0] rd_qp;
wire logic [7:0]     rd_op, rd_syn;
wire logic [23:0]    rd_psn, rd_msn;
wire logic [12:0]    rd_len;
rocelet_resp_tx #(
    .NUM_QP(NUM_QP), .RSP_DEPTH((NUM_QP * READ_DEPTH < 4) ? 4 : NUM_QP * READ_DEPTH),
    .READ_EN(1'b1), .RAM_STYLE((NUM_QP * READ_DEPTH > 64) ? "block" : "distributed")
) u_rtx (
    .clk(clk), .rst(rst),
    .s_rsp_valid(rs_valid), .s_rsp_ready(rs_ready), .s_rsp_read(rs_read), .s_rsp_cont(rs_cont),
    .s_rsp_dup(rs_dup),
    .s_rsp_qp(rs_qp), .s_rsp_psn(rs_psn), .s_rsp_syndrome(rs_syn), .s_rsp_msn(rs_msn),
    .s_rsp_laddr(rs_laddr), .s_rsp_len(rs_len), .s_rsp_pmtu(rs_pmtu),
    .m_desc_valid(r0_valid), .m_desc_ready(r0_ready), .m_desc_qp(rd_qp), .m_desc_opcode(rd_op),
    .m_desc_psn(rd_psn), .m_desc_syndrome(rd_syn), .m_desc_msn(rd_msn), .m_desc_len(rd_len),
    .m_rd_valid(m_rcmd_valid), .m_rd_ready(m_rcmd_ready), .m_rd_addr(m_rcmd_addr),
    .m_rd_len(m_rcmd_len), .m_rddone_valid(dn_valid), .m_rddone_qp(dn_qp)
);
always_comb begin
    r0_desc          = '0;
    r0_desc.qp       = 8'(rd_qp);
    r0_desc.opcode   = rd_op;
    r0_desc.psn      = rd_psn;
    r0_desc.syndrome = rd_syn;
    r0_desc.msn      = rd_msn;
    r0_desc.len      = rd_len;
end

// =====================================================================
// TX source 1: requester
// =====================================================================
wire logic           r1_valid, r1_ready, sent_room;
tx_desc_t            r1_desc;
wire logic [511:0]   r1_pay_tdata;
wire logic           r1_pay_tvalid, r1_pay_tready;
wire logic           r1_gen;

// WR source: the user directly, or through the on-chip ring
wire logic           w_valid, w_ready;
wire logic [QPW-1:0] w_qp;
wire logic [1:0]     w_class, w_flags;
wire logic [63:0]    w_va, w_laddr;
wire logic [31:0]    w_rkey, w_len, w_imm;
wire logic [15:0]    w_id;
wire logic           q_rd_valid, q_rd_ready;
wire logic [63:0]    q_rd_addr;
wire logic [12:0]    q_rd_len;
wire logic           wc_fire = m_wc_valid && m_wc_ready;
wire logic           ring_tlast_err;

if (RING) begin : g_ring
    localparam int RW = $clog2(RING_BYTES / 64);
    wire logic [RW:0] used;
    rocelet_retx_ring #(.BYTES(RING_BYTES), .RAM_STYLE(RING_RAM), .RD_LAT(4), .NUM_QP(NUM_QP),
                        .MAX_WR(MAX_WR)) u_ring (
        .clk(clk), .rst(rst),
        .s_wr_valid(s_wr_valid), .s_wr_ready(s_wr_ready), .s_wr_qp(s_wr_qp), .s_wr_class(s_wr_class),
        .s_wr_va(s_wr_va), .s_wr_rkey(s_wr_rkey), .s_wr_len(s_wr_len), .s_wr_imm(s_wr_imm),
        .s_wr_id(s_wr_id), .s_wr_flags({s_wr_md, s_wr_se}),
        .s_pay_tdata(s_wpay_tdata), .s_pay_tvalid(s_wpay_tvalid), .s_pay_tready(s_wpay_tready),
        .s_pay_tlast(s_wpay_tlast),
        .m_wr_valid(w_valid), .m_wr_ready(w_ready), .m_wr_qp(w_qp), .m_wr_class(w_class),
        .m_wr_va(w_va), .m_wr_rkey(w_rkey), .m_wr_len(w_len), .m_wr_imm(w_imm), .m_wr_id(w_id),
        .m_wr_flags(w_flags), .m_wr_laddr(w_laddr),
        .s_rcmd_valid(q_rd_valid), .s_rcmd_ready(q_rd_ready), .s_rcmd_addr(q_rd_addr),
        .s_rcmd_len(q_rd_len), .m_rdat_tdata(r1_pay_tdata), .m_rdat_tvalid(r1_pay_tvalid),
        .m_rdat_tready(r1_pay_tready), .s_cpl_valid(wc_fire), .stat_used_beats(used),
        .ev_tlast_err(ring_tlast_err)
    );
    assign stat_ring_used = 24'(used);
    assign m_qrd_valid = 1'b0; assign m_qrd_addr = '0; assign m_qrd_len = '0; assign s_qrd_tready = 1'b0;
end else begin : g_direct
    assign w_valid = s_wr_valid; assign s_wr_ready = w_ready; assign w_qp = s_wr_qp;
    assign w_class = s_wr_class; assign w_va = s_wr_va; assign w_rkey = s_wr_rkey;
    assign w_len = s_wr_len; assign w_imm = s_wr_imm; assign w_id = s_wr_id; assign w_laddr = s_wr_laddr;
    assign w_flags = {s_wr_md, s_wr_se};
    assign stat_ring_used = '0;
    assign ring_tlast_err = 1'b0;
    if (REREAD) begin : g_mm
        assign m_qrd_valid = q_rd_valid; assign q_rd_ready = m_qrd_ready;
        assign m_qrd_addr = q_rd_addr; assign m_qrd_len = q_rd_len;
        assign r1_pay_tdata = s_qrd_tdata; assign r1_pay_tvalid = s_qrd_tvalid;
        assign s_qrd_tready = r1_pay_tready; assign s_wpay_tready = 1'b0;
    end else begin : g_stream
        assign q_rd_ready = 1'b1;
        assign m_qrd_valid = 1'b0; assign m_qrd_addr = '0; assign m_qrd_len = '0; assign s_qrd_tready = 1'b0;
        assign r1_pay_tdata = s_wpay_tdata; assign r1_pay_tvalid = s_wpay_tvalid;
        assign s_wpay_tready = r1_pay_tready;
    end
end

// requester engine
wire logic           t_valid, t_ready;
wire logic [QPW-1:0] t_qp;
wire logic [15:0]    t_id;
wire logic [23:0]    t_first, t_last;
wire logic [1:0]     t_class;
wire logic           t_se;
wire logic [63:0]    t_va, t_laddr;
wire logic [31:0]    t_rkey, t_len, t_imm;
wire logic           x_valid, x_ready, x_probe;
wire logic [QPW-1:0] x_qp;
wire logic [23:0]    x_psn;
wire logic           e_valid, e_ready;
wire logic [QPW-1:0] e_qp;
wire logic [1:0]     e_class;
wire logic           e_se;
wire logic [63:0]    e_va, e_laddr;
wire logic [31:0]    e_rkey, e_len, e_imm;
wire logic [15:0]    e_id;
wire logic [23:0]    e_first, e_start;
wire logic           busy, rtx_ready_desc, w_rdy;
assign w_ready = w_rdy && !busy;          // hold new WRs while a go-back-N re-issue scan runs

rocelet_req_ctrl #(
    .NUM_QP(NUM_QP), .PMTU_RUNTIME(PMTU_RUNTIME), .PMTU_LOG2(PMTU_LOG2), .HSB_EN(HSB_EN),
    .SRC_MM(!LOSSY), .REXMIT_EN(GBN), .LOSSY_EN(LOSSY)
) u_req (
    .clk(clk), .rst(rst), .cfg_ackreq_n(cfg_ackreq_n), .qp_err(qp_err_req),
    .cfg_we(cfg_qp_we), .cfg_qp(cfg_qp), .cfg_psn(cfg_qp_sq_psn), .cfg_pmtu_log2(cfg_qp_pmtu),
    .cfg_type(cfg_qp_type),
    .s_wr_valid(w_valid && !busy), .s_wr_ready(w_rdy), .s_wr_qp(w_qp), .s_wr_class(w_class),
    .s_wr_se(w_flags[0]), .s_wr_md(w_flags[1]),
    .s_wr_va(w_va), .s_wr_rkey(w_rkey), .s_wr_len(w_len), .s_wr_imm(w_imm),
    .s_wr_laddr(w_laddr), .s_wr_id(w_id),
    .s_rex_valid(e_valid), .s_rex_ready(e_ready), .s_rex_qp(e_qp), .s_rex_class(e_class), .s_rex_se(e_se),
    .s_rex_va(e_va), .s_rex_rkey(e_rkey), .s_rex_len(e_len), .s_rex_imm(e_imm),
    .s_rex_laddr(e_laddr), .s_rex_id(e_id), .s_rex_first_psn(e_first), .s_rex_start_psn(e_start),
    .s_ctl_valid(LOSSY && x_valid && (x_probe || rtx_ready_desc)), .s_ctl_ready(x_ready), .s_ctl_qp(x_qp),
    .s_ctl_psn(x_psn), .s_ctl_probe(x_probe),
    .m_desc_valid(r1_valid), .m_desc_ready(r1_ready), .m_desc(r1_desc), .m_desc_gen(r1_gen),
    .m_rd_valid(q_rd_valid), .m_rd_ready(q_rd_ready), .m_rd_addr(q_rd_addr), .m_rd_len(q_rd_len),
    .m_trk_valid(t_valid), .m_trk_ready(t_ready), .m_trk_qp(t_qp), .m_trk_id(t_id),
    .m_trk_first_psn(t_first), .m_trk_last_psn(t_last), .m_trk_class(t_class), .m_trk_se(t_se),
    .m_trk_va(t_va), .m_trk_rkey(t_rkey), .m_trk_len(t_len), .m_trk_imm(t_imm), .m_trk_laddr(t_laddr)
);

// ACK processing and the outstanding-WR ring
wire logic           rel_v;
wire logic [QPW-1:0] rel_qp;
wire logic [23:0]    rel_una;
wire logic           xr_ready;
wire logic           r1_fire = r1_valid && r1_ready;
wire logic           ap_ev_rtx, ap_ev_to, ap_ev_ld;

rocelet_ack_proc #(.NUM_QP(NUM_QP), .MODE(GBN)) u_ack (
    .clk(clk), .rst(rst),
    .cfg_tick_div(cfg_tick_div), .cfg_timeout(cfg_timeout), .cfg_rnr_min(cfg_rnr_min),
    .cfg_rnr_max(cfg_rnr_max), .cfg_retry_cnt(cfg_retry_cnt), .cfg_rnr_retry(cfg_rnr_retry),
    .cfg_loss_fatal(cfg_loss_fatal), .cfg_link_grace(cfg_link_grace), .link_up(link_up),
    .cfg_qp_we(cfg_qp_we), .cfg_qp(cfg_qp), .cfg_psn(cfg_qp_sq_psn), .cfg_qp_uc(cfg_qp_type != QPT_RC),
    .cfg_qp_valid(cfg_qp_valid), .cfg_err_we(cfg_err_we), .cfg_err_qp(cfg_err_qp),
    .s_sent_valid(r1_fire && !r1_desc.drop), .s_sent_room(sent_room), .s_sent_qp(r1_desc.qp[QPW-1:0]),
    .s_sent_psn(r1_desc.psn), .s_sent_gen(r1_gen),
    .s_ack_valid(ack_valid), .s_ack_room(ack_room), .s_ack_qp(ack_qp), .s_ack_psn(ack_psn),
    .s_ack_syndrome(ack_syn),
    .m_rel_valid(rel_v), .m_rel_qp(rel_qp), .m_rel_una(rel_una),
    .m_rtx_valid(x_valid), .m_rtx_ready(xr_ready), .m_rtx_qp(x_qp), .m_rtx_psn(x_psn),
    .m_rtx_probe(x_probe),
    .m_err_valid(m_req_err_valid), .m_err_qp(m_req_err_qp), .m_err_code(m_req_err_code),
    .qp_err(qp_err_req), .ev_rtx(ap_ev_rtx), .ev_timeout(ap_ev_to), .ev_link_down(ap_ev_ld),
    .st_hold(stat_timer_hold)
);

// go-back-N: the ring re-issues; lossy: rocelet_req_ctrl rewinds / probes and the ring
// marks the lost WRs (both must take the request)
assign xr_ready = GBN ? rtx_ready_desc : (x_ready && (x_probe || rtx_ready_desc));

wire logic [$clog2(MAX_WR):0] wr_used;
rocelet_retx_desc #(.NUM_QP(NUM_QP), .DEPTH(MAX_WR), .REGEN(GBN)) u_desc (
    .clk(clk), .rst(rst),
    .cfg_qp_we(cfg_qp_we), .cfg_qp(cfg_qp), .cfg_psn(cfg_qp_sq_psn), .qp_err(qp_err_req),
    .s_trk_valid(t_valid), .s_trk_ready(t_ready), .s_trk_qp(t_qp), .s_trk_id(t_id),
    .s_trk_first_psn(t_first), .s_trk_last_psn(t_last), .s_trk_class(t_class), .s_trk_se(t_se),
    .s_trk_va(t_va), .s_trk_rkey(t_rkey), .s_trk_len(t_len), .s_trk_imm(t_imm), .s_trk_laddr(t_laddr),
    .s_rel_valid(rel_v), .s_rel_qp(rel_qp), .s_rel_una(rel_una),
    .s_rtx_valid(x_valid && (GBN || (!x_probe && x_ready))), .s_rtx_ready(rtx_ready_desc),
    .s_rtx_qp(x_qp), .s_rtx_psn(x_psn),
    .m_rex_valid(e_valid), .m_rex_ready(e_ready), .m_rex_qp(e_qp), .m_rex_class(e_class), .m_rex_se(e_se),
    .m_rex_va(e_va), .m_rex_rkey(e_rkey), .m_rex_len(e_len), .m_rex_imm(e_imm),
    .m_rex_laddr(e_laddr), .m_rex_id(e_id), .m_rex_first_psn(e_first), .m_rex_start_psn(e_start),
    .m_busy(busy),
    .m_cpl_valid(m_wc_valid), .m_cpl_ready(m_wc_ready), .m_cpl_qp(m_wc_qp), .m_cpl_id(m_wc_id),
    .m_cpl_status(m_wc_status), .stat_used(wr_used)
);
assign stat_wr_outstanding = 16'(wr_used);

// =====================================================================
// TX: arbiter -> builder -> ICRC
// =====================================================================
wire logic        b_valid, b_ready;
tx_desc_t         b_desc;
wire logic [511:0] b_pay_tdata;
wire logic        b_pay_tvalid, b_pay_tready;
wire logic        a1_ready;

// requester rate limit: a token bucket in 1/256 byte; each packet costs its wire bytes
// (payload + 98: headers, ICRC, FCS, preamble and gap); a packet may start while the
// bucket is not negative (one packet of overdraft). For timing, the configuration is
// registered and a packet's cost is debited one clock after its descriptor is accepted
// (no descriptor is accepted in that clock).
logic signed [27:0] tokens = '0;
logic signed [27:0] p_cap = '0, p_cost = '0;
logic [19:0]        p_inc = '0;
logic               p_on = 1'b0, p_deb = 1'b0;
wire  logic         pace_ok = !p_on || (!tokens[27] && !p_deb);
always_ff @(posedge clk) begin
    logic signed [27:0] t;
    p_on   <= (cfg_pace_inc != 20'd0);
    p_inc  <= cfg_pace_inc;
    p_cap  <= $signed({4'd0, cfg_pace_burst, 8'd0});
    p_deb  <= r1_valid && r1_ready && !r1_desc.drop;
    p_cost <= (r1_valid && r1_ready && !r1_desc.drop) ? $signed({7'd0, r1_desc.len + 13'd98, 8'd0}) : '0;
    t = tokens + $signed({8'd0, p_inc}) - p_cost;
    tokens <= (!p_on || t > p_cap) ? p_cap : t;
    if (rst) begin
        tokens <= '0;
        p_deb  <= 1'b0;
        p_cost <= '0;
    end
end

// requester descriptors wait while the ACK processor's "sent" queue is nearly full, and
// while the rate limit says so
assign r1_ready = a1_ready && sent_room && pace_ok;

rocelet_tx_arb u_arb (
    .clk(clk), .rst(rst),
    .s0_desc_valid(r0_valid), .s0_desc_ready(r0_ready), .s0_desc(r0_desc),
    .s0_pay_tdata(s_rdat_tdata), .s0_pay_tvalid(s_rdat_tvalid), .s0_pay_tready(s_rdat_tready),
    .s1_desc_valid(r1_valid && sent_room && pace_ok), .s1_desc_ready(a1_ready), .s1_desc(r1_desc),
    .s1_pay_tdata(r1_pay_tdata), .s1_pay_tvalid(r1_pay_tvalid), .s1_pay_tready(r1_pay_tready),
    .m_desc_valid(b_valid), .m_desc_ready(b_ready), .m_desc(b_desc),
    .m_pay_tdata(b_pay_tdata), .m_pay_tvalid(b_pay_tvalid), .m_pay_tready(b_pay_tready)
);

wire logic [511:0] f_tdata;
wire logic [63:0]  f_tkeep;
wire logic         f_tvalid, f_tready, f_tlast;

rocelet_tx_builder #(.NUM_QP(NUM_QP), .IPV6_EN(IPV6_EN), .OPSET(2)) u_bld (
    .clk(clk), .rst(rst),
    .cfg_we(cfg_qp_we), .cfg_qp(cfg_qp), .cfg_ipv6(cfg_qp_ipv6), .cfg_dmac(cfg_qp_dmac),
    .cfg_dip(cfg_qp_dip), .cfg_dqpn(cfg_qp_dqpn), .cfg_sport(cfg_qp_sport), .cfg_dport(cfg_qp_dport),
    .my_mac(my_mac), .my_ip4(my_ip4), .my_ip6(my_ip6), .ip_tos(ip_tos), .ip_ttl(ip_ttl),
    .s_desc_valid(b_valid), .s_desc_ready(b_ready), .s_desc(b_desc),
    .s_pay_tdata(b_pay_tdata), .s_pay_tvalid(b_pay_tvalid), .s_pay_tready(b_pay_tready),
    .m_axis_tdata(f_tdata), .m_axis_tkeep(f_tkeep), .m_axis_tvalid(f_tvalid),
    .m_axis_tready(f_tready), .m_axis_tlast(f_tlast)
);

rocelet_icrc_tx #(.GRAN(4), .REM(2), .IPV6_EN(IPV6_EN), .CRC_SHARE(ICRC_SHARE)) u_icrc_tx (
    .clk(clk), .rst(rst), .l3_off(6'd14),
    .s_axis_tdata(f_tdata), .s_axis_tkeep(f_tkeep), .s_axis_tvalid(f_tvalid),
    .s_axis_tready(f_tready), .s_axis_tlast(f_tlast),
    .m_axis_tdata(m_tx_tdata), .m_axis_tkeep(m_tx_tkeep), .m_axis_tvalid(m_tx_tvalid),
    .m_axis_tready(m_tx_tready), .m_axis_tlast(m_tx_tlast)
);

// =====================================================================
// events
// =====================================================================
wire logic b_fire = b_valid && b_ready;
always_ff @(posedge clk) begin
    ev.rx_icrc_bad   <= icrc_v && !icrc_ok;
    ev.rx_parse_drop <= ev_pdrop;
    ev.rx_cnp        <= ev_cnp;
    ev.rx_ack        <= ack_valid && (ack_syn[7:5] == 3'b000);
    ev.rx_nak_seq    <= ack_valid && (ack_syn == SYN_NAK_PSN_SEQ);
    ev.rx_rnr_nak    <= ack_valid && (ack_syn[7:5] == 3'b001);
    ev.rx_nak_fatal  <= ack_valid && (ack_syn[7:5] == 3'b011) && (ack_syn != SYN_NAK_PSN_SEQ);
    ev.rx_req        <= rs_ev_req;
    ev.rx_dup        <= rs_ev_dup;
    ev.rx_oos        <= rs_ev_seq;
    ev.rx_qp_drop    <= rs_ev_drop;
    ev.rx_read       <= rs_ev_read;
    ev.rx_read_cont  <= rs_ev_cont;
    ev.rx_rnr_sent   <= rs_ev_rnr;
    ev.tx_req        <= b_fire && (b_desc.opcode[4:0] <= 5'h0B) && (b_desc.opcode[7:6] == 2'b00);
    ev.tx_ack        <= b_fire && (b_desc.opcode == OP_ACK) && (b_desc.syndrome[7:5] == 3'b000);
    ev.tx_nak        <= b_fire && (b_desc.opcode == OP_ACK) && (b_desc.syndrome[7:5] != 3'b000);
    ev.tx_read_resp  <= b_fire && (b_desc.opcode >= OP_READ_RESP_FIRST) && (b_desc.opcode <= OP_READ_RESP_ONLY);
    ev.req_rtx       <= ap_ev_rtx;
    ev.req_timeout   <= ap_ev_to;
    ev.link_down     <= ap_ev_ld;
    ev.req_rex       <= e_valid && e_ready;
    ev.wr_data_err   <= ring_tlast_err;
end

endmodule

`resetall
