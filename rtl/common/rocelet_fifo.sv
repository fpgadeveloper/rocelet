// SPDX-License-Identifier: MIT
//
// rocelet_fifo - synchronous first-word-fall-through FIFO.
//   RAM_STYLE "distributed" / "registers": asynchronous-read array, dout is
//   mem[rd_ptr] (LUTRAM or FFs).
//   RAM_STYLE "block" / "ultra": synchronous-read RAM plus a 2-entry output
//   prefetch so dout stays first-word-fall-through.
// DEPTH must be a power of two. count is the number of words held (incl. the
// prefetch stage). No reset of the array.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_fifo #(
    parameter int    WIDTH     = 32,
    parameter int    DEPTH     = 16,
    parameter        RAM_STYLE = "distributed"
) (
    input  wire logic             clk,
    input  wire logic             rst,

    input  wire logic [WIDTH-1:0] din,
    input  wire logic             wr_en,
    output wire logic             full,

    output wire logic [WIDTH-1:0] dout,
    output wire logic             valid,      // dout holds a word
    input  wire logic             rd_en,      // pop (only when valid)

    output wire logic [$clog2(DEPTH):0] count
);

localparam int AW = $clog2(DEPTH);
localparam bit SYNC_RD = (RAM_STYLE == "block") || (RAM_STYLE == "ultra");

logic [AW:0] wr_ptr = '0;
logic [AW:0] rd_ptr = '0;

if (!SYNC_RD) begin : g_async
    (* ram_style = RAM_STYLE *)
    logic [WIDTH-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (wr_en && !full) mem[wr_ptr[AW-1:0]] <= din;
    end

    assign dout  = mem[rd_ptr[AW-1:0]];
    assign valid = (wr_ptr != rd_ptr);
    assign full  = (wr_ptr == {~rd_ptr[AW], rd_ptr[AW-1:0]});
    assign count = wr_ptr - rd_ptr;

    always_ff @(posedge clk) begin
        if (wr_en && !full) wr_ptr <= wr_ptr + 1'b1;
        if (rd_en && valid) rd_ptr <= rd_ptr + 1'b1;
        if (rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end
    end
end else begin : g_sync
    (* ram_style = RAM_STYLE *)
    logic [WIDTH-1:0] mem [DEPTH];
    logic [WIDTH-1:0] rd_data;

    // prefetch: RAM read issued when the output stage (2 regs) has room
    logic [WIDTH-1:0] q0, q1;     // q0 = head
    logic q0_v = 1'b0, q1_v = 1'b0;
    logic rd_pend = 1'b0;          // a RAM read is in flight (data in rd_data next cycle)
    wire  ram_empty = (wr_ptr == rd_ptr);
    wire  pop = rd_en && q0_v;
    // occupancy of the output stage after this cycle, counting the in-flight read
    wire [1:0] out_cnt = q0_v + q1_v + rd_pend - pop;
    wire  issue = !ram_empty && (out_cnt < 2);

    always_ff @(posedge clk) begin
        if (wr_en && !full) mem[wr_ptr[AW-1:0]] <= din;
        if (issue) rd_data <= mem[rd_ptr[AW-1:0]];
    end

    always_ff @(posedge clk) begin
        if (wr_en && !full) wr_ptr <= wr_ptr + 1'b1;
        if (issue) rd_ptr <= rd_ptr + 1'b1;
        rd_pend <= issue;
        // output stage
        if (pop) begin
            q0 <= q1; q0_v <= q1_v; q1_v <= 1'b0;
            if (rd_pend) begin
                if (q1_v) begin q1 <= rd_data; q1_v <= 1'b1; end
                else begin q0 <= rd_data; q0_v <= 1'b1; end
            end
        end else if (rd_pend) begin
            if (!q0_v) begin q0 <= rd_data; q0_v <= 1'b1; end
            else begin q1 <= rd_data; q1_v <= 1'b1; end
        end
        if (rst) begin
            wr_ptr <= '0; rd_ptr <= '0; rd_pend <= 1'b0; q0_v <= 1'b0; q1_v <= 1'b0;
        end
    end

    assign dout  = q0;
    assign valid = q0_v;
    assign full  = (wr_ptr == {~rd_ptr[AW], rd_ptr[AW-1:0]});
    assign count = (wr_ptr - rd_ptr) + q0_v + q1_v + rd_pend;
end

endmodule

`resetall
