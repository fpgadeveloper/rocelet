// SPDX-License-Identifier: MIT
//
// rocelet_vlan - 802.1Q priority-tag handling at 512 bits (for host-NIC
// interop: a NIC in PCP/PFC mode sends RoCE frames with a VID-0
// "priority tag").
//
//  rocelet_vlan_strip  RX: removes a VID-0 tag (TPID 0x8100 at byte 12, VID 0, any
//                 PCP/DEI) so that the classifier and the engine see an untagged
//                 frame; other frames (untagged, or tagged with VID != 0) pass
//                 unchanged. One beat of look-ahead; full throughput.
//  rocelet_vlan_ins    TX: inserts a tag {0x8100, TCI} at byte 12 of every frame
//                 while enabled (decided per frame at its first beat). The RoCE
//                 v2 ICRC starts at the IP header, so a tag inserted after the
//                 engine leaves it valid. One bubble per frame whose last beat
//                 holds more than 60 bytes (the frame grows by a beat).
//
// Byte order: byte i of the frame is tdata[8i +: 8]; tkeep is contiguous from
// bit 0 on every beat (the CMAC and the engine produce no other).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_vlan_strip (
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic          enable,

    input  wire logic [511:0]  s_axis_tdata,
    input  wire logic [63:0]   s_axis_tkeep,
    input  wire logic          s_axis_tvalid,
    output wire logic          s_axis_tready,
    input  wire logic          s_axis_tlast,

    output wire logic [511:0]  m_axis_tdata,
    output wire logic [63:0]   m_axis_tkeep,
    output wire logic          m_axis_tvalid,
    input  wire logic          m_axis_tready,
    output wire logic          m_axis_tlast,

    output logic               ev_strip,      // a VID-0 tag was removed (one per frame)
    output logic               ev_tagged,     // a tagged frame passed unchanged (VID != 0 or disabled)
    output logic [15:0]        last_tci       // TCI of the last removed tag
);

// pending beat R (the one to be emitted next; it needs the next beat's first 4 bytes)
logic         r_v = 1'b0, r_l = 1'b0, r_first = 1'b0;
logic [511:0] r_d;
logic [63:0]  r_k;
logic         in_first = 1'b1;     // the next input beat starts a frame
logic         sf = 1'b0;           // the frame in R is being stripped

wire logic tag_r = (r_d[12*8 +: 8] == 8'h81) && (r_d[13*8 +: 8] == 8'h00) && r_k[15];
wire logic vid0  = (r_d[14*8 +: 4] == 4'h0) && (r_d[15*8 +: 8] == 8'h00);
wire logic strip = r_first ? (enable && tag_r && vid0) : sf;

// output register
logic         o_v = 1'b0, o_l;
logic [511:0] o_d;
logic [63:0]  o_k;
wire  logic   o_slot = !o_v || m_axis_tready;

wire logic emit  = r_v && (r_l || s_axis_tvalid) && o_slot;
assign s_axis_tready = !r_v || emit;
wire logic s_fire = s_axis_tvalid && s_axis_tready;
// a stripped frame whose last input beat holds <= 4 bytes ends with the current output beat
wire logic merge = emit && strip && !r_l && s_axis_tlast && !s_axis_tkeep[4];

