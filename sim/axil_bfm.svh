// SPDX-License-Identifier: MIT
//
// axil_bfm.svh - AXI4-Lite master tasks for the rocelet testbenches. Include inside a module
// that declares, for a prefix P (macro argument): P_awaddr, P_awvalid, P_awready, P_wdata,
// P_wstrb, P_wvalid, P_wready, P_bvalid, P_bready, P_araddr, P_arvalid, P_arready, P_rdata,
// P_rvalid, P_rready and a clock `clk`.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`define AXIL_BFM(P) \
task automatic P``_write(input logic [15:0] a, input logic [31:0] d); \
    P``_awaddr <= a; P``_awvalid <= 1'b1; P``_wdata <= d; P``_wstrb <= 4'hF; P``_wvalid <= 1'b1; \
    P``_bready <= 1'b1; \
    fork \
        begin @(posedge clk); while (!P``_awready) @(posedge clk); P``_awvalid <= 1'b0; end \
        begin @(posedge clk); while (!P``_wready) @(posedge clk); P``_wvalid <= 1'b0; end \
    join \
    while (!P``_bvalid) @(posedge clk); \
    @(posedge clk); \
    P``_bready <= 1'b0; \
endtask \
task automatic P``_read(input logic [15:0] a, output logic [31:0] d); \
    P``_araddr <= a; P``_arvalid <= 1'b1; P``_rready <= 1'b1; \
    @(posedge clk); while (!P``_arready) @(posedge clk); P``_arvalid <= 1'b0; \
    while (!P``_rvalid) @(posedge clk); \
    d = P``_rdata; \
    @(posedge clk); \
    P``_rready <= 1'b0; \
endtask
