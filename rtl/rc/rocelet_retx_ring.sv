// SPDX-License-Identifier: MIT
//
// rocelet_retx_ring - on-chip payload ring = the retransmission buffer for streaming
// data sources (sensor / ADC streams that cannot be read twice).
//
// The user writes a WR (descriptor + payload stream, tlast at the WR's end);
// the payload is stored at the ring's write pointer (64-byte beats, every WR
// starts on a beat) and, once complete, the WR is forwarded to the requester
// with laddr = its byte offset in the ring. The requester reads payload per
// packet through the MM2S-style port (s_rcmd / m_rdat), both for the first
// transmission and for go-back-N retransmissions (rocelet_retx_desc re-issue), so
// the ring stores payload only, no headers. A WR's space is freed when its
// completion (rocelet_retx_desc m_cpl: acknowledged, sent on UC, or flushed) arrives;
// the ring back-pressures the user when full. The payload's tlast must be on the
// WR's last beat (ceil(length / 64) beats); a mismatch is reported on ev_tlast_err
// (the beat count from the length is used either way). Capacity = BYTES (power of two); the bandwidth-delay
// product it covers is BYTES / line rate (256 KB = 21 us at 100 Gb/s).
// RAM_STYLE "ultra": 8 URAM per 256 KB (512 data bits = 8 x 64 of the 72-bit
// URAM width), "block": 512 bits = 14.5 RAMB36 per 1K beats (64 KB).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_retx_ring #(
    parameter int BYTES     = 262144,
    parameter     RAM_STYLE = "ultra",
    parameter int RD_LAT    = 4,          // >= 2
    parameter int NUM_QP    = 8,
    parameter int MAX_WR    = 64,
    localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1
) (
    input  wire logic             clk,
    input  wire logic             rst,

    input  wire logic             s_wr_valid,
    output wire logic             s_wr_ready,
    input  wire logic [QPW-1:0]   s_wr_qp,
    input  wire logic [1:0]       s_wr_class,
    input  wire logic [63:0]      s_wr_va,
    input  wire logic [31:0]      s_wr_rkey,
    input  wire logic [31:0]      s_wr_len,
    input  wire logic [31:0]      s_wr_imm,
    input  wire logic [15:0]      s_wr_id,
    input  wire logic [1:0]       s_wr_flags,      // passed through: {md, se}
    input  wire logic [511:0]     s_pay_tdata,
    input  wire logic             s_pay_tvalid,
    output wire logic             s_pay_tready,
    input  wire logic             s_pay_tlast,

    output wire logic             m_wr_valid,
    input  wire logic             m_wr_ready,
    output wire logic [QPW-1:0]   m_wr_qp,
    output wire logic [1:0]       m_wr_class,
    output wire logic [63:0]      m_wr_va,
    output wire logic [31:0]      m_wr_rkey,
    output wire logic [31:0]      m_wr_len,
    output wire logic [31:0]      m_wr_imm,
    output wire logic [15:0]      m_wr_id,
    output wire logic [1:0]       m_wr_flags,
    output wire logic [63:0]      m_wr_laddr,

    input  wire logic             s_rcmd_valid,
    output wire logic             s_rcmd_ready,
    input  wire logic [63:0]      s_rcmd_addr,
    input  wire logic [12:0]      s_rcmd_len,
    output wire logic [511:0]     m_rdat_tdata,
    output wire logic             m_rdat_tvalid,
    input  wire logic             m_rdat_tready,

    input  wire logic             s_cpl_valid,

    output wire logic [$clog2(BYTES/64):0] stat_used_beats,
    output logic                  ev_tlast_err
);

localparam int DEPTH = BYTES / 64;
localparam int AW = $clog2(DEPTH);

logic [AW:0] wptr = '0, fptr = '0;
wire  logic [AW:0] used = wptr - fptr;
wire  logic  space = (used < (AW+1)'(DEPTH));
assign stat_used_beats = used;

// ---------------- write side ----------------
typedef enum logic [1:0] {W_IDLE, W_DATA, W_OUT} wst_t;
wst_t ws = W_IDLE;
logic [AW:0]  w_start;
logic [AW:0]  w_left;           // beats still to store
logic [QPW-1:0] o_qp;
logic [1:0]   o_class;
logic [63:0]  o_va;
logic [31:0]  o_rkey, o_len, o_imm;
logic [15:0]  o_id;
logic [1:0]   o_flags;

wire logic [AW:0] nbeats = (AW+1)'((s_wr_len + 32'd63) >> 6);
wire logic sz_full;
assign s_wr_ready   = (ws == W_IDLE) && !sz_full;
assign s_pay_tready = (ws == W_DATA) && space;
wire logic pay_fire = s_pay_tvalid && s_pay_tready;

