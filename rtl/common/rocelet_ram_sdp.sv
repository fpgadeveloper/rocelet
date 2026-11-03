// SPDX-License-Identifier: MIT
//
// rocelet_ram_sdp - inferred simple-dual-port RAM (one write port, one read port,
// same clock). RD_LAT = 1: registered read; RD_LAT >= 2 adds output pipeline
// registers (needed for block RAM output registers and URAM cascades).
// RAM_STYLE: "auto" | "distributed" | "block" | "ultra" | "registers".
// Full-word writes only (no byte enables).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_ram_sdp #(
    parameter int    WIDTH     = 64,
    parameter int    DEPTH     = 256,
    parameter int    RD_LAT    = 1,
    parameter        RAM_STYLE = "auto"
) (
    input  wire logic                     clk,
    input  wire logic                     we,
    input  wire logic [$clog2(DEPTH)-1:0] waddr,
    input  wire logic [WIDTH-1:0]         wdata,
    input  wire logic                     re,
    input  wire logic [$clog2(DEPTH)-1:0] raddr,
    output wire logic [WIDTH-1:0]         rdata
);

(* ram_style = RAM_STYLE *)
logic [WIDTH-1:0] mem [DEPTH];

logic [WIDTH-1:0] q [RD_LAT];

always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
end

always_ff @(posedge clk) begin
    if (re) q[0] <= mem[raddr];
    for (int i = 1; i < RD_LAT; i++) q[i] <= q[i-1];
end

assign rdata = q[RD_LAT-1];

endmodule

`resetall
