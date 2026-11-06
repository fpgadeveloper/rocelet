// SPDX-License-Identifier: MIT
//
// rocelet_mac_width - AXI-Stream width converters between a narrow MAC (MAC_W = 64, 128 or
// 256 bits) and the 512-bit engine, in ONE clock (the MAC user clock, which is also the
// engine clock). rocelet_top instantiates them when MAC_WIDTH < 512; at 512 the MAC ports
// connect straight through.
//
//   rocelet_rx_upsize    MAC RX (no tready, tvalid gaps allowed) -> 512-bit beats
//                        (no tready, tvalid gaps: the RX FIFO takes a beat whenever it comes)
//   rocelet_tx_downsize  512-bit engine TX -> MAC TX (tready from the MAC)
//
// RX: R = 512 / MAC_W MAC beats are packed into one 512-bit beat, sub-beat i in bytes
// [i*MAC_W/8 +: MAC_W/8]. A frame always starts in lane 0 of a fresh 512-bit beat: the
// packer emits on the frame's last MAC beat (tlast) or when the 512-bit beat is full, so
// the output tkeep is contiguous from bit 0 (lanes after the last valid byte are 0, and
// so is their data). The MAC's tkeep is used as is: every MAC beat but the last of a frame
// must be full (contiguous tkeep from bit 0 on the last one), as the MAC AXI-Stream
// convention requires. tuser (bad frame: FCS or PCS error) is OR-ed over the whole frame
// and given on the output's last beat, where the RX FIFO evaluates it. abort (the MAC's RX
// reset) drops a partly packed beat; the RX FIFO rolls the frame back itself. Latency: one
// clock after the MAC beat that completes the 512-bit beat.
//
// TX: one 512-bit beat is held and shifted out MAC_W bits per MAC beat; sub-beats after
// the last valid byte of a frame's last beat are skipped, so a frame ends on the MAC beat
// that holds its last byte. s_tready rises on the beat's last needed sub-beat (when the
// MAC takes it) or while the holding register is empty, so the next beat is loaded in
// the same clock: when the engine side presents a frame without gaps (it does: the TX
// FIFO is store-and-forward and the arbiter frame-atomic) the MAC sees no gap inside a
// frame. ev_gap flags a clock with tvalid low inside a frame on the MAC side (counted in
// CNT_TX_UNDERRUN together with the 512-bit side; must stay 0).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_rx_upsize #(
    parameter int MAC_W = 256,
    localparam int KB = MAC_W / 8,
    localparam int R  = 512 / MAC_W
) (
    input  wire logic             clk,
    input  wire logic             rst,
    input  wire logic             abort,

    input  wire logic [MAC_W-1:0] s_tdata,
    input  wire logic [KB-1:0]    s_tkeep,
    input  wire logic             s_tvalid,
    input  wire logic             s_tlast,
    input  wire logic             s_tuser,

    output logic      [511:0]     m_tdata = '0,
    output logic      [63:0]      m_tkeep = '0,
    output logic                  m_tvalid = 1'b0,
    output logic                  m_tlast = 1'b0,
    output logic                  m_tuser = 1'b0
);

if (R < 2 || R * MAC_W != 512) begin : g_bad
    $error("rocelet_rx_upsize: MAC_W must be 64, 128 or 256");
end

localparam int IW = $clog2(R);

logic [IW-1:0] idx = '0;
logic          err = 1'b0;      // a bad-frame flag seen earlier in this frame

always_ff @(posedge clk) begin
    m_tvalid <= 1'b0;
    if (s_tvalid) begin
        for (int i = 0; i < R; i++) begin
            if (IW'(i) == idx) begin
                m_tdata[i*MAC_W +: MAC_W] <= s_tdata;
                m_tkeep[i*KB +: KB]       <= s_tkeep;
            end else if (idx == '0) begin
                // a new 512-bit beat: the lanes above the first sub-beat start empty
                m_tdata[i*MAC_W +: MAC_W] <= '0;
                m_tkeep[i*KB +: KB]       <= '0;
            end
        end
        if (s_tlast || idx == IW'(R - 1)) begin
            m_tvalid <= 1'b1;
            m_tlast  <= s_tlast;
            m_tuser  <= s_tlast && (err || s_tuser);
            idx      <= '0;
        end else begin
            idx <= idx + IW'(1);
        end
        err <= s_tlast ? 1'b0 : (err || s_tuser);
    end
    if (rst || abort) begin
        m_tvalid <= 1'b0;
        idx      <= '0;
        err      <= 1'b0;
    end
end

endmodule


module rocelet_tx_downsize #(
    parameter int MAC_W = 256,
    localparam int KB = MAC_W / 8,
    localparam int R  = 512 / MAC_W
) (
    input  wire logic             clk,
    input  wire logic             rst,

    input  wire logic [511:0]     s_tdata,
    input  wire logic [63:0]      s_tkeep,
    input  wire logic             s_tvalid,
    output wire logic             s_tready,
    input  wire logic             s_tlast,

    output wire logic [MAC_W-1:0] m_tdata,
    output wire logic [KB-1:0]    m_tkeep,
    output wire logic             m_tvalid,
    input  wire logic             m_tready,
    output wire logic             m_tlast,

    output logic                  ev_gap = 1'b0
);

if (R < 2 || R * MAC_W != 512) begin : g_bad
    $error("rocelet_tx_downsize: MAC_W must be 64, 128 or 256");
end

localparam int IW = $clog2(R);

logic [511:0]  sh_d;            // the held beat, current sub-beat in the low MAC_W bits
logic [63:0]   sh_k;
logic          sh_v = 1'b0, sh_l = 1'b0;
logic [IW-1:0] idx = '0;
logic          in_frame = 1'b0; // MAC side: a frame started and its last beat not yet taken

// the current sub-beat is the last one of the held beat: the top sub-beat, or the next
// sub-beat holds no byte (tkeep is contiguous)
wire logic last_sub = (idx == IW'(R - 1)) || !sh_k[KB];

assign m_tdata  = sh_d[MAC_W-1:0];
assign m_tkeep  = sh_k[KB-1:0];
assign m_tvalid = sh_v;
assign m_tlast  = sh_l && last_sub;
assign s_tready = !sh_v || (m_tready && last_sub);

always_ff @(posedge clk) begin
    if (s_tvalid && s_tready) begin
        sh_d <= s_tdata;
        sh_k <= s_tkeep;
        sh_l <= s_tlast;
        sh_v <= 1'b1;
        idx  <= '0;
    end else if (sh_v && m_tready) begin
        if (last_sub) begin
            sh_v <= 1'b0;
        end else begin
            sh_d <= {MAC_W'(0), sh_d[511:MAC_W]};
            sh_k <= {KB'(0), sh_k[63:KB]};
            idx  <= idx + IW'(1);
        end
    end
    if (sh_v && m_tready) in_frame <= !m_tlast;
    ev_gap <= in_frame && !sh_v;
    if (rst) begin
        sh_v     <= 1'b0;
        idx      <= '0;
        in_frame <= 1'b0;
        ev_gap   <= 1'b0;
    end
end

endmodule

`resetall
