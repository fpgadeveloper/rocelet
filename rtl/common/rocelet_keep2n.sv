// SPDX-License-Identifier: MIT
//
// rocelet_keep2n - byte count of a contiguous (thermometer, lane 0 first) tkeep.
// Returns 0..KW. Built from the one-hot "last valid lane" so each output bit is
// a single OR over KW/2 terms, cheaper than a popcount adder tree.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_keep2n #(
    parameter int KW = 64
) (
    input  wire logic [KW-1:0]          keep,
    output wire logic [$clog2(KW+1)-1:0] n
);

localparam int NW = $clog2(KW+1);

logic [KW-1:0] edge_oh;     // edge_oh[i] = lane i is the last valid lane
always_comb begin
    for (int i = 0; i < KW-1; i++) edge_oh[i] = keep[i] & ~keep[i+1];
    edge_oh[KW-1] = keep[KW-1];
end

logic [NW-1:0] n_c;
always_comb begin
    n_c = '0;
    for (int unsigned i = 0; i < KW; i++) begin
        if (edge_oh[i]) n_c = n_c | NW'(i + 1);
    end
end
assign n = n_c;

endmodule

`resetall