// the beat R shifted down by 4 bytes, topped up with the next beat's first 4 bytes
logic [511:0] sh_d;
logic [63:0]  sh_k;
always_comb begin
    sh_d = {s_axis_tdata[31:0], r_d[511:32]};
    sh_k = {(r_l ? 4'h0 : s_axis_tkeep[3:0]), r_k[63:4]};
    if (r_first) begin
        sh_d[95:0] = r_d[95:0];
        sh_k[11:0] = r_k[11:0];
    end
end

always_ff @(posedge clk) begin
    ev_strip  <= 1'b0;
    ev_tagged <= 1'b0;
    if (m_axis_tready) o_v <= 1'b0;
    if (emit) begin
        o_v <= 1'b1;
        o_d <= strip ? sh_d : r_d;
        o_k <= strip ? sh_k : r_k;
        o_l <= r_l || merge;
        if (r_first) begin
            sf <= strip;
            if (strip) begin
                ev_strip <= 1'b1;
                last_tci <= {r_d[14*8 +: 8], r_d[15*8 +: 8]};
            end else if (tag_r) ev_tagged <= 1'b1;
        end
    end
    if (s_fire) in_first <= s_axis_tlast;
    // R: emptied by an emit, refilled by an accepted beat (unless it was merged)
    if (emit && !s_fire) r_v <= 1'b0;
    if (s_fire) begin
        r_v     <= !merge;
        r_d     <= s_axis_tdata;
        r_k     <= s_axis_tkeep;
        r_l     <= s_axis_tlast;
        r_first <= in_first;
    end
    if (rst) begin
        r_v      <= 1'b0;
        o_v      <= 1'b0;
        in_first <= 1'b1;
        sf       <= 1'b0;
    end
end

assign m_axis_tdata  = o_d;
assign m_axis_tkeep  = o_k;
assign m_axis_tvalid = o_v;
assign m_axis_tlast  = o_l;

endmodule

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_vlan_ins (
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic          enable,
    input  wire logic [15:0]   tci,           // {PCP, DEI, VID}

    input  wire logic [511:0]  s_axis_tdata,
    input  wire logic [63:0]   s_axis_tkeep,
    input  wire logic          s_axis_tvalid,
    output wire logic          s_axis_tready,
    input  wire logic          s_axis_tlast,

    output wire logic [511:0]  m_axis_tdata,
    output wire logic [63:0]   m_axis_tkeep,
    output wire logic          m_axis_tvalid,
    input  wire logic          m_axis_tready,
    output wire logic          m_axis_tlast,

    output logic               ev_tag         // a frame was tagged
);

logic         o_v = 1'b0, o_l;
logic [511:0] o_d;
logic [63:0]  o_k;
wire  logic   o_slot = !o_v || m_axis_tready;

logic         in_first = 1'b1;
logic         tf = 1'b0;          // the current frame is being tagged
logic [31:0]  c_d;                // carry: the last 4 bytes of the previous beat
logic [3:0]   c_k;
logic         extra = 1'b0;       // the carry is a beat of its own (frame end)

assign s_axis_tready = o_slot && !extra;
wire logic s_fire = s_axis_tvalid && s_axis_tready;
wire logic tag    = in_first ? enable : tf;

wire logic [31:0] tag32 = {tci[7:0], tci[15:8], 8'h00, 8'h81};   // bytes 12..15: 81 00 TCI

always_ff @(posedge clk) begin
    ev_tag <= 1'b0;
    if (m_axis_tready) o_v <= 1'b0;
    if (extra && o_slot) begin
        o_v   <= 1'b1;
        o_d   <= {480'd0, c_d};
        o_k   <= {60'd0, c_k};
        o_l   <= 1'b1;
        extra <= 1'b0;
    end else if (s_fire) begin
        o_v <= 1'b1;
        if (!tag) begin
            o_d <= s_axis_tdata;
            o_k <= s_axis_tkeep;
            o_l <= s_axis_tlast;
        end else begin
            if (in_first) begin
                o_d <= {s_axis_tdata[479:96], tag32, s_axis_tdata[95:0]};
                o_k <= {s_axis_tkeep[59:12], 4'hF, s_axis_tkeep[11:0]};
                ev_tag <= 1'b1;
            end else begin
                o_d <= {s_axis_tdata[479:0], c_d};
                o_k <= {s_axis_tkeep[59:0], c_k};
            end
            c_d   <= s_axis_tdata[511:480];
            c_k   <= s_axis_tkeep[63:60];
            extra <= s_axis_tlast && s_axis_tkeep[60];
            o_l   <= s_axis_tlast && !s_axis_tkeep[60];
        end
        if (in_first) tf <= enable;
        in_first <= s_axis_tlast;
    end
    if (rst) begin
        o_v      <= 1'b0;
        extra    <= 1'b0;
        in_first <= 1'b1;
        tf       <= 1'b0;
    end
end

assign m_axis_tdata  = o_d;
assign m_axis_tkeep  = o_k;
assign m_axis_tvalid = o_v;
assign m_axis_tlast  = o_l;

endmodule

`resetall
