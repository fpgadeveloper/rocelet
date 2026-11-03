// SPDX-License-Identifier: MIT
//
// rocelet_pause - 802.3x PAUSE handling next to a 100G CMAC.
//   Received: every valid global PAUSE (CMAC stat_rx_pause_valid[8], with
//   stat_rx_pause_quanta8) loads a timer with its quanta (1 quantum = 512 bit times =
//   5.12 ns at 100G = 1.65 clocks at 322 MHz; the factor follows CLK_MHZ and errs on the
//   long side); while it runs (or, with level_en, while the CMAC holds
//   stat_rx_pause_req[8]) `gate` is high and the TX arbiter starts no new frame. The
//   timer loads on a rising valid or a quanta change, so a pulse or a level from the
//   CMAC both work; an XON (quanta 0) clears it.
//   Sent: with req_en, ctl_tx_pause_req[8] rises when the RX FIFO fill reaches `xoff` and
//   falls at `xon` or below, each level held for at least 32 clocks (the CMAC needs 16);
//   the CMAC sends the PAUSE frames itself (quanta and refresh interval: CMAC
//   configuration, e.g. 0x100 quanta, refresh 0x80), and an XON when the request drops.
// Proven on hardware in both directions by the research prototype.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

(* use_dsp = "no" *)
module rocelet_pause #(
    parameter int CLK_MHZ = 322,
    parameter int FILL_W  = 10
) (
    input  wire logic              clk,
    input  wire logic              rst,

    input  wire logic              honour_en,
    input  wire logic              level_en,
    input  wire logic              req_en,
    input  wire logic [15:0]       xoff,
    input  wire logic [15:0]       xon,
    input  wire logic [FILL_W-1:0] fill,

    input  wire logic [8:0]        stat_rx_pause_req,
    input  wire logic [8:0]        stat_rx_pause_valid,
    input  wire logic [15:0]       stat_rx_pause_quanta8,
    output wire logic [8:0]        ctl_tx_pause_req,

    output logic                   gate,
    output logic                   req,
    output logic [15:0]            last_quanta,
    output logic                   ev_load,
    output logic                   ev_xoff
);

// clocks per quantum x 256 (5.12 ns x CLK_MHZ x 256 / 1000), rounded up
localparam int QMUL = (CLK_MHZ * 131072 + 99999) / 100000;

logic        v = 1'b0, v_d = 1'b0, req8 = 1'b0;
logic [15:0] q = '0, q_d = '0;
logic [25:0] timer = '0;
logic [5:0]  hold = '0;
always_ff @(posedge clk) begin
    v       <= stat_rx_pause_valid[8];
    q       <= stat_rx_pause_quanta8;
    req8    <= stat_rx_pause_req[8];
    v_d     <= v;
    q_d     <= q;
    ev_load <= 1'b0;
    if (v && (!v_d || q != q_d)) begin
        timer       <= (26'(q) * 26'(QMUL)) >> 8;
        last_quanta <= q;
        ev_load     <= 1'b1;
    end else if (timer != '0) begin
        timer <= timer - 26'd1;
    end
    gate <= honour_en && ((timer != '0) || (level_en && req8));
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
        last_quanta <= '0;
    end
end
assign ctl_tx_pause_req = {req, 8'd0};

endmodule

`resetall
