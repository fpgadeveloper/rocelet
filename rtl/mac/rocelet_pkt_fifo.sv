// SPDX-License-Identifier: MIT
//
// rocelet_pkt_fifo - store-and-forward frame FIFO (512-bit AXI-Stream, back-pressure on
// both sides). A frame is offered downstream only once its last beat is in, so the
// output never pauses inside a frame: the CMAC TX interface must not see tvalid drop
// between the first and the last beat of a frame (underrun = bad FCS). Frames longer than
// DEPTH beats would deadlock; the sources bound their frames. Beats are stored as
// {last, byte count, data} (tkeep must be contiguous from bit 0).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_pkt_fifo #(
    parameter int DEPTH     = 512,
    parameter     RAM_STYLE = "block"
) (
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic [511:0]  s_axis_tdata,
    input  wire logic [63:0]   s_axis_tkeep,
    input  wire logic          s_axis_tvalid,
    output wire logic          s_axis_tready,
    input  wire logic          s_axis_tlast,

    output wire logic [511:0]  m_axis_tdata,
    output wire logic [63:0]   m_axis_tkeep,
    output wire logic          m_axis_tvalid,
    input  wire logic          m_axis_tready,
    output wire logic          m_axis_tlast
);

wire logic       full, v;
wire logic [511:0] d;
wire logic [6:0] n, in_n;
wire logic       l;
wire logic in_fire  = s_axis_tvalid && !full;
wire logic out_fire = m_axis_tvalid && m_axis_tready;

rocelet_keep2n #(.KW(64)) u_k2n (.keep(s_axis_tkeep), .n(in_n));

rocelet_fifo #(.WIDTH(512 + 7 + 1), .DEPTH(DEPTH), .RAM_STYLE(RAM_STYLE)) u_f (
    .clk(clk), .rst(rst), .din({s_axis_tlast, in_n, s_axis_tdata}), .wr_en(in_fire),
    .full(full), .dout({l, n, d}), .valid(v), .rd_en(out_fire), .count()
);

// complete frames held (a frame being read out stays counted until its last beat).
// A frame is counted only when its last beat can reach the output in time: the
// block-RAM FIFO needs 2 clocks from the write of a beat to its first-word-fall-through
// output stage, and a frame whose last beat arrives late (the ICRC generator holds a
// short frame's last beat ~6 clocks) would otherwise show a one-clock tvalid hole
// between its last two beats (found on the bench by the research prototype).
localparam int VLAT = ((RAM_STYLE == "block") || (RAM_STYLE == "ultra")) ? 3 : 1;
logic [VLAT-1:0]        tl_pipe = '0;
logic [$clog2(DEPTH):0] frames = '0;
logic                   out_act = 1'b0;   // a frame is being read out
always_ff @(posedge clk) begin
    tl_pipe <= {tl_pipe[VLAT-2 >= 0 ? VLAT-2 : 0 : 0], in_fire && s_axis_tlast};
    frames <= frames + (tl_pipe[VLAT-1] ? 1'b1 : 1'b0) - ((out_fire && l) ? 1'b1 : 1'b0);
    if (out_fire) out_act <= !l;
    if (rst) begin
        frames  <= '0;
        out_act <= 1'b0;
        tl_pipe <= '0;
    end
end

function automatic logic [63:0] therm(input logic [6:0] k);
    for (int i = 0; i < 64; i++) therm[i] = (i < k);
endfunction

assign s_axis_tready = !full;
assign m_axis_tvalid = v && (out_act || frames != 0);
assign m_axis_tdata  = d;
assign m_axis_tkeep  = therm(n);
assign m_axis_tlast  = l;

endmodule

`resetall
