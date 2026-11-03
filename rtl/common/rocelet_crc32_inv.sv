// SPDX-License-Identifier: MIT
//
// rocelet_crc32_inv - CRC-32 (reflected, 0xEDB88320) register run BACKWARDS over 32
// zero bytes, i.e. the inverse state matrix A^-32 as explicit XOR equations
// (generated with a symbolic matrix inversion; checked: A^32 * A^-32 = I).
// Used by rocelet_crc32_core (SHARE = 1): D64(lo, 0^32) = A^32 D32(lo), so
// D32(lo) = A^-32 D64(lo, 0^32).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_crc32_inv (
    input  wire logic [31:0] state_in,
    output wire logic [31:0] state_out
);

assign state_out[0] = state_in[2] ^ state_in[3] ^ state_in[6] ^ state_in[7] ^ state_in[11] ^ state_in[13] ^ state_in[14] ^ state_in[15] ^ state_in[19] ^ state_in[23] ^ state_in[25] ^ state_in[26] ^ state_in[27] ^ state_in[28] ^ state_in[29] ^ state_in[31];
assign state_out[1] = state_in[0] ^ state_in[3] ^ state_in[4] ^ state_in[7] ^ state_in[8] ^ state_in[12] ^ state_in[14] ^ state_in[15] ^ state_in[16] ^ state_in[20] ^ state_in[24] ^ state_in[26] ^ state_in[27] ^ state_in[28] ^ state_in[29] ^ state_in[30];
assign state_out[2] = state_in[1] ^ state_in[4] ^ state_in[5] ^ state_in[8] ^ state_in[9] ^ state_in[13] ^ state_in[15] ^ state_in[16] ^ state_in[17] ^ state_in[21] ^ state_in[25] ^ state_in[27] ^ state_in[28] ^ state_in[29] ^ state_in[30] ^ state_in[31];
assign state_out[3] = state_in[0] ^ state_in[2] ^ state_in[5] ^ state_in[6] ^ state_in[9] ^ state_in[10] ^ state_in[14] ^ state_in[16] ^ state_in[17] ^ state_in[18] ^ state_in[22] ^ state_in[26] ^ state_in[28] ^ state_in[29] ^ state_in[30] ^ state_in[31];
assign state_out[4] = state_in[1] ^ state_in[3] ^ state_in[6] ^ state_in[7] ^ state_in[10] ^ state_in[11] ^ state_in[15] ^ state_in[17] ^ state_in[18] ^ state_in[19] ^ state_in[23] ^ state_in[27] ^ state_in[29] ^ state_in[30] ^ state_in[31];
assign state_out[5] = state_in[0] ^ state_in[2] ^ state_in[4] ^ state_in[7] ^ state_in[8] ^ state_in[11] ^ state_in[12] ^ state_in[16] ^ state_in[18] ^ state_in[19] ^ state_in[20] ^ state_in[24] ^ state_in[28] ^ state_in[30] ^ state_in[31];
assign state_out[6] = state_in[1] ^ state_in[2] ^ state_in[5] ^ state_in[6] ^ state_in[7] ^ state_in[8] ^ state_in[9] ^ state_in[11] ^ state_in[12] ^ state_in[14] ^ state_in[15] ^ state_in[17] ^ state_in[20] ^ state_in[21] ^ state_in[23] ^ state_in[26] ^ state_in[27] ^ state_in[28];
assign state_out[7] = state_in[0] ^ state_in[2] ^ state_in[3] ^ state_in[6] ^ state_in[7] ^ state_in[8] ^ state_in[9] ^ state_in[10] ^ state_in[12] ^ state_in[13] ^ state_in[15] ^ state_in[16] ^ state_in[18] ^ state_in[21] ^ state_in[22] ^ state_in[24] ^ state_in[27] ^ state_in[28] ^ state_in[29];
assign state_out[8] = state_in[0] ^ state_in[1] ^ state_in[3] ^ state_in[4] ^ state_in[7] ^ state_in[8] ^ state_in[9] ^ state_in[10] ^ state_in[11] ^ state_in[13] ^ state_in[14] ^ state_in[16] ^ state_in[17] ^ state_in[19] ^ state_in[22] ^ state_in[23] ^ state_in[25] ^ state_in[28] ^ state_in[29] ^ state_in[30];
assign state_out[9] = state_in[1] ^ state_in[3] ^ state_in[4] ^ state_in[5] ^ state_in[6] ^ state_in[7] ^ state_in[8] ^ state_in[9] ^ state_in[10] ^ state_in[12] ^ state_in[13] ^ state_in[17] ^ state_in[18] ^ state_in[19] ^ state_in[20] ^ state_in[24] ^ state_in[25] ^ state_in[27] ^ state_in[28] ^ state_in[30];
assign state_out[10] = state_in[3] ^ state_in[4] ^ state_in[5] ^ state_in[8] ^ state_in[9] ^ state_in[10] ^ state_in[15] ^ state_in[18] ^ state_in[20] ^ state_in[21] ^ state_in[23] ^ state_in[27];
assign state_out[11] = state_in[4] ^ state_in[5] ^ state_in[6] ^ state_in[9] ^ state_in[10] ^ state_in[11] ^ state_in[16] ^ state_in[19] ^ state_in[21] ^ state_in[22] ^ state_in[24] ^ state_in[28];
assign state_out[12] = state_in[0] ^ state_in[5] ^ state_in[6] ^ state_in[7] ^ state_in[10] ^ state_in[11] ^ state_in[12] ^ state_in[17] ^ state_in[20] ^ state_in[22] ^ state_in[23] ^ state_in[25] ^ state_in[29];
assign state_out[13] = state_in[1] ^ state_in[6] ^ state_in[7] ^ state_in[8] ^ state_in[11] ^ state_in[12] ^ state_in[13] ^ state_in[18] ^ state_in[21] ^ state_in[23] ^ state_in[24] ^ state_in[26] ^ state_in[30];
assign state_out[14] = state_in[2] ^ state_in[7] ^ state_in[8] ^ state_in[9] ^ state_in[12] ^ state_in[13] ^ state_in[14] ^ state_in[19] ^ state_in[22] ^ state_in[24] ^ state_in[25] ^ state_in[27] ^ state_in[31];
assign state_out[15] = state_in[3] ^ state_in[8] ^ state_in[9] ^ state_in[10] ^ state_in[13] ^ state_in[14] ^ state_in[15] ^ state_in[20] ^ state_in[23] ^ state_in[25] ^ state_in[26] ^ state_in[28];
assign state_out[16] = state_in[2] ^ state_in[3] ^ state_in[4] ^ state_in[6] ^ state_in[7] ^ state_in[9] ^ state_in[10] ^ state_in[13] ^ state_in[16] ^ state_in[19] ^ state_in[21] ^ state_in[23] ^ state_in[24] ^ state_in[25] ^ state_in[28] ^ state_in[31];
assign state_out[17] = state_in[3] ^ state_in[4] ^ state_in[5] ^ state_in[7] ^ state_in[8] ^ state_in[10] ^ state_in[11] ^ state_in[14] ^ state_in[17] ^ state_in[20] ^ state_in[22] ^ state_in[24] ^ state_in[25] ^ state_in[26] ^ state_in[29];
assign state_out[18] = state_in[4] ^ state_in[5] ^ state_in[6] ^ state_in[8] ^ state_in[9] ^ state_in[11] ^ state_in[12] ^ state_in[15] ^ state_in[18] ^ state_in[21] ^ state_in[23] ^ state_in[25] ^ state_in[26] ^ state_in[27] ^ state_in[30];
assign state_out[19] = state_in[0] ^ state_in[5] ^ state_in[6] ^ state_in[7] ^ state_in[9] ^ state_in[10] ^ state_in[12] ^ state_in[13] ^ state_in[16] ^ state_in[19] ^ state_in[22] ^ state_in[24] ^ state_in[26] ^ state_in[27] ^ state_in[28] ^ state_in[31];
assign state_out[20] = state_in[0] ^ state_in[1] ^ state_in[2] ^ state_in[3] ^ state_in[8] ^ state_in[10] ^ state_in[15] ^ state_in[17] ^ state_in[19] ^ state_in[20] ^ state_in[26] ^ state_in[31];
assign state_out[21] = state_in[1] ^ state_in[4] ^ state_in[6] ^ state_in[7] ^ state_in[9] ^ state_in[13] ^ state_in[14] ^ state_in[15] ^ state_in[16] ^ state_in[18] ^ state_in[19] ^ state_in[20] ^ state_in[21] ^ state_in[23] ^ state_in[25] ^ state_in[26] ^ state_in[28] ^ state_in[29] ^ state_in[31];
assign state_out[22] = state_in[0] ^ state_in[3] ^ state_in[5] ^ state_in[6] ^ state_in[8] ^ state_in[10] ^ state_in[11] ^ state_in[13] ^ state_in[16] ^ state_in[17] ^ state_in[20] ^ state_in[21] ^ state_in[22] ^ state_in[23] ^ state_in[24] ^ state_in[25] ^ state_in[28] ^ state_in[30] ^ state_in[31];
assign state_out[23] = state_in[1] ^ state_in[4] ^ state_in[6] ^ state_in[7] ^ state_in[9] ^ state_in[11] ^ state_in[12] ^ state_in[14] ^ state_in[17] ^ state_in[18] ^ state_in[21] ^ state_in[22] ^ state_in[23] ^ state_in[24] ^ state_in[25] ^ state_in[26] ^ state_in[29] ^ state_in[31];
assign state_out[24] = state_in[0] ^ state_in[3] ^ state_in[5] ^ state_in[6] ^ state_in[8] ^ state_in[10] ^ state_in[11] ^ state_in[12] ^ state_in[14] ^ state_in[18] ^ state_in[22] ^ state_in[24] ^ state_in[28] ^ state_in[29] ^ state_in[30] ^ state_in[31];
assign state_out[25] = state_in[1] ^ state_in[2] ^ state_in[3] ^ state_in[4] ^ state_in[9] ^ state_in[12] ^ state_in[14] ^ state_in[26] ^ state_in[27] ^ state_in[28] ^ state_in[30];
assign state_out[26] = state_in[2] ^ state_in[3] ^ state_in[4] ^ state_in[5] ^ state_in[10] ^ state_in[13] ^ state_in[15] ^ state_in[27] ^ state_in[28] ^ state_in[29] ^ state_in[31];
assign state_out[27] = state_in[0] ^ state_in[2] ^ state_in[4] ^ state_in[5] ^ state_in[7] ^ state_in[13] ^ state_in[15] ^ state_in[16] ^ state_in[19] ^ state_in[23] ^ state_in[25] ^ state_in[26] ^ state_in[27] ^ state_in[30] ^ state_in[31];
assign state_out[28] = state_in[1] ^ state_in[2] ^ state_in[5] ^ state_in[7] ^ state_in[8] ^ state_in[11] ^ state_in[13] ^ state_in[15] ^ state_in[16] ^ state_in[17] ^ state_in[19] ^ state_in[20] ^ state_in[23] ^ state_in[24] ^ state_in[25] ^ state_in[29];
assign state_out[29] = state_in[2] ^ state_in[3] ^ state_in[6] ^ state_in[8] ^ state_in[9] ^ state_in[12] ^ state_in[14] ^ state_in[16] ^ state_in[17] ^ state_in[18] ^ state_in[20] ^ state_in[21] ^ state_in[24] ^ state_in[25] ^ state_in[26] ^ state_in[30];
assign state_out[30] = state_in[0] ^ state_in[2] ^ state_in[4] ^ state_in[6] ^ state_in[9] ^ state_in[10] ^ state_in[11] ^ state_in[14] ^ state_in[17] ^ state_in[18] ^ state_in[21] ^ state_in[22] ^ state_in[23] ^ state_in[28] ^ state_in[29];
assign state_out[31] = state_in[1] ^ state_in[2] ^ state_in[5] ^ state_in[6] ^ state_in[10] ^ state_in[12] ^ state_in[13] ^ state_in[14] ^ state_in[18] ^ state_in[22] ^ state_in[24] ^ state_in[25] ^ state_in[26] ^ state_in[27] ^ state_in[28] ^ state_in[30] ^ state_in[31];

endmodule

`resetall
