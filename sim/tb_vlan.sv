// SPDX-License-Identifier: MIT
//
// tb_vlan - unit test of rocelet_vlan_ins -> rocelet_vlan_strip: random frames of
// 14..600 bytes, random input gaps and output back-pressure on both stages.
//   * frames tagged by the inserter with VID 0 must come out of the stripper
//     byte-identical to the input;
//   * frames tagged with VID != 0 must pass the stripper unchanged (tagged);
//   * untagged frames (inserter off) must pass both unchanged;
//   * the inserter's output (between the two) is checked against the expected
//     tagged frame byte by byte.
// run: sim/test_vlan.py
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_vlan;

logic clk = 1'b0;
always #1.5 clk = ~clk;
logic rst = 1'b1;

localparam int NFR = 3000;
localparam int MAXB = 640;

// frame plan
int          f_len [NFR];
bit          f_tag [NFR];
logic [15:0] f_tci [NFR];
logic [7:0]  f_b   [NFR][MAXB];

// source
logic [511:0] s_d;
logic [63:0]  s_k;
logic         s_v = 1'b0, s_l;
wire  logic   s_r;
// inserter -> stripper
wire  logic [511:0] m_d, o_d;
wire  logic [63:0]  m_k, o_k;
wire  logic         m_v, m_l, o_v, o_l;
logic               m_r_rnd, o_r = 1'b0;
wire  logic         m_r;
logic         ins_en = 1'b0;
logic [15:0]  ins_tci = '0;
logic         ev_tag, ev_strip, ev_tagged;
logic [15:0]  last_tci;