always_ff @(posedge clk) begin
    ev_tlast_err <= pay_fire && (s_pay_tlast != (w_left == 1));
    case (ws)
        W_IDLE: if (s_wr_valid && s_wr_ready) begin
            o_qp <= s_wr_qp; o_class <= s_wr_class; o_va <= s_wr_va; o_rkey <= s_wr_rkey;
            o_len <= s_wr_len; o_imm <= s_wr_imm; o_id <= s_wr_id; o_flags <= s_wr_flags;
            w_start <= wptr;
            w_left  <= nbeats;
            ws <= (nbeats == 0) ? W_OUT : W_DATA;
        end
        W_DATA: if (pay_fire) begin
            w_left <= w_left - 1'b1;
            if (w_left == 1) ws <= W_OUT;
        end
        W_OUT: if (m_wr_ready) ws <= W_IDLE;
        default: ws <= W_IDLE;
    endcase
    if (pay_fire) wptr <= wptr + 1'b1;
    if (rst) begin
        ws   <= W_IDLE;
        wptr <= '0;
    end
end

assign m_wr_valid = (ws == W_OUT);
assign m_wr_qp    = o_qp;
assign m_wr_class = o_class;
assign m_wr_va    = o_va;
assign m_wr_rkey  = o_rkey;
assign m_wr_len   = o_len;
assign m_wr_imm   = o_imm;
assign m_wr_id    = o_id;
assign m_wr_flags = o_flags;
assign m_wr_laddr = {{(58-AW){1'b0}}, w_start[AW-1:0], 6'd0};

// sizes of the WRs in the ring, in order, for freeing on completion
wire logic [AW:0] sz_out;
wire logic        sz_v;
rocelet_fifo #(.WIDTH(AW + 1), .DEPTH(MAX_WR), .RAM_STYLE("distributed")) u_sz (
    .clk(clk), .rst(rst), .din(nbeats), .wr_en(s_wr_valid && s_wr_ready), .full(sz_full),
    .dout(sz_out), .valid(sz_v), .rd_en(s_cpl_valid && sz_v), .count()
);
always_ff @(posedge clk) begin
    if (s_cpl_valid && sz_v) fptr <= fptr + sz_out;
    if (rst) fptr <= '0;
end

// ---------------- read side (MM2S emulation) ----------------
logic          r_act = 1'b0;
logic [AW-1:0] r_ptr;
logic [7:0]    r_left;
wire  logic [511:0] rd_data;
logic          rd_issue;

rocelet_ram_sdp #(.WIDTH(512), .DEPTH(DEPTH), .RD_LAT(RD_LAT), .RAM_STYLE(RAM_STYLE)) u_ram (
    .clk(clk), .we(pay_fire), .waddr(wptr[AW-1:0]), .wdata(s_pay_tdata),
    .re(rd_issue), .raddr(r_ptr), .rdata(rd_data)
);

localparam int OFD = (RD_LAT + 4 <= 8) ? 8 : 16;
wire  logic [$clog2(OFD):0] of_cnt;
logic [RD_LAT-1:0] inflight = '0;
logic [$clog2(OFD):0] n_inflight;
always_comb begin
    n_inflight = '0;
    for (int i = 0; i < RD_LAT; i++) n_inflight = n_inflight + inflight[i];
end
assign rd_issue = r_act && (of_cnt + n_inflight < ($clog2(OFD)+1)'(OFD));
assign s_rcmd_ready = !r_act;

always_ff @(posedge clk) begin
    inflight <= {inflight[RD_LAT-2:0], rd_issue};
    if (s_rcmd_valid && !r_act) begin
        r_act  <= (s_rcmd_len != 0);
        r_ptr  <= s_rcmd_addr[AW+5:6];
        r_left <= 8'((s_rcmd_len + 13'd63) >> 6);
    end else if (rd_issue) begin
        r_ptr  <= r_ptr + 1'b1;
        r_left <= r_left - 8'd1;
        if (r_left == 8'd1) r_act <= 1'b0;
    end
    if (rst) begin
        r_act    <= 1'b0;
        inflight <= '0;
    end
end

rocelet_fifo #(.WIDTH(512), .DEPTH(OFD), .RAM_STYLE("distributed")) u_of (
    .clk(clk), .rst(rst), .din(rd_data), .wr_en(inflight[RD_LAT-1]), .full(),
    .dout(m_rdat_tdata), .valid(m_rdat_tvalid), .rd_en(m_rdat_tready), .count(of_cnt)
);

endmodule

`resetall
