// SPDX-License-Identifier: MIT
//
// rocelet_byte_shift - 512-bit byte funnel shifter: y = ({hi, lo} >> 8*sh)[511:0],
// i.e. y lane j = lo lane (j + sh) for j + sh < 64, else hi lane (j + sh - 64).
//   header insert (payload behind an H-byte header): lo = previous payload beat,
//     hi = current beat, sh = 64 - (H mod 64)
//   header strip (payload of a frame with an H-byte header): lo = current frame
//     beat, hi = next beat, sh = H mod 64
// GENERIC = 1: any sh in 0..63 (a full 64-way byte multiplexer per lane).
// GENERIC = 0: sh is one of the NS values in SLIST (the header lengths the
//   protocol can produce), so each output lane is only an NS-way multiplexer.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_byte_shift #(
    parameter bit GENERIC = 1'b0,
    parameter int NS = 4,
    parameter logic [NS*8-1:0] SLIST = {8'd10, 8'd6, 8'd58, 8'd54}
) (
    input  wire logic [511:0] lo,
    input  wire logic [511:0] hi,
    input  wire logic [5:0]   sh,
    output wire logic [511:0] y
);

wire logic [1023:0] cat = {hi, lo};

if (GENERIC) begin : g_gen
    wire logic [1023:0] shifted = cat >> {sh, 3'b000};
    assign y = shifted[511:0];
end else if (NS == 1) begin : g_const
    // a single possible shift: pure wiring
    wire logic [1023:0] shifted = cat >> (SLIST[7:0] * 8);
    assign y = shifted[511:0];
end else begin : g_list
    wire logic [NS-1:0] hit;
    wire logic [511:0]  cand [NS];
    for (genvar i = 0; i < NS; i++) begin : g_c
        localparam int SH = SLIST[i*8 +: 8];
        wire logic [1023:0] shifted = cat >> (SH * 8);
        assign hit[i]  = (sh == 6'(SH));
        assign cand[i] = shifted[511:0];
    end
    logic [511:0] yy;
    always_comb begin
        yy = '0;
        for (int i = 0; i < NS; i++) begin
            if (hit[i]) yy = yy | cand[i];
        end
    end
    assign y = yy;
end

endmodule

`resetall