rocelet_vlan_ins u_ins (
    .clk(clk), .rst(rst), .enable(ins_en), .tci(ins_tci),
    .s_axis_tdata(s_d), .s_axis_tkeep(s_k), .s_axis_tvalid(s_v), .s_axis_tready(s_r), .s_axis_tlast(s_l),
    .m_axis_tdata(m_d), .m_axis_tkeep(m_k), .m_axis_tvalid(m_v), .m_axis_tready(m_r), .m_axis_tlast(m_l),
    .ev_tag(ev_tag)
);
rocelet_vlan_strip u_strip (
    .clk(clk), .rst(rst), .enable(1'b1),
    .s_axis_tdata(m_d), .s_axis_tkeep(m_k), .s_axis_tvalid(m_v), .s_axis_tready(m_r), .s_axis_tlast(m_l),
    .m_axis_tdata(o_d), .m_axis_tkeep(o_k), .m_axis_tvalid(o_v), .m_axis_tready(o_r), .m_axis_tlast(o_l),
    .ev_strip(ev_strip), .ev_tagged(ev_tagged), .last_tci(last_tci)
);

int errors = 0;
int n_strip = 0, n_tagged = 0, n_ins = 0;
always @(posedge clk) begin
    if (ev_strip) n_strip++;
    if (ev_tagged) n_tagged++;
    if (ev_tag) n_ins++;
end

// random back-pressure
always_ff @(posedge clk) o_r <= ($urandom % 4) != 0;

// ---- source: frame by frame, the inserter enable/TCI set per frame before its first beat
initial begin
    for (int f = 0; f < NFR; f++) begin
        int r = $urandom % 10;
        f_len[f] = 14 + ($urandom % 587);
        if (f % 7 == 0) f_len[f] = 14 + ($urandom % 3) + 64 * ($urandom % 9) + 46;   // ends near a beat boundary
        f_tag[f] = (r < 7);
        f_tci[f] = (r < 5) ? {3'($urandom), 1'b0, 12'd0} : {3'($urandom), 1'b0, 12'(1 + $urandom % 4000)};
        for (int i = 0; i < MAXB; i++) f_b[f][i] = 8'($urandom);
    end
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (5) @(posedge clk);
    for (int f = 0; f < NFR; f++) begin
        int nb = (f_len[f] + 63) / 64;
        for (int bt = 0; bt < nb; bt++) begin
            while (($urandom % 3) == 0) @(posedge clk);         // input gaps
            for (int j = 0; j < 64; j++) begin
                s_d[8*j +: 8] <= (64*bt + j < f_len[f]) ? f_b[f][64*bt + j] : 8'hEE;
                s_k[j]        <= (64*bt + j < f_len[f]);
            end
            s_l <= (bt == nb - 1);
            s_v <= 1'b1;
            if (bt == 0) begin ins_en <= f_tag[f]; ins_tci <= f_tci[f]; end
            do @(posedge clk); while (!s_r);
            s_v <= 1'b0;
        end
    end
end

// ---- inserter output check
int mf = 0, mpos = 0;
logic [7:0] mexp [MAXB + 8];
int mexp_len;
task automatic build_m(input int f);
    if (!f_tag[f]) begin
        for (int i = 0; i < f_len[f]; i++) mexp[i] = f_b[f][i];
        mexp_len = f_len[f];
    end else begin
        for (int i = 0; i < 12; i++) mexp[i] = f_b[f][i];
        mexp[12] = 8'h81; mexp[13] = 8'h00; mexp[14] = f_tci[f][15:8]; mexp[15] = f_tci[f][7:0];
        for (int i = 12; i < f_len[f]; i++) mexp[i + 4] = f_b[f][i];
        mexp_len = f_len[f] + 4;
    end
endtask
always @(posedge clk) if (!rst && m_v && m_r) begin
    if (mpos == 0) build_m(mf);
    for (int j = 0; j < 64; j++) begin
        bit want = (mpos + j < mexp_len);
        if (m_k[j] != want) begin
            if (errors < 20) $display("TB_ERROR ins frame %0d beat@%0d keep[%0d] %0d want %0d (len %0d tag %0d)", mf, mpos, j, m_k[j], want, mexp_len, f_tag[mf]);
            errors++;
        end else if (want && m_d[8*j +: 8] != mexp[mpos + j]) begin
            if (errors < 20) $display("TB_ERROR ins frame %0d byte %0d = %h want %h", mf, mpos + j, m_d[8*j +: 8], mexp[mpos + j]);
            errors++;
        end
    end
    if (m_l != (mpos + 64 >= mexp_len)) begin
        if (errors < 20) $display("TB_ERROR ins frame %0d last %0d at %0d (len %0d)", mf, m_l, mpos, mexp_len);
        errors++;
    end
    if (m_l) begin mf++; mpos = 0; end else mpos += 64;
end

// ---- stripper output check: VID-0 tagged frames come back untagged, others as they went in
int of = 0, opos = 0;
logic [7:0] oexp [MAXB + 8];
int oexp_len;
task automatic build_o(input int f);
    if (f_tag[f] && f_tci[f][11:0] != 0) begin
        for (int i = 0; i < 12; i++) oexp[i] = f_b[f][i];
        oexp[12] = 8'h81; oexp[13] = 8'h00; oexp[14] = f_tci[f][15:8]; oexp[15] = f_tci[f][7:0];
        for (int i = 12; i < f_len[f]; i++) oexp[i + 4] = f_b[f][i];
        oexp_len = f_len[f] + 4;
    end else begin
        for (int i = 0; i < f_len[f]; i++) oexp[i] = f_b[f][i];
        oexp_len = f_len[f];
    end
endtask
always @(posedge clk) if (!rst && o_v && o_r) begin
    if (opos == 0) build_o(of);
    for (int j = 0; j < 64; j++) begin
        bit want = (opos + j < oexp_len);
        if (o_k[j] != want) begin
            if (errors < 20) $display("TB_ERROR strip frame %0d beat@%0d keep[%0d] %0d want %0d (len %0d tag %0d tci %h)", of, opos, j, o_k[j], want, oexp_len, f_tag[of], f_tci[of]);
            errors++;
        end else if (want && o_d[8*j +: 8] != oexp[opos + j]) begin
            if (errors < 20) $display("TB_ERROR strip frame %0d byte %0d = %h want %h", of, opos + j, o_d[8*j +: 8], oexp[opos + j]);
            errors++;
        end
    end
    if (o_l != (opos + 64 >= oexp_len)) begin
        if (errors < 20) $display("TB_ERROR strip frame %0d last %0d at %0d (len %0d)", of, o_l, opos, oexp_len);
        errors++;
    end
    if (o_l) begin of++; opos = 0; end else opos += 64;
end

initial begin
    int vid0 = 0, vidn = 0;
    wait (of == NFR);
    repeat (10) @(posedge clk);
    for (int f = 0; f < NFR; f++) if (f_tag[f]) begin if (f_tci[f][11:0] == 0) vid0++; else vidn++; end
    $display("TB_INFO frames %0d: tagged by the inserter %0d (VID 0: %0d, VID != 0: %0d), stripped %0d, passed tagged %0d",
             NFR, n_ins, vid0, vidn, n_strip, n_tagged);
    if (n_strip != vid0) begin $display("FAIL stripped count"); errors++; end
    if (n_tagged != vidn) begin $display("FAIL passed-tagged count"); errors++; end
    if (n_ins != vid0 + vidn) begin $display("FAIL inserted count"); errors++; end
    $display("TB_DONE errors=%0d", errors);
    if (errors == 0) $display("SIM PASS"); else $display("SIM FAIL");
    $finish;
end
initial begin #50ms; $display("TB_TIMEOUT frames out %0d", of); $finish; end

endmodule
