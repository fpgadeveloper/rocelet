// SPDX-License-Identifier: MIT
//
// rocelet_resp_tx - responder transmit engine: ACK / NAK packets and RDMA READ
// responses, in the order rocelet_resp_rx committed the requests (one queue for
// both, so the ACK of a WRITE never overtakes an earlier READ's response:
// IBTA C9-27 / C9-101).
//
// Queue depth RSP_DEPTH = NUM_QP x READ_DEPTH covers every outstanding READ
// (the "READ resources"; ~170 bits each). A READ job is split into READ
// RESPONSE FIRST / MIDDLE / LAST / ONLY packets of PMTU bytes with consecutive
// PSNs from the request PSN; FIRST / LAST / ONLY carry an AETH (ACK, MSN). Each
// response packet with payload issues one MM2S read command (local address,
// length) whose data the TX arbiter feeds to rocelet_tx_builder behind the
// descriptor. m_rddone tells rocelet_resp_rx that a READ resource is free again (the
// last packet of a new READ's response was handed on; a job marked `dup`, a re-executed
// duplicate READ, holds no READ resource and gives no m_rddone).
// A job marked `cont` (a partial duplicate READ answered as a continuation of the
// original response, rocelet_resp_rx) starts with READ RESPONSE MIDDLE instead of
// FIRST, or LAST instead of ONLY.
// Local addresses are 64-byte aligned (checked on receive), so no byte
// realignment of the read data is needed.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_resp_tx
    import rocelet_pkg::*;
#(
    parameter int NUM_QP       = 8,
    parameter int RSP_DEPTH    = 32,
    parameter bit READ_EN      = 1'b1,
    parameter     RAM_STYLE    = "distributed",
    localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1
) (
    input  wire logic             clk,
    input  wire logic             rst,

    input  wire logic             s_rsp_valid,
    output wire logic             s_rsp_ready,
    input  wire logic             s_rsp_read,
    input  wire logic             s_rsp_cont,
    input  wire logic             s_rsp_dup,
    input  wire logic [QPW-1:0]   s_rsp_qp,
    input  wire logic [23:0]      s_rsp_psn,
    input  wire logic [7:0]       s_rsp_syndrome,
    input  wire logic [23:0]      s_rsp_msn,
    input  wire logic [63:0]      s_rsp_laddr,
    input  wire logic [31:0]      s_rsp_len,
    input  wire logic [3:0]       s_rsp_pmtu,

    output wire logic             m_desc_valid,
    input  wire logic             m_desc_ready,
    output wire logic [QPW-1:0]   m_desc_qp,
    output wire logic [7:0]       m_desc_opcode,
    output wire logic [23:0]      m_desc_psn,
    output wire logic [7:0]       m_desc_syndrome,
    output wire logic [23:0]      m_desc_msn,
    output wire logic [12:0]      m_desc_len,

    output wire logic             m_rd_valid,
    input  wire logic             m_rd_ready,
    output wire logic [63:0]      m_rd_addr,
    output wire logic [12:0]      m_rd_len,

    output wire logic             m_rddone_valid,
    output wire logic [QPW-1:0]   m_rddone_qp
);

localparam int QW = 1 + QPW + 24 + 8 + 24 + (READ_EN ? (2 + 64 + 32 + 4) : 0);

wire logic [QW-1:0] q_din = READ_EN ?
    {s_rsp_read, s_rsp_qp, s_rsp_psn, s_rsp_syndrome, s_rsp_msn, s_rsp_dup, s_rsp_cont, s_rsp_laddr, s_rsp_len,
     s_rsp_pmtu} :
    {1'b0, s_rsp_qp, s_rsp_psn, s_rsp_syndrome, s_rsp_msn};
wire logic [QW-1:0] q_dout;
wire logic          q_full, q_valid;
logic               q_pop;
rocelet_fifo #(.WIDTH(QW), .DEPTH(RSP_DEPTH), .RAM_STYLE(RAM_STYLE)) u_q (
    .clk(clk), .rst(rst), .din(q_din), .wr_en(s_rsp_valid && !q_full), .full(q_full),
    .dout(q_dout), .valid(q_valid), .rd_en(q_pop), .count()
);
assign s_rsp_ready = !q_full;

