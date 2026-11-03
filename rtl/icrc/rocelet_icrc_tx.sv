// SPDX-License-Identifier: MIT
//
// rocelet_icrc_tx - RoCE v2 ICRC generator: appends the 4-byte ICRC to each frame of a
// 512-bit AXI-Stream (Ethernet frame without FCS; the MAC adds the FCS).
//
// s_axis: frames starting at lane 0, contiguous tkeep, tlast on the last beat.
// m_axis: the same frames with the ICRC (rocelet_icrc_mask rules) appended after the
//         last byte; a frame whose last beat has more than 60 bytes gets one
//         extra beat. Line rate: one beat per clock, plus the extra beat.
// The frame is held in a FIFO_DEPTH-beat LUTRAM FIFO while the CRC pipeline
// (rocelet_crc32_core, 10 clocks) finishes; FIFO_DEPTH >= 16 keeps back-to-back short
// frames at full rate.
// GRAN / REM: RoCE v2 frames end at a byte count n with n mod 4 == 2 (14-byte
// Ethernet header + 4-byte-aligned IP..pad coverage), so GRAN = 4 / REM = 2
// prunes the CRC tail and the ICRC insert multiplexers. GRAN = 1 handles any n.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_icrc_tx #(
    parameter int GRAN       = 4,
    parameter int REM        = 2,
    parameter int FIFO_DEPTH = 16,
    parameter bit IPV6_EN    = 1'b1,
    parameter int OFF_MODE   = 0,       // ICRC start: 0 = byte 14, 1 = 14/18 (VLAN), 2 = l3_off
    parameter bit CRC_SHARE  = 1'b0     // rocelet_crc32_core SHARE (one shared 512-bit data network)
) (
    input  wire logic         clk,
    input  wire logic         rst,
    input  wire logic [5:0]   l3_off,   // OFF_MODE 2 only

    input  wire logic [511:0] s_axis_tdata,
    input  wire logic [63:0]  s_axis_tkeep,
    input  wire logic         s_axis_tvalid,
    output wire logic         s_axis_tready,
    input  wire logic         s_axis_tlast,

    output wire logic [511:0] m_axis_tdata,
    output wire logic [63:0]  m_axis_tkeep,
    output wire logic         m_axis_tvalid,
    input  wire logic         m_axis_tready,
    output wire logic         m_axis_tlast
);

localparam logic [5:0] NMASK = ~6'(GRAN-1);
localparam logic [5:0] NREM  = 6'(REM);

// ---------------- input side ----------------
wire logic       fifo_full;
wire logic       in_fire = s_axis_tvalid && s_axis_tready;
assign s_axis_tready = !fifo_full;

logic in_beat0 = 1'b1;   // next input beat is the first of a frame
logic in_beat1 = 1'b0;
logic ipv6_hold = 1'b0;
logic [5:0] off_hold = 6'd14;

wire logic [6:0] in_n;
rocelet_keep2n #(.KW(64)) u_k2n (.keep(s_axis_tkeep), .n(in_n));

wire logic [511:0] masked;
wire logic         ipv6_det;
wire logic [5:0] off_det;
rocelet_icrc_mask #(.IPV6_EN(IPV6_EN), .OFF_MODE(OFF_MODE)) u_mask (
    .l3_off(l3_off), .off_hold(off_hold), .off_det(off_det),
    .din(s_axis_tdata), .beat0(in_beat0), .beat1(in_beat1), .ipv6_hold(ipv6_hold),
    .dout(masked), .ipv6_det(ipv6_det)
);

always_ff @(posedge clk) begin
    if (in_fire) begin
        in_beat0 <= s_axis_tlast;
        in_beat1 <= in_beat0 && !s_axis_tlast;
        if (in_beat0) begin
            ipv6_hold <= ipv6_det;
            off_hold  <= off_det;
        end
    end
    if (rst) begin
        in_beat0 <= 1'b1;
        in_beat1 <= 1'b0;
    end
end

wire logic        crc_v;
wire logic [31:0] crc_reg;
rocelet_crc32_core #(.INIT(32'd0), .GRAN(GRAN), .REM(REM), .SHARE(CRC_SHARE)) u_crc (
    .clk(clk), .rst(rst),
    .in_valid(in_fire), .in_first(in_beat0), .in_last(s_axis_tlast),
    .in_data(masked), .in_nbytes(s_axis_tlast ? in_n : 7'd64),
    .out_valid(crc_v), .out_crc(crc_reg)
);

