// SPDX-License-Identifier: MIT
//
// rocelet_crc32_core - pipelined CRC-32 engine for a 512-bit (64-byte) stream.
//
// One beat per clock, no back-pressure (in_valid = the upstream handshake).
// Non-last beats must carry 64 bytes; the last beat of a packet carries
// in_nbytes = 1..64 valid bytes in lanes 0..n-1 (contiguous tkeep).
// out_crc is the raw CRC register after the packet's last byte (NOT inverted);
// one out_valid pulse per packet, LAT = 10 clocks after the last beat.
//
// Structure (linear-algebra split of the CRC update S' = A^k S ^ D_k d):
//   A   input register
//   B   data terms, independent of the CRC state: D32(lo half), D32(hi half)
//       and the tail chunk terms D16/D8/D4/D2/D1 of a partial last beat
//       (chunk start = in_nbytes with the lower bits cleared, i.e. the binary
//       decomposition of the byte count: 32 | 16 | 8 | 4 | 2 | 1 bytes)
//   B2  full-beat data term D64 = A32*D32(lo) ^ D32(hi)
//   C   the only feedback loop: S <= A64*S ^ D64 (a 32x32 matrix + XOR)
//   D..I one tail stage per chunk size, feed-forward (no loop), so a partial
//       last beat costs no throughput.
// GRAN / REM: last-beat byte counts are known to satisfy n mod GRAN == REM
// (RoCE v2 frames: GRAN = 4, REM = 2), which removes the narrow tail stages
// and their chunk multiplexers at elaboration.
// INIT is the register value before byte 0 of a packet. Seeds can instead be
// folded into the first data bytes (CRC(S, d) = CRC(0, d ^ S)) and INIT = 0.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_crc32_core #(
    parameter logic [31:0] INIT = 32'h0000_0000,
    parameter int          GRAN = 1,    // 1, 2 or 4
    parameter int          REM  = 0,    // n mod GRAN on a partial last beat
    // 0: two 256-bit data networks D32(lo), D32(hi) combined as A32*D32(lo)^D32(hi);
    // 1: one shared 512-bit network D64 on {full ? hi : 0, lo}; the tail's 32-byte
    //    term is recovered as A^-32 * D64(lo, 0) (rocelet_crc32_inv)
    parameter bit          SHARE = 1'b0
) (
    input  wire logic         clk,
    input  wire logic         rst,

    input  wire logic         in_valid,
    input  wire logic         in_first,
    input  wire logic         in_last,
    input  wire logic [511:0] in_data,
    input  wire logic [6:0]   in_nbytes,

    output wire logic         out_valid,
    output wire logic [31:0]  out_crc
);

localparam logic [5:0] NMASK = ~6'(GRAN-1);
localparam logic [5:0] NREM  = 6'(REM);

// ---------------- stage A: input register ----------------
logic         a_valid = 1'b0, a_first = 1'b0, a_last = 1'b0;
logic [511:0] a_data;
logic         a_full;          // 64 bytes
logic [5:0]   a_n;             // byte count of a partial last beat (1..63)

always_ff @(posedge clk) begin
    a_valid <= in_valid;
    a_first <= in_first;
    a_last  <= in_last;
    a_data  <= in_data;
    a_full  <= in_nbytes[6];
    a_n     <= (in_nbytes[5:0] & NMASK) | NREM;
    if (rst) a_valid <= 1'b0;
end

// ---------------- stage B: data terms ----------------
wire logic [31:0] d32_lo, d32_hi, d16, d8, d4, d2, d1, d64s;

