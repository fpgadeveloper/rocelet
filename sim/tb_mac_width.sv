// SPDX-License-Identifier: MIT
//
// tb_mac_width - self-checking unit test of the MAC width converters (rocelet_mac_width.sv)
// at MAC_W = 64, 128 or 256:
//   RX (rocelet_rx_upsize): +nf= random frames of 1-600 bytes from a MAC model with random
//     tvalid gaps inside and between frames (+gap= per cent), partial last beats, the
//     bad-frame flag on the last beat or on an earlier beat (must reach the 512-bit last
//     beat); every 512-bit beat checked: contiguous tkeep from lane 0, full unless last,
//     frame bytes and the flag exact; an abort in the middle of a frame drops the partial
//     beat (the following frame is exact).
//   TX (rocelet_tx_downsize): random frames as 512-bit beats from a store-and-forward
//     source (no gap inside a frame, random gaps between frames) into a MAC with random
//     tready (+bp= per cent): bytes, contiguous tkeep, full non-last beats, tlast, no
//     tvalid gap inside a frame on the MAC side, ev_gap never; then a back-to-back phase
//     with tready held high: the MAC side must be busy every clock (full rate, no bubble
//     between 512-bit beats or frames).
// Prints TB_DONE ... or TB_ERROR lines.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_mac_width #(
    parameter int MAC_W = 64
);
localparam int KB = MAC_W / 8;

logic clk = 1'b0, rst = 1'b1;
always #2 clk = ~clk;

integer seed, nf, gap, bp, r;
int     nerr = 0;
function automatic int urand100();
    return $urandom_range(99, 0);
endfunction
task automatic err(input string s);
    nerr++;
    if (nerr < 20) $display("TB_ERROR %s", s);
endtask

// ================= RX =================
logic [MAC_W-1:0] rx_d = '0;
logic [KB-1:0]    rx_k = '0;
logic             rx_v = 1'b0, rx_l = 1'b0, rx_u = 1'b0, rx_abort = 1'b0;
wire  logic [511:0] up_d;
wire  logic [63:0]  up_k;
wire  logic         up_v, up_l, up_u;

rocelet_rx_upsize #(.MAC_W(MAC_W)) u_up (
    .clk(clk), .rst(rst), .abort(rx_abort),
    .s_tdata(rx_d), .s_tkeep(rx_k), .s_tvalid(rx_v), .s_tlast(rx_l), .s_tuser(rx_u),
    .m_tdata(up_d), .m_tkeep(up_k), .m_tvalid(up_v), .m_tlast(up_l), .m_tuser(up_u)
);

byte unsigned rx_exp [$][$];
bit           rx_bad [$];
int           rx_frames = 0, rx_badn = 0, rx_beats512 = 0;
bit           rx_done = 0;

function automatic int keep_n(input logic [63:0] k, output bit contig);
    int n = 0;
    contig = 1;
    for (int i = 0; i < 64; i++) begin
        if (k[i]) begin
            if (n != i) contig = 0;
            n++;
        end
    end
    return n;
endfunction

