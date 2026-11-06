// SPDX-License-Identifier: MIT
//
// rocelet_mac_arb - frame-atomic N-input arbiter in front of the MAC TX:
// fixed priority, lowest input index first (control traffic: ARP/ICMP replies and
// the other-traffic port before the engine), switching only at frame boundaries. Inputs must
// be store-and-forward (no pause inside a frame); the output is registered.
// hold (802.3x PAUSE received): no new frame starts; a frame in progress ends.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_mac_arb #(
    parameter int N = 3
) (
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic          hold,

    input  wire logic [511:0]  s_tdata  [N],
    input  wire logic [63:0]   s_tkeep  [N],
    input  wire logic [N-1:0]  s_tvalid,
    output logic      [N-1:0]  s_tready,
    input  wire logic [N-1:0]  s_tlast,

    output logic      [511:0]  m_tdata,
    output logic      [63:0]   m_tkeep,
    output logic               m_tvalid,
    input  wire logic          m_tready,
    output logic               m_tlast,
    output logic      [N-1:0]  m_src        // source of the beat on the output
);

logic         lock = 1'b0;
logic [$clog2(N > 1 ? N : 2)-1:0] cur, pick;
logic         any;
always_comb begin
    any  = 1'b0;
    pick = '0;
    for (int i = N - 1; i >= 0; i--) if (s_tvalid[i]) begin any = 1'b1; pick = i; end
end
wire logic [$clog2(N > 1 ? N : 2)-1:0] sel = lock ? cur : pick;
wire logic slot = !m_tvalid || m_tready;
wire logic go   = slot && (lock ? s_tvalid[cur] : (any && !hold));

always_comb begin
    s_tready = '0;
    s_tready[sel] = go;
end

always_ff @(posedge clk) begin
    if (m_tready) m_tvalid <= 1'b0;
    if (go) begin
        m_tvalid <= 1'b1;
        m_tdata  <= s_tdata[sel];
        m_tkeep  <= s_tkeep[sel];
        m_tlast  <= s_tlast[sel];
        m_src    <= N'(1) << sel;
        lock     <= !s_tlast[sel];
        cur      <= sel;
    end
    if (rst) begin
        m_tvalid <= 1'b0;
        lock     <= 1'b0;
    end
end

endmodule

`resetall
