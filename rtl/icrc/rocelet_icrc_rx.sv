// SPDX-License-Identifier: MIT
//
// rocelet_icrc_rx - RoCE v2 ICRC checker for a 512-bit receive stream.
//
// s_axis: Ethernet frames without FCS (as delivered by the CMAC), ICRC included
//         as the last 4 bytes of the RoCE v2 payload, contiguous tkeep.
// The CRC runs over the masked frame INCLUDING the received ICRC; a good frame
// leaves the CRC register at the CRC-32 residue 0xDEBB20E3 (the same property
// the Ethernet FCS check uses), so no "length minus 4" bookkeeping is needed.
// Single-beat frames may carry Ethernet padding (a zero-length SEND ONLY over
// IPv4 is 58 bytes and is padded to 60): their CRC length is taken from the IP
// header (IPv4 total length + 14, IPv6 payload length + 54), not from tkeep.
//
// PASS_DATA = 1: frames pass through a FIFO_DEPTH-beat FIFO and the verdict is
//   on m_axis_tuser (1 = ICRC bad) with the last beat.
// PASS_DATA = 0: only the verdict stream m_verdict_* (one pulse per frame,
//   10 clocks after its last beat, in frame order); the caller holds the frame.
// GRAN / REM as in rocelet_icrc_tx (frames that violate n mod GRAN == REM are not
// RoCE v2 frames and fail the check).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_icrc_rx #(
    parameter int GRAN       = 4,
    parameter int REM        = 2,
    parameter bit PASS_DATA  = 1'b1,
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
    output wire logic         m_axis_tlast,
    output wire logic         m_axis_tuser,     // ICRC bad (last beat)

    output wire logic         m_verdict_valid,
    output wire logic         m_verdict_ok
);

localparam logic [31:0] RESIDUE = 32'hDEBB20E3;

wire logic fifo_full;
assign s_axis_tready = PASS_DATA ? !fifo_full : 1'b1;
wire logic in_fire = s_axis_tvalid && s_axis_tready;

logic in_beat0 = 1'b1, in_beat1 = 1'b0, ipv6_hold = 1'b0;
logic [5:0] off_hold = 6'd14;

wire logic [6:0] keep_n;
rocelet_keep2n #(.KW(64)) u_k2n (.keep(s_axis_tkeep), .n(keep_n));

wire logic [511:0] masked;
wire logic         ipv6_det;
wire logic [5:0] off_det;
rocelet_icrc_mask #(.IPV6_EN(IPV6_EN), .OFF_MODE(OFF_MODE)) u_mask (
    .l3_off(l3_off), .off_hold(off_hold), .off_det(off_det),
    .din(s_axis_tdata), .beat0(in_beat0), .beat1(in_beat1), .ipv6_hold(ipv6_hold),
    .dout(masked), .ipv6_det(ipv6_det)
);

// IP-header length of a single-beat frame (padding removal)
logic [15:0] ip4_tot, ip6_pl;
always_comb begin
    ip4_tot = {s_axis_tdata[16*8 +: 8], s_axis_tdata[17*8 +: 8]};
    ip6_pl  = {s_axis_tdata[18*8 +: 8], s_axis_tdata[19*8 +: 8]};
    if (OFF_MODE != 0) begin
        for (int o = 8; o <= 40; o++) begin
            if (off_det == 6'(o)) begin
                ip4_tot = {s_axis_tdata[(o+2)*8 +: 8], s_axis_tdata[(o+3)*8 +: 8]};
                ip6_pl  = {s_axis_tdata[(o+4)*8 +: 8], s_axis_tdata[(o+5)*8 +: 8]};
            end
        end
    end
end
wire logic [16:0] hdr_len = ipv6_det ? ({1'b0, ip6_pl} + 17'd40 + {11'd0, off_det}) :
                                       ({1'b0, ip4_tot} + {11'd0, off_det});
wire logic [6:0]  n_use   = (in_beat0 && (hdr_len < {10'd0, keep_n})) ? hdr_len[6:0] : keep_n;

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
    .in_data(masked), .in_nbytes(s_axis_tlast ? n_use : 7'd64),
    .out_valid(crc_v), .out_crc(crc_reg)
);

logic v_valid = 1'b0, v_ok = 1'b0;
always_ff @(posedge clk) begin
    v_valid <= crc_v;
    v_ok    <= (crc_reg == RESIDUE);
    if (rst) v_valid <= 1'b0;
end
assign m_verdict_valid = v_valid;
assign m_verdict_ok    = v_ok;

if (PASS_DATA) begin : g_pass
    wire logic [511:0] h_data;
    wire logic [63:0]  h_keep;
    wire logic         h_last, h_valid;
    wire logic         h_pop;
    rocelet_fifo #(.WIDTH(512+64+1), .DEPTH(FIFO_DEPTH), .RAM_STYLE("distributed")) u_dfifo (
        .clk(clk), .rst(rst),
        .din({s_axis_tlast, s_axis_tkeep, s_axis_tdata}), .wr_en(in_fire), .full(fifo_full),
        .dout({h_last, h_keep, h_data}), .valid(h_valid), .rd_en(h_pop), .count()
    );
    wire logic vq_ok, vq_valid;
    rocelet_fifo #(.WIDTH(1), .DEPTH(FIFO_DEPTH), .RAM_STYLE("distributed")) u_vfifo (
        .clk(clk), .rst(rst),
        .din(v_ok), .wr_en(v_valid), .full(),
        .dout(vq_ok), .valid(vq_valid), .rd_en(h_pop && h_last), .count()
    );
    logic [511:0] o_data;
    logic [63:0]  o_keep;
    logic         o_valid = 1'b0, o_last, o_user;
    wire  logic   out_slot = !o_valid || m_axis_tready;
    assign h_pop = out_slot && h_valid && (!h_last || vq_valid);
    always_ff @(posedge clk) begin
        if (m_axis_tready) o_valid <= 1'b0;
        if (h_pop) begin
            o_valid <= 1'b1;
            o_data  <= h_data;
            o_keep  <= h_keep;
            o_last  <= h_last;
            o_user  <= h_last && !vq_ok;
        end
        if (rst) o_valid <= 1'b0;
    end
    assign m_axis_tdata  = o_data;
    assign m_axis_tkeep  = o_keep;
    assign m_axis_tvalid = o_valid;
    assign m_axis_tlast  = o_last;
    assign m_axis_tuser  = o_user;
end else begin : g_nopass
    assign fifo_full     = 1'b0;
    assign m_axis_tdata  = '0;
    assign m_axis_tkeep  = '0;
    assign m_axis_tvalid = 1'b0;
    assign m_axis_tlast  = 1'b0;
    assign m_axis_tuser  = 1'b0;
end

endmodule

`resetall