initial begin
    byte unsigned fr [$];
    int len, nb;
    bit bad, early;
    wait (!rst);
    repeat (4) @(posedge clk);
    for (int f = 0; f < nf; f++) begin
        len = (urand100() < 20) ? $urandom_range(KB, 1) : $urandom_range(600, 1);
        fr = {};
        for (int i = 0; i < len; i++) fr.push_back(8'($urandom));
        bad = (urand100() < 10);
        early = bad && (urand100() < 50) && len > KB;
        // frame 7: aborted in its middle (the MAC's RX reset): not expected at the output
        if (f == 7 && len > 2 * KB) begin
            for (int b = 0; b < 1; b++) begin
                for (int j = 0; j < KB; j++) rx_d[j*8 +: 8] <= fr[b * KB + j];
                rx_k <= '1; rx_l <= 1'b0; rx_u <= 1'b0; rx_v <= 1'b1;
                @(posedge clk);
            end
            rx_v <= 1'b0; rx_abort <= 1'b1;
            @(posedge clk);
            rx_abort <= 1'b0;
            @(posedge clk);
            continue;
        end
        rx_exp.push_back(fr);
        rx_bad.push_back(bad);
        nb = (len + KB - 1) / KB;
        for (int b = 0; b < nb; b++) begin
            while (urand100() < gap) begin rx_v <= 1'b0; @(posedge clk); end
            rx_d <= '0; rx_k <= '0;
            for (int j = 0; j < KB && b * KB + j < len; j++) begin
                rx_d[j*8 +: 8] <= fr[b * KB + j];
                rx_k[j] <= 1'b1;
            end
            rx_l <= (b == nb - 1);
            rx_u <= early ? (b == 0) : (bad && b == nb - 1);
            rx_v <= 1'b1;
            @(posedge clk);
        end
        rx_v <= 1'b0; rx_l <= 1'b0; rx_u <= 1'b0;
        while (urand100() < gap) @(posedge clk);
    end
    rx_v <= 1'b0;
    repeat (20) @(posedge clk);
    rx_done = 1;
end

byte unsigned rx_cur [$];
always @(posedge clk) begin
    if (up_v) begin
        bit c;
        int n;
        n = keep_n(up_k, c);
        rx_beats512++;
        if (!c || n == 0) err($sformatf("RX: tkeep %h not contiguous from lane 0", up_k));
        if (!up_l && n != 64) err($sformatf("RX: non-last 512-bit beat with %0d bytes", n));
        for (int i = 0; i < n; i++) rx_cur.push_back(up_d[i*8 +: 8]);
        for (int i = n; i < 64; i++) if (up_d[i*8 +: 8] != 0) begin err("RX: data beyond tkeep not 0"); break; end
        if (up_l) begin
            if (rx_exp.size() == 0) err("RX: unexpected frame");
            else begin
                byte unsigned e [$];
                bit b;
                e = rx_exp.pop_front();
                b = rx_bad.pop_front();
                if (e != rx_cur) err($sformatf("RX: frame %0d: %0d bytes, expected %0d, data %s", rx_frames,
                                               rx_cur.size(), e.size(), (e == rx_cur) ? "ok" : "BAD"));
                if (up_u != b) err($sformatf("RX: frame %0d bad flag %0d, expected %0d", rx_frames, up_u, b));
                if (b) rx_badn++;
            end
            rx_frames++;
            rx_cur = {};
        end else if (up_u) err("RX: tuser on a non-last beat");
    end
end

// ================= TX =================
logic [511:0] tx_d = '0;
logic [63:0]  tx_k = '0;
logic         tx_v = 1'b0, tx_l = 1'b0;
wire  logic   tx_r;
wire  logic [MAC_W-1:0] dn_d;
wire  logic [KB-1:0]    dn_k;
wire  logic             dn_v, dn_l, dn_gap;
logic                   dn_r = 1'b0;
bit                     tx_b2b = 0;

rocelet_tx_downsize #(.MAC_W(MAC_W)) u_dn (
    .clk(clk), .rst(rst),
    .s_tdata(tx_d), .s_tkeep(tx_k), .s_tvalid(tx_v), .s_tready(tx_r), .s_tlast(tx_l),
    .m_tdata(dn_d), .m_tkeep(dn_k), .m_tvalid(dn_v), .m_tready(dn_r), .m_tlast(dn_l), .ev_gap(dn_gap)
);

byte unsigned tx_exp [$][$];
int           tx_frames = 0, tx_sent = 0, b2b_beats = 0, b2b_idle = 0, b2b_exp = 0;
bit           tx_done = 0, b2b_on = 0;

