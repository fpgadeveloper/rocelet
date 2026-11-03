// SPDX-License-Identifier: MIT
//
// rocelet_crc32_xor - combinational CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320)
// state update over NB data bytes: state_out = A^NB * state_in  XOR  D_NB * data_in
// over GF(2). Byte b of the data is data_in[8b +: 8], byte 0 first on the wire,
// each byte LSB first (the Ethernet FCS / zlib crc32 bit order).
//
// USE_STATE = 0 builds only the data term (state_in ignored), USE_DATA = 0 only
// the state term (data_in ignored): the two halves can be placed in different
// pipeline stages because the update is linear. The XOR network is derived at
// elaboration time from a symbolic run of the bit-serial LFSR (one dependency
// vector per state bit), so each output is a single balanced reduction-XOR.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
// rocelet.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_crc32_xor #(
    parameter int NB        = 64,
    parameter bit USE_STATE = 1'b1,
    parameter bit USE_DATA  = 1'b1
) (
    input  wire logic [31:0]     state_in,
    input  wire logic [8*NB-1:0] data_in,
    output wire logic [31:0]     state_out
);

localparam int DW = 8*NB;
localparam int VW = 32 + DW;     // dependency vector: [31:0] state bits, [VW-1:32] data bits
localparam logic [31:0] POLY_R = 32'hEDB88320;

function automatic logic [31:0][VW-1:0] crc_matrix();
    logic [31:0][VW-1:0] st;
    logic [VW-1:0] fb;
    for (int k = 0; k < 32; k++) begin
        st[k] = '0;
        st[k][k] = 1'b1;
    end
    for (int i = 0; i < DW; i++) begin
        fb = st[0];
        fb[32+i] = ~fb[32+i];
        for (int k = 0; k < 31; k++) begin
            st[k] = POLY_R[k] ? (st[k+1] ^ fb) : st[k+1];
        end
        st[31] = fb;   // POLY_R[31] = 1
    end
    return st;
endfunction

localparam logic [31:0][VW-1:0] M = crc_matrix();

wire logic [VW-1:0] vin = {USE_DATA ? data_in : {DW{1'b0}}, USE_STATE ? state_in : 32'd0};

for (genvar k = 0; k < 32; k++) begin : g_out
    assign state_out[k] = ^(vin & M[k]);
end

endmodule

`resetall
