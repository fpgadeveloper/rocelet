// SPDX-License-Identifier: MIT
//
// rocelet_rx_fifo - store-and-forward RX frame FIFO for a MAC without RX back-pressure
// (a MAC RX AXI-Stream has no tready, e.g. the UltraScale+ CMAC's rx_axis: every beat must be
// taken in its clock; tvalid may drop between beats, e.g. behind rocelet_rx_upsize).
// Everything behind it can stall, so frames are written whole and released only after
// their last beat:
//  * a frame is offered downstream once its last beat is written and it was not flagged
//    bad (s_tuser on the last beat = FCS error: dropped, ev_err);
//  * if the FIFO fills up while a frame is being written, the partial frame is rolled back
//    and the rest of it discarded: frames are dropped whole, never truncated or merged
//    (ev_drop); a frame longer than the FIFO is dropped the same way;
//  * s_abort (MAC RX in reset) / s_hold (MAC TX side in reset, or receive disabled): the
//    frame being written is rolled back and input is discarded while they last; after
//    them only the rest of a frame that is really in progress is skipped (the MAC's
//    frame state is tracked from the input beats), so an idle MAC's next frame is taken;
//  * fill (beats, registered) feeds the 802.3x PAUSE request logic.
// Beats are stored as {last, byte count, data} (tkeep is contiguous: 7 bits instead of
// 64), so 512 beats fit in 8 RAMB36. Timing: the RAM write port is registered; the read
// side reads the RAM every clock into a two-stage pipeline and a small LUTRAM output
// buffer, the only part that sees tready (full rate with tready held high).
// Based on the CMAC RX frame FIFO of the Opsero 2x QSFP28 FMC reference design (MIT),
// reduced to one clock domain.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_rx_fifo #(
    parameter int DEPTH = 512          // beats, power of 2
) (
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic          s_abort,
    input  wire logic          s_hold,
    input  wire logic [511:0]  s_tdata,
    input  wire logic [63:0]   s_tkeep,
    input  wire logic          s_tvalid,
    input  wire logic          s_tlast,
    input  wire logic          s_tuser,

    output wire logic [511:0]  m_axis_tdata,
    output wire logic [63:0]   m_axis_tkeep,
    output wire logic          m_axis_tvalid,
    input  wire logic          m_axis_tready,
    output wire logic          m_axis_tlast,

    output logic [$clog2(DEPTH):0] fill = '0,
    output logic               ev_frame,       // a frame's last beat arrived from the MAC
    output logic               ev_err,         // ... flagged bad, dropped
    output logic               ev_drop         // ... dropped: full, oversize, reset, hold, skip
);

localparam int AW = $clog2(DEPTH);
localparam int MW = 1 + 7 + 512;              // {last, n, data}
localparam int OBD = 8;                        // output buffer entries
localparam int OBW = 3;

// ---------------- input register ----------------
logic         in_hold = 1'b0, in_abort = 1'b0, in_beat = 1'b0, in_rstn = 1'b0;
logic         in_last = 1'b0, in_err = 1'b0;
logic [6:0]   in_n;
logic [511:0] in_data;
wire  logic [6:0] keep_n;
rocelet_keep2n #(.KW(64)) u_k2n (.keep(s_tkeep), .n(keep_n));
always_ff @(posedge clk) begin
    in_hold  <= s_abort || s_hold;
    in_abort <= s_abort;
    in_beat  <= s_tvalid;
    in_rstn  <= !rst;
    in_last  <= s_tlast;
    in_err   <= s_tuser;
    in_n     <= keep_n;
    in_data  <= s_tdata;
end

// the MAC is in the middle of a frame (after this beat); tracked from every beat
logic mac_in_frame = 1'b0;
wire  logic mif_next = in_abort ? 1'b0 : (in_beat ? !in_last : mac_in_frame);
always_ff @(posedge clk) mac_in_frame <= mif_next;

// ---------------- storage ----------------
(* ram_style = "block" *) logic [MW-1:0] mem [DEPTH];

logic [AW:0] wr_ptr = '0;          // speculative write pointer
logic [AW:0] wr_commit = '0;       // end of the last complete, good frame
logic [AW:0] commit_rd = '0;       // wr_commit, delayed like the RAM write
logic [AW:0] rd_ptr = '0;