if (SHARE) begin : g_share
    wire logic [511:0] d64_in = {a_data[511:256] & {256{a_full}}, a_data[255:0]};
    rocelet_crc32_xor #(.NB(64), .USE_STATE(1'b0)) u_d64 (
        .state_in(32'd0), .data_in(d64_in), .state_out(d64s));
    assign d32_lo = '0;
    assign d32_hi = '0;
end else begin : g_split
    rocelet_crc32_xor #(.NB(32), .USE_STATE(1'b0)) u_d32lo (.state_in(32'd0), .data_in(a_data[255:0]),   .state_out(d32_lo));
    rocelet_crc32_xor #(.NB(32), .USE_STATE(1'b0)) u_d32hi (.state_in(32'd0), .data_in(a_data[511:256]), .state_out(d32_hi));
    assign d64s = '0;
end

// tail chunks: chunk for size 2^k starts at byte (a_n & ~(2^(k+1)-1))
wire logic [127:0] c16 = a_n[5] ? a_data[256 +: 128] : a_data[0 +: 128];
wire logic [511:0] sh8 = a_data >> {a_n[5:4], 7'd0};     // chunk start (n & 6'b110000) bytes
wire logic [511:0] sh4 = a_data >> {a_n[5:3], 6'd0};     // (n & 6'b111000)
wire logic [511:0] sh2 = a_data >> {a_n[5:2], 5'd0};     // (n & 6'b111100)
wire logic [511:0] sh1 = a_data >> {a_n[5:1], 4'd0};     // (n & 6'b111110)
wire logic [63:0]  c8  = sh8[63:0];
wire logic [31:0]  c4  = sh4[31:0];
wire logic [15:0]  c2  = sh2[15:0];
wire logic [7:0]   c1  = sh1[7:0];

rocelet_crc32_xor #(.NB(16), .USE_STATE(1'b0)) u_d16 (.state_in(32'd0), .data_in(c16), .state_out(d16));
rocelet_crc32_xor #(.NB(8),  .USE_STATE(1'b0)) u_d8  (.state_in(32'd0), .data_in(c8),  .state_out(d8));
rocelet_crc32_xor #(.NB(4),  .USE_STATE(1'b0)) u_d4  (.state_in(32'd0), .data_in(c4),  .state_out(d4));
rocelet_crc32_xor #(.NB(2),  .USE_STATE(1'b0)) u_d2  (.state_in(32'd0), .data_in(c2),  .state_out(d2));
rocelet_crc32_xor #(.NB(1),  .USE_STATE(1'b0)) u_d1  (.state_in(32'd0), .data_in(c1),  .state_out(d1));

logic        b_valid = 1'b0, b_first, b_last, b_full;
logic [5:0]  b_n;
logic [31:0] b_dlo, b_dhi, b_d16, b_d8, b_d4, b_d2, b_d1, b_d64s;

always_ff @(posedge clk) begin
    b_valid <= a_valid;
    b_first <= a_first;
    b_last  <= a_last;
    b_full  <= a_full;
    b_n     <= a_n;
    b_dlo   <= d32_lo;
    b_dhi   <= d32_hi;
    b_d64s  <= d64s;
    b_d16   <= d16;
    b_d8    <= d8;
    b_d4    <= d4;
    b_d2    <= d2;
    b_d1    <= d1;
    if (rst) b_valid <= 1'b0;
end

// ---------------- stage B2: full-beat data term ----------------
wire logic [31:0] a32_dlo, inv_dlo;
if (SHARE) begin : g_b2s
    // partial beat: D64(lo, 0) = A^32 D32(lo)  ->  D32(lo) = A^-32 D64(lo, 0)
    rocelet_crc32_inv u_inv (.state_in(b_d64s), .state_out(inv_dlo));
    assign a32_dlo = '0;
end else begin : g_b2
    rocelet_crc32_xor #(.NB(32), .USE_DATA(1'b0)) u_a32b (.state_in(b_dlo), .data_in('0), .state_out(a32_dlo));
    assign inv_dlo = '0;
end

logic        b2_valid = 1'b0, b2_first, b2_last, b2_full;
logic [5:0]  b2_n;
logic [31:0] b2_d64, b2_dlo, b2_d16, b2_d8, b2_d4, b2_d2, b2_d1;

always_ff @(posedge clk) begin
    b2_valid <= b_valid;
    b2_first <= b_first;
    b2_last  <= b_last;
    b2_full  <= b_full;
    b2_n     <= b_n;
    b2_d64   <= SHARE ? b_d64s : (a32_dlo ^ b_dhi);
    b2_dlo   <= SHARE ? inv_dlo : b_dlo;
    b2_d16   <= b_d16;
    b2_d8    <= b_d8;
    b2_d4    <= b_d4;
    b2_d2    <= b_d2;
    b2_d1    <= b_d1;
    if (rst) b2_valid <= 1'b0;
end

// ---------------- stage C: the feedback loop ----------------
logic [31:0] s_reg = 32'd0;
wire  logic [31:0] s_base = b2_first ? INIT : s_reg;
wire  logic [31:0] a64_s;
rocelet_crc32_xor #(.NB(64), .USE_DATA(1'b0)) u_a64 (.state_in(s_base), .data_in('0), .state_out(a64_s));

logic        c_valid = 1'b0;
logic [5:0]  c_n;              // remaining tail bytes (0 if the last beat was full)
logic [31:0] c_dlo, c_d16, c_d8, c_d4, c_d2, c_d1;

always_ff @(posedge clk) begin
    if (b2_valid) begin
        s_reg <= b2_full ? (a64_s ^ b2_d64) : s_base;
    end
    c_valid <= b2_valid & b2_last;
    c_n     <= b2_full ? 6'd0 : b2_n;
    c_dlo   <= b2_dlo;
    c_d16   <= b2_d16;
    c_d8    <= b2_d8;
    c_d4    <= b2_d4;
    c_d2    <= b2_d2;
    c_d1    <= b2_d1;
    if (rst) c_valid <= 1'b0;
end

// ---------------- stages D..I: tail, one chunk size per stage ----------------
// stage t consumes the 2^(5-t)-byte chunk if bit (5-t) of the byte count is set
wire logic        t_valid [7];
wire logic [31:0] t_s     [7];
wire logic [5:0]  t_n     [7];
wire logic [31:0] t_dt    [7][6];    // data terms by chunk bit 5..0

assign t_valid[0] = c_valid;
assign t_s[0]     = s_reg;
assign t_n[0]     = c_n;
assign t_dt[0][5] = c_dlo;
assign t_dt[0][4] = c_d16;
assign t_dt[0][3] = c_d8;
assign t_dt[0][2] = c_d4;
assign t_dt[0][1] = c_d2;
assign t_dt[0][0] = c_d1;

for (genvar t = 0; t < 6; t++) begin : g_tail
    localparam int BIT = 5 - t;
    localparam int NBY = 1 << BIT;
    // a stage whose count bit is fixed to 0 by GRAN/REM is a pure delay
    localparam bit ALWAYS_OFF = (BIT < $clog2(GRAN)) && !NREM[BIT];
    wire logic [31:0] adv;
    if (ALWAYS_OFF) begin : g_off
        assign adv = t_s[t];
    end else begin : g_on
        rocelet_crc32_xor #(.NB(NBY), .USE_DATA(1'b0)) u_a (.state_in(t_s[t]), .data_in('0), .state_out(adv));
    end

    logic        v = 1'b0;
    logic [31:0] s;
    logic [5:0]  n;
    logic [31:0] dt [6];
    always_ff @(posedge clk) begin
        v <= t_valid[t];
        n <= t_n[t];
        if (!ALWAYS_OFF && t_n[t][BIT]) s <= adv ^ t_dt[t][BIT];
        else                            s <= t_s[t];
        for (int j = 0; j < 6; j++) dt[j] <= t_dt[t][j];
        if (rst) v <= 1'b0;
    end
    assign t_valid[t+1] = v;
    assign t_s[t+1]     = s;
    assign t_n[t+1]     = n;
    for (genvar j = 0; j < 6; j++) begin : g_dt
        assign t_dt[t+1][j] = dt[j];
    end
end

assign out_valid = t_valid[6];
assign out_crc   = t_s[6];

endmodule

`resetall