task automatic tx_frame(input int len, input bit b2b);
    byte unsigned fr [$];
    int nb;
    for (int i = 0; i < len; i++) fr.push_back(8'($urandom));
    tx_exp.push_back(fr);
    nb = (len + 63) / 64;
    if (b2b) b2b_exp += (len + KB - 1) / KB;
    for (int b = 0; b < nb; b++) begin
        tx_d <= '0; tx_k <= '0;
        for (int j = 0; j < 64 && b * 64 + j < len; j++) begin
            tx_d[j*8 +: 8] <= fr[b * 64 + j];
            tx_k[j] <= 1'b1;
        end
        tx_l <= (b == nb - 1);
        tx_v <= 1'b1;
        @(posedge clk);
        while (!tx_r) @(posedge clk);
    end
    tx_v <= 1'b0;
    tx_sent++;
endtask

initial begin
    wait (!rst);
    repeat (4) @(posedge clk);
    for (int f = 0; f < nf; f++) begin
        tx_frame((urand100() < 20) ? $urandom_range(KB, 1) : $urandom_range(600, 1), 0);
        while (urand100() < gap) @(posedge clk);
    end
    wait (tx_exp.size() == 0);
    repeat (10) @(posedge clk);
    // back to back with tready high: the MAC side must be busy every clock
    tx_b2b = 1;
    repeat (2) @(posedge clk);
    for (int f = 0; f < 40; f++) tx_frame($urandom_range(600, 1), 1);
    wait (tx_exp.size() == 0);
    repeat (10) @(posedge clk);
    tx_done = 1;
end

always @(posedge clk) dn_r <= tx_b2b ? 1'b1 : (urand100() >= bp);

byte unsigned tx_cur [$];
bit           tx_in = 0;
always @(posedge clk) begin
    if (dn_gap) err("TX: ev_gap");
    if (tx_in && !dn_v) err($sformatf("TX: tvalid gap inside frame %0d on the MAC side", tx_frames));
    if (tx_b2b && b2b_on) begin
        if (dn_v) b2b_beats++; else b2b_idle++;
    end
    if (dn_v && dn_r) begin
        bit c;
        int n;
        n = keep_n(64'(dn_k), c);
        if (!c || n == 0) err($sformatf("TX: tkeep %h not contiguous from lane 0", dn_k));
        if (!dn_l && n != KB) err($sformatf("TX: non-last MAC beat with %0d bytes", n));
        for (int i = 0; i < n; i++) tx_cur.push_back(dn_d[i*8 +: 8]);
        tx_in = !dn_l;
        if (tx_b2b && !b2b_on) begin b2b_on = 1; b2b_beats = 1; end
        if (dn_l) begin
            byte unsigned e [$];
            if (tx_exp.size() == 0) err("TX: unexpected frame");
            else begin
                e = tx_exp.pop_front();
                if (e != tx_cur) err($sformatf("TX: frame %0d: %0d bytes, expected %0d", tx_frames, tx_cur.size(),
                                               e.size()));
            end
            tx_frames++;
            tx_cur = {};
            if (tx_b2b && tx_exp.size() == 0) b2b_on = 0;
        end
    end
end

initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("nf=%d", nf)) nf = 500;
    if (!$value$plusargs("gap=%d", gap)) gap = 25;
    if (!$value$plusargs("bp=%d", bp)) bp = 25;
    r = $urandom(seed);
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    wait (rx_done && tx_done);
    if (rx_exp.size()) err($sformatf("RX: %0d frames missing", rx_exp.size()));
    if (b2b_beats != b2b_exp || b2b_idle != 0)
        err($sformatf("TX back to back: %0d MAC beats busy, %0d expected, %0d idle clocks", b2b_beats, b2b_exp,
                      b2b_idle));
    $display("TB_DONE mac_w=%0d rx_frames=%0d rx_bad=%0d rx_beats512=%0d tx_frames=%0d b2b_beats=%0d b2b_idle=%0d errors=%0d",
             MAC_W, rx_frames, rx_badn, rx_beats512, tx_frames, b2b_beats, b2b_idle, nerr);
    $finish;
end

initial begin
    #50ms;
    $display("TB_TIMEOUT");
    $finish;
end

endmodule