// ---------------- write side ----------------
logic full_r = 1'b0, dropping = 1'b0;
wire  logic [AW:0] fill_now = wr_ptr - rd_ptr;
always_ff @(posedge clk) fill <= fill_now;

wire logic acc     = in_beat && !dropping && !in_hold;
wire logic wrst    = rst || !in_rstn;            // the beat sampled in reset belongs to it
wire logic wr_en   = acc && !full_r && !wrst;
wire logic commit  = wr_en && in_last && !in_err;
wire logic lost    = in_beat && in_last && !commit;

always_ff @(posedge clk) begin
    ev_frame <= in_beat && in_last;
    ev_err   <= lost && in_err;
    ev_drop  <= lost && !in_err;
end

logic          we_r = 1'b0;
logic [AW-1:0] wa_r;
logic [MW-1:0] wd_r;
always_ff @(posedge clk) begin
    we_r <= wr_en;
    wa_r <= wr_ptr[AW-1:0];
    wd_r <= {in_last, in_n, in_data};
    if (we_r) mem[wa_r] <= wd_r;
end

// discarding the rest of the current MAC frame: across a reset or a hold (only the rest
// of a frame really in progress), after an overflow; a frame's last beat ends it
logic drop_n;
always_comb begin
    drop_n = dropping;
    if (wrst || in_hold)              drop_n = mif_next;
    else if (in_beat && dropping)     drop_n = !in_last;
    else if (in_beat && full_r)       drop_n = !in_last;
end
always_ff @(posedge clk) dropping <= drop_n;

always_ff @(posedge clk) begin
    if (wrst) begin
        wr_ptr    <= '0;
        wr_commit <= '0;
        commit_rd <= '0;
        full_r    <= 1'b0;
    end else begin
        full_r    <= (fill_now >= (AW+1)'(DEPTH - 1));
        commit_rd <= wr_commit;
        if (in_hold) begin
            wr_ptr <= wr_commit;    // roll back a partial frame
        end else if (in_beat && !dropping) begin
            if (full_r) begin
                wr_ptr <= wr_commit;
            end else if (in_last) begin
                if (in_err) begin
                    wr_ptr <= wr_commit;
                end else begin
                    wr_ptr    <= wr_ptr + 1'b1;
                    wr_commit <= wr_ptr + 1'b1;
                end
            end else begin
                wr_ptr <= wr_ptr + 1'b1;
            end
        end
    end
end

// ---------------- read side ----------------
logic [OBW:0]  cnt = '0, ob_wp = '0, ob_rp = '0;
logic          v1 = 1'b0, v2 = 1'b0;
logic [MW-1:0] qa, qb;
wire  logic    rd_avail = (rd_ptr != commit_rd);
wire  logic    rd_issue = rd_avail && (cnt < (OBW+1)'(OBD));
wire  logic    ob_valid = (ob_wp != ob_rp);
wire  logic    ob_pop   = ob_valid && m_axis_tready;

always_ff @(posedge clk) begin
    qa <= mem[rd_ptr[AW-1:0]];
    qb <= qa;
end

(* ram_style = "distributed" *) logic [MW-1:0] ob [OBD];
always_ff @(posedge clk) if (v2) ob[ob_wp[OBW-1:0]] <= qb;

always_ff @(posedge clk) begin
    if (rst) begin
        rd_ptr <= '0;
        v1     <= 1'b0;
        v2     <= 1'b0;
        cnt    <= '0;
        ob_wp  <= '0;
        ob_rp  <= '0;
    end else begin
        if (rd_issue) rd_ptr <= rd_ptr + 1'b1;
        v1 <= rd_issue;
        v2 <= v1;
        if (v2) ob_wp <= ob_wp + 1'b1;
        if (ob_pop) ob_rp <= ob_rp + 1'b1;
        cnt <= cnt + rd_issue - ob_pop;
    end
end

function automatic logic [63:0] therm(input logic [6:0] n);
    for (int i = 0; i < 64; i++) therm[i] = (i < n);
endfunction

wire logic [MW-1:0] ob_q = ob[ob_rp[OBW-1:0]];
assign m_axis_tvalid = ob_valid;
assign m_axis_tlast  = ob_q[MW-1];
assign m_axis_tkeep  = therm(ob_q[MW-2 -: 7]);
assign m_axis_tdata  = ob_q[511:0];

endmodule

`resetall