// frame FIFO: {last, n, data}
wire logic [511:0] h_data;
wire logic [6:0]   h_n;
wire logic         h_last, h_valid;
logic              h_pop;
rocelet_fifo #(.WIDTH(512+7+1), .DEPTH(FIFO_DEPTH), .RAM_STYLE("distributed")) u_dfifo (
    .clk(clk), .rst(rst),
    .din({s_axis_tlast, in_n, s_axis_tdata}), .wr_en(in_fire), .full(fifo_full),
    .dout({h_last, h_n, h_data}), .valid(h_valid), .rd_en(h_pop), .count()
);

// ICRC FIFO (one entry per frame; never more frames than FIFO beats)
wire logic [31:0] c_icrc;
wire logic        c_valid;
logic             c_pop;
rocelet_fifo #(.WIDTH(32), .DEPTH(FIFO_DEPTH), .RAM_STYLE("distributed")) u_cfifo (
    .clk(clk), .rst(rst),
    .din(~crc_reg), .wr_en(crc_v), .full(),
    .dout(c_icrc), .valid(c_valid), .rd_en(c_pop), .count()
);

// ---------------- output side ----------------
logic [511:0] o_data;
logic [63:0]  o_keep;
logic         o_valid = 1'b0, o_last;
logic         spill = 1'b0;
logic [6:0]   spill_hn;           // byte count of the beat that spilled
logic [511:0] spill_data_r;       // its remaining ICRC bytes

wire logic out_slot = !o_valid || m_axis_tready;

// last-beat byte count, pruned by GRAN/REM (64 = full beat)
wire logic [6:0] hn = (h_n == 7'd64) ? 7'd64 : {1'b0, (h_n[5:0] & NMASK) | NREM};

function automatic logic [63:0] therm(input logic [6:0] n);
    for (int i = 0; i < 64; i++) therm[i] = (i < n);
endfunction

logic [511:0] ins_data;
always_comb begin
    ins_data = h_data;
    for (int j = 0; j < 64; j++) begin
        for (int k = 0; k < 4; k++) begin
            if (int'(hn) + k == j) ins_data[j*8 +: 8] = c_icrc[k*8 +: 8];
        end
    end
end

logic [511:0] spill_data;
always_comb begin
    spill_data = '0;
    for (int j = 0; j < 4; j++) begin
        for (int k = 0; k < 4; k++) begin
            if (int'(hn) + k == 64 + j) spill_data[j*8 +: 8] = c_icrc[k*8 +: 8];
        end
    end
end

always_comb begin
    h_pop = 1'b0;
    c_pop = 1'b0;
    if (out_slot) begin
        if (spill) begin
            c_pop = 1'b1;
        end else if (h_valid && (!h_last || c_valid)) begin
            h_pop = 1'b1;
            c_pop = h_last && (hn <= 7'd60);
        end
    end
end

always_ff @(posedge clk) begin
    if (m_axis_tready) o_valid <= 1'b0;
    if (out_slot) begin
        if (spill) begin
            // remaining ICRC bytes of the previous beat, captured with its n
            o_data  <= spill_data_r;
            o_keep  <= therm(spill_hn - 7'd60);
            o_last  <= 1'b1;
            o_valid <= 1'b1;
            spill   <= 1'b0;
        end else if (h_valid && (!h_last || c_valid)) begin
            o_valid <= 1'b1;
            if (!h_last) begin
                o_data <= h_data;
                o_keep <= '1;
                o_last <= 1'b0;
            end else if (hn <= 7'd60) begin
                o_data <= ins_data;
                o_keep <= therm(hn + 7'd4);
                o_last <= 1'b1;
            end else begin
                o_data   <= ins_data;
                o_keep   <= '1;
                o_last   <= 1'b0;
                spill    <= 1'b1;
                spill_hn <= hn;
            end
        end
    end
    if (rst) begin
        o_valid <= 1'b0;
        spill   <= 1'b0;
    end
end

// spill data computed while the ICRC is still at the FIFO head
always_ff @(posedge clk) begin
    if (out_slot && !spill) spill_data_r <= spill_data;
end

assign m_axis_tdata  = o_data;
assign m_axis_tkeep  = o_keep;
assign m_axis_tvalid = o_valid;
assign m_axis_tlast  = o_last;

endmodule

`resetall
