// SPDX-License-Identifier: MIT
//
// rocelet_tx_arb - two-source packet arbiter in front of the header builder. Source 0
// (responses: ACK/NAK, READ responses) has priority over source 1 (requester data). A
// descriptor is forwarded whole; its payload beats (ceil(len / 64)) are then routed
// from the same source's payload stream, in descriptor order, through a small order
// FIFO, so the builder sees descriptor and payload in step. A descriptor marked `drop`
// is not forwarded: its payload beats are consumed and discarded (a flushed WR whose
// payload is already on the stream).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_tx_arb
    import rocelet_pkg::*;
(
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic          s0_desc_valid,
    output wire logic          s0_desc_ready,
    input  tx_desc_t           s0_desc,
    input  wire logic [511:0]  s0_pay_tdata,
    input  wire logic          s0_pay_tvalid,
    output wire logic          s0_pay_tready,

    input  wire logic          s1_desc_valid,
    output wire logic          s1_desc_ready,
    input  tx_desc_t           s1_desc,
    input  wire logic [511:0]  s1_pay_tdata,
    input  wire logic          s1_pay_tvalid,
    output wire logic          s1_pay_tready,

    output wire logic          m_desc_valid,
    input  wire logic          m_desc_ready,
    output tx_desc_t           m_desc,
    output wire logic [511:0]  m_pay_tdata,
    output wire logic          m_pay_tvalid,
    input  wire logic          m_pay_tready
);

// descriptor stage
logic        d_v = 1'b0;
tx_desc_t    d;
wire  logic  of_full;
wire  logic  d_slot = (!d_v || m_desc_ready) && !of_full;
wire  logic  g0 = d_slot && s0_desc_valid;
wire  logic  g1 = d_slot && !s0_desc_valid && s1_desc_valid;
assign s0_desc_ready = g0;
assign s1_desc_ready = g1;

wire tx_desc_t   gd    = g0 ? s0_desc : s1_desc;
wire logic [6:0] nbeat = 7'((gd.len + 13'd63) >> 6);

always_ff @(posedge clk) begin
    if (m_desc_ready) d_v <= 1'b0;
    if ((g0 || g1) && !gd.drop) begin
        d_v <= 1'b1;
        d   <= gd;
    end
    if (rst) d_v <= 1'b0;
end
assign m_desc_valid = d_v;
assign m_desc       = d;

// order FIFO: {src, drop, beats}
wire logic       o_src, o_drop;
wire logic [6:0] o_nb;
wire logic       o_v;
logic            o_pop;
rocelet_fifo #(.WIDTH(9), .DEPTH(8), .RAM_STYLE("distributed")) u_of (
    .clk(clk), .rst(rst), .din({g1, gd.drop, nbeat}), .wr_en((g0 || g1) && nbeat != 0), .full(of_full),
    .dout({o_src, o_drop, o_nb}), .valid(o_v), .rd_en(o_pop), .count()
);

logic [6:0] cnt = '0;
wire  logic src_v = o_v && (o_src ? s1_pay_tvalid : s0_pay_tvalid);
wire  logic take  = o_drop || m_pay_tready;
assign m_pay_tdata   = o_src ? s1_pay_tdata : s0_pay_tdata;
assign m_pay_tvalid  = src_v && !o_drop;
assign s0_pay_tready = o_v && !o_src && take;
assign s1_pay_tready = o_v &&  o_src && take;
wire  logic beat = src_v && take;
assign o_pop = beat && (cnt == o_nb - 7'd1);

always_ff @(posedge clk) begin
    if (beat) cnt <= o_pop ? 7'd0 : cnt + 7'd1;
    if (rst) cnt <= '0;
end

endmodule

`resetall
