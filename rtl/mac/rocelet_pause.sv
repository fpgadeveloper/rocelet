// SPDX-License-Identifier: MIT
//
// rocelet_pause - 802.3x PAUSE handling next to the MAC. The MAC parses and sends the PAUSE
// frames; this block decides when the engine's TX holds and when to ask for PAUSE.
//   Received, two ways a MAC can report it:
//   * quanta (pulse or level of mac_pause_valid with mac_pause_quanta, e.g. the 100G CMAC's
//     stat_rx_pause_valid[8] / stat_rx_pause_quanta8): every valid global PAUSE loads a
//     timer with its quanta x qclk / 256 clocks (qclk = PAUSE_QCLK: one quantum = 512 bit
//     times = 5.12 ns at 100G, 12.8 ns at 40G, 51.2 ns at 10G, in clocks x 256; reset value
//     from CLK_KHZ and LINK_GBPS, rounded up). The timer loads on a rising valid or a
//     quanta change, so a pulse or a level both work; an XON (quanta 0) clears it.
//   * level (mac_pause_hold, with level_en = CTRL.PAUSE_RX_LEVEL): the MAC times the quanta
//     itself and holds the level while a received PAUSE is in force (omac's stat_rx_pause_req,
//     the CMAC's stat_rx_pause_req[8]).
//   While the timer runs or the level is held (and honour_en), `gate` is high and the TX
//   arbiter starts no new frame.
//   Sent: with req_en, mac_pause_req rises when the RX FIFO fill reaches `xoff` and falls at
//   `xon` or below, each level held for at least 32 clocks (the CMAC needs 16); the MAC
//   sends the PAUSE frames itself (quanta and refresh interval: MAC configuration, e.g.
//   0x100 quanta, refresh 0x80), and an XON when the request drops.
// The quanta x qclk product is a DSP multiply with two pipeline registers (the load is 3
// clocks after the MAC's report; irrelevant against a 512-bit-time quantum).
// Proven on hardware in both directions (100G CMAC, quanta mode) by the research prototype.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_pause #(
    parameter int FILL_W  = 10
) (
    input  wire logic              clk,
    input  wire logic              rst,

    input  wire logic              honour_en,
    input  wire logic              level_en,
    input  wire logic              req_en,
    input  wire logic [15:0]       xoff,
    input  wire logic [15:0]       xon,
    input  wire logic [19:0]       qclk,
    input  wire logic [FILL_W-1:0] fill,

    input  wire logic              mac_pause_hold,
    input  wire logic              mac_pause_valid,
    input  wire logic [15:0]       mac_pause_quanta,
    output wire logic              mac_pause_req,

    output logic                   gate = 1'b0,
    output logic                   req = 1'b0,
    output logic [15:0]            last_quanta = '0,
    output logic                   ev_load = 1'b0,
    output logic                   ev_xoff = 1'b0
);

logic        v = 1'b0, v_d = 1'b0, lvl = 1'b0, lvl_d = 1'b0, ld1 = 1'b0, ld2 = 1'b0;
logic [15:0] q = '0, q_d = '0, q1 = '0, q2 = '0;
logic [19:0] qc = '0;
(* use_dsp = "yes" *) logic [35:0] p1 = '0, p2 = '0;
logic [27:0] timer = '0;
logic [5:0]  hold = '0;
always_ff @(posedge clk) begin
    v     <= mac_pause_valid;
    q     <= mac_pause_quanta;
    lvl   <= mac_pause_hold;
    qc    <= qclk;
    v_d   <= v;
    q_d   <= q;
    lvl_d <= lvl;
    // load request, then quanta x clocks per quantum (two pipeline stages)
    ld1 <= v && (!v_d || q != q_d);
    q1  <= q;
    p1  <= 36'(q) * 36'(qc);
    ld2 <= ld1;
    q2  <= q1;
    p2  <= p1;
    ev_load <= level_en && lvl && !lvl_d;
    if (ld2) begin
        timer       <= p2[35:8];
        last_quanta <= q2;
        ev_load     <= 1'b1;
    end else if (timer != '0) begin
        timer <= timer - 28'd1;
    end
    gate <= honour_en && ((timer != '0) || (level_en && lvl));
    // requests from the RX FIFO level
    ev_xoff <= 1'b0;
    if (hold != '0) hold <= hold - 6'd1;
    else if (!req && req_en && 16'(fill) >= xoff) begin
        req     <= 1'b1;
        hold    <= 6'd32;
        ev_xoff <= 1'b1;
    end else if (req && (!req_en || 16'(fill) <= xon)) begin
        req  <= 1'b0;
        hold <= 6'd32;
    end
    if (rst) begin
        timer <= '0;
        gate  <= 1'b0;
        req   <= 1'b0;
        hold  <= '0;
        ld1   <= 1'b0;
        ld2   <= 1'b0;
        last_quanta <= '0;
    end
end
assign mac_pause_req = req;

endmodule

`resetall