// head register: the queue's LUTRAM read is not in the segmentation path
logic           hv = 1'b0;
logic           h_read;
logic           h_cont;
logic           h_dup;
logic [QPW-1:0] h_qp;
logic [23:0]    h_psn, h_msn;
logic [7:0]     h_syn;
logic [63:0]    h_laddr;
logic [31:0]    h_len;
logic [3:0]     h_pmtu;
logic           h_done;        // the head entry is finished this clock

assign q_pop = q_valid && (!hv || h_done);

always_ff @(posedge clk) begin
    if (q_pop) begin
        hv     <= 1'b1;
        h_read <= READ_EN ? q_dout[QW-1] : 1'b0;
        h_qp   <= q_dout[QW-2 -: QPW];
        h_psn  <= q_dout[QW-2-QPW -: 24];
        h_syn  <= q_dout[QW-26-QPW -: 8];
        h_msn  <= q_dout[QW-34-QPW -: 24];
        if (READ_EN) begin
            h_cont  <= q_dout[100];
            h_dup   <= q_dout[101];
            h_laddr <= q_dout[99:36];
            h_len   <= q_dout[35:4];
            h_pmtu  <= q_dout[3:0];
        end
    end else if (h_done) begin
        hv <= 1'b0;
    end
    if (rst) hv <= 1'b0;
end

// READ segmentation state
logic        r_act = 1'b0;
logic [31:0] r_rem;
logic [63:0] r_addr;
logic [23:0] r_psn;
logic        r_first;

wire logic [13:0] pm_b    = 14'd1 << h_pmtu;
wire logic [31:0] rem     = r_act ? r_rem : h_len;
// one carry chain: rem - PMTU decides "last" and gives the next residue
wire logic [32:0] after   = {1'b0, rem} - {19'd0, pm_b};
wire logic        last_pk = after[32] || (after[31:0] == 32'd0);
wire logic [12:0] pk_len  = last_pk ? rem[12:0] : pm_b[12:0];
wire logic        first   = r_act ? r_first : 1'b1;

logic           d_v = 1'b0, c_v = 1'b0, dn_v = 1'b0;
logic [QPW-1:0] o_qp;
logic [7:0]     o_op, o_syn;
logic [23:0]    o_psn, o_msn;
logic [12:0]    o_len;
logic [63:0]    o_addr;

wire logic slot = (!d_v || m_desc_ready) && (!c_v || m_rd_ready);
wire logic go   = hv && slot;
assign h_done   = go && (!h_read || last_pk);

always_ff @(posedge clk) begin
    if (m_desc_ready) d_v <= 1'b0;
    if (m_rd_ready) c_v <= 1'b0;
    dn_v <= 1'b0;
    if (go) begin
        d_v   <= 1'b1;
        o_qp  <= h_qp;
        o_syn <= h_syn;
        o_msn <= h_msn;
        if (!h_read) begin
            o_op  <= OP_ACK;
            o_psn <= h_psn;
            o_len <= '0;
        end else begin
            // a continuation never starts with FIRST / ONLY
            o_op   <= (first && !h_cont && last_pk) ? OP_READ_RESP_ONLY :
                      (first && !h_cont)            ? OP_READ_RESP_FIRST :
                      last_pk ? OP_READ_RESP_LAST : OP_READ_RESP_MIDDLE;
            o_psn  <= r_act ? r_psn : h_psn;
            o_len  <= pk_len;
            o_addr <= r_act ? r_addr : h_laddr;
            c_v    <= (pk_len != 0);
            r_act  <= !last_pk;
            r_first <= 1'b0;
            r_rem  <= after[31:0];
            r_addr <= (r_act ? r_addr : h_laddr) + {51'd0, pk_len};
            r_psn  <= (r_act ? r_psn : h_psn) + 24'd1;
            if (last_pk) dn_v <= !h_dup;              // a duplicate frees no READ resource
        end
    end
    if (rst) begin
        d_v   <= 1'b0;
        c_v   <= 1'b0;
        r_act <= 1'b0;
        dn_v  <= 1'b0;
    end
end

assign m_desc_valid    = d_v;
assign m_desc_qp       = o_qp;
assign m_desc_opcode   = o_op;
assign m_desc_psn      = o_psn;
assign m_desc_syndrome = o_syn;
assign m_desc_msn      = o_msn;
assign m_desc_len      = o_len;

assign m_rd_valid = c_v;
assign m_rd_addr  = o_addr;
assign m_rd_len   = o_len;

assign m_rddone_valid = dn_v;
assign m_rddone_qp    = o_qp;

endmodule

`resetall
