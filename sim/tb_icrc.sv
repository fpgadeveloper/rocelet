// SPDX-License-Identifier: MIT
//
// tb_icrc - xsim testbench for the ICRC / CRC-32 blocks. Drives beats from a
// file with random input gaps and random output back-pressure, logs the output.
//   MODE 0: rocelet_icrc_tx        (out.txt: frames with ICRC appended)
//   MODE 1: rocelet_icrc_rx PASS=1 (out.txt: frames + tuser verdict)
//   MODE 2: rocelet_icrc_rx PASS=0 (out.txt: one verdict per line)
// Plusargs: +in=<file> +out=<file> +seed=<n> +gap=<0..100 %> +bp=<0..100 %>
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_icrc #(
    parameter int MODE = 0,
    parameter int GRAN = 4,
    parameter int REM  = 2,
    parameter int OFF_MODE = 0,
    parameter bit SHARE = 1'b0
);

logic clk = 1'b0, rst = 1'b1;
always #1.551 clk = ~clk;

logic [511:0] s_tdata = '0;
logic [63:0]  s_tkeep = '0;
logic         s_tvalid = 1'b0, s_tlast = 1'b0;
logic [5:0]   l3_off = 6'd14;
wire  logic   s_tready;
wire  logic [511:0] m_tdata;
wire  logic [63:0]  m_tkeep;
wire  logic         m_tvalid, m_tlast, m_tuser;
logic               m_tready = 1'b0;
wire  logic         v_valid, v_ok;
wire  logic         c_valid;
wire  logic [31:0]  c_crc;

if (MODE == 0) begin : g_tx
    rocelet_icrc_tx #(.GRAN(GRAN), .REM(REM), .OFF_MODE(OFF_MODE), .CRC_SHARE(SHARE)) dut (
        .clk(clk), .rst(rst), .l3_off(l3_off),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast));
    assign m_tuser = 1'b0;
    assign v_valid = 1'b0; assign v_ok = 1'b0; assign c_valid = 1'b0; assign c_crc = '0;
end else if (MODE == 1 || MODE == 2) begin : g_rx
    rocelet_icrc_rx #(.GRAN(GRAN), .REM(REM), .PASS_DATA(MODE == 1), .OFF_MODE(OFF_MODE), .CRC_SHARE(SHARE)) dut (
        .clk(clk), .rst(rst), .l3_off(l3_off),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .m_verdict_valid(v_valid), .m_verdict_ok(v_ok));
    assign c_valid = 1'b0; assign c_crc = '0;
end else begin : g_none
    assign m_tdata = '0; assign m_tkeep = '0; assign m_tvalid = 1'b0; assign m_tlast = 1'b0;
    assign s_tready = 1'b1; assign m_tuser = 1'b0; assign v_valid = 1'b0; assign v_ok = 1'b0;
    assign c_valid = 1'b0; assign c_crc = '0;
end

string  fin, fout;
integer fdi, fdo, seed, gap, bp;
int     nin = 0, nout = 0, nframes_in = 0, nframes_out = 0;
bit     in_done = 1'b0;

function automatic int urand100();
    return $urandom_range(99, 0);
endfunction

// ------------- input driver -------------
logic [511:0] rd_data;
integer rd_last, rd_n, r, rd_off;
initial begin
    if (!$value$plusargs("in=%s", fin)) fin = "in.txt";
    if (!$value$plusargs("out=%s", fout)) fout = "out.txt";
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("gap=%d", gap)) gap = 20;
    if (!$value$plusargs("bp=%d", bp)) bp = 20;
    r = $urandom(seed);
    fdi = $fopen(fin, "r");
    fdo = $fopen(fout, "w");
    if (fdi == 0 || fdo == 0) $fatal(1, "cannot open files");
    repeat (8) @(posedge clk);
    rst <= 1'b0;
    repeat (4) @(posedge clk);
    while (!$feof(fdi)) begin
        if (OFF_MODE == 2) begin
            r = $fscanf(fdi, "%d %d %h %d\n", rd_last, rd_n, rd_data, rd_off);
            if (r != 4) break;
        end else begin
            r = $fscanf(fdi, "%d %d %h\n", rd_last, rd_n, rd_data);
            if (r != 3) break;
            rd_off = 14;
        end
        // optional gap before the beat
        while (urand100() < gap) begin
            s_tvalid <= 1'b0;
            @(posedge clk);
        end
        s_tdata  <= rd_data;
        l3_off   <= rd_off;
        for (int i = 0; i < 64; i++) s_tkeep[i] <= (i < rd_n);
        s_tlast  <= rd_last[0];
        s_tvalid <= 1'b1;
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        nin++;
        if (rd_last[0]) nframes_in++;
    end
    s_tvalid <= 1'b0;
    in_done = 1'b1;
end

// ------------- output monitor -------------
function automatic int popc(input logic [63:0] k);
    int c = 0;
    for (int i = 0; i < 64; i++) c += k[i];
    return c;
endfunction

always @(posedge clk) begin
    if (!rst) m_tready <= (urand100() >= bp);
    if (m_tvalid && m_tready) begin
        $fdisplay(fdo, "%0d %0d %0128h %0d", m_tlast, popc(m_tkeep), m_tdata, m_tuser);
        nout++;
        if (m_tlast) nframes_out++;
    end
    if (v_valid && (MODE == 2 || MODE == 4)) begin
        $fdisplay(fdo, "%0d", v_ok);
        nframes_out++;
    end
    if (c_valid) begin
        $fdisplay(fdo, "%08h", c_crc);
        nframes_out++;
    end
end

// ------------- end of test -------------
int idle = 0;
always @(posedge clk) begin
    if (in_done) begin
        idle <= idle + 1;
        if (m_tvalid || nframes_out < nframes_in) idle <= 0;
        if (idle > 200 || (idle > 50 && nframes_out == nframes_in)) begin
            $display("TB_DONE beats_in=%0d beats_out=%0d frames_in=%0d frames_out=%0d", nin, nout, nframes_in, nframes_out);
            $fclose(fdo);
            $finish;
        end
    end
end

initial begin
    #50ms;
    $display("TB_TIMEOUT");
    $finish;
end

endmodule
