// SPDX-License-Identifier: MIT
//
// rocelet_retx_desc - outstanding-WR ring of the requester: completion tracking and
// go-back-N re-issue by regeneration.
//
// Every WR the requester starts is recorded here first; the ring's free space is the
// outstanding-WR window. A record retires, and a completion (qp, wr_id, status) is
// emitted, when the QP's una (rocelet_ack_proc m_rel) has passed the WR's last PSN
// (status OK), when it was marked lost (LOST), or when its QP is in the error state
// (FLUSHED). Records of different QPs share one ring in issue order, so a slow QP holds
// back the retirement of later records (head-of-line blocking of completions, not of
// traffic). Retirement is pipelined: the head record is registered, then judged, so at
// most one record retires every two clocks (far above the packet rate).
// REGEN = 1 also keeps the WR fields (class, SE, VA, rkey, length, immediate, local
// address) in a RAM, and on a go-back-N request (qp, PSN) scans the ring from the oldest
// record and re-issues, in order, every WR of that QP whose last PSN is >= PSN, the
// first one starting at PSN. The payload is fetched again through the requester's
// read port (the on-chip ring of rocelet_retx_ring, or memory), so no packet store is
// needed here.
// REGEN = 0 (lossy resume): the same scan marks the records of the QP from PSN on as
// lost (the requester resumes new data there, reusing those PSNs); they retire at the
// head with status LOST.
// m_busy is high while a scan runs; new WRs must be held back.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_retx_desc
    import rocelet_pkg::*;
#(
    parameter int NUM_QP    = 16,
    parameter int DEPTH     = 128,
    parameter bit REGEN     = 1'b1,
    parameter     RAM_STYLE = "auto",
    localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1
) (
    input  wire logic             clk,
    input  wire logic             rst,

    input  wire logic             cfg_qp_we,
    input  wire logic [QPW-1:0]   cfg_qp,
    input  wire logic [23:0]      cfg_psn,
    input  wire logic [NUM_QP-1:0] qp_err,

    input  wire logic             s_trk_valid,
    output wire logic             s_trk_ready,
    input  wire logic [QPW-1:0]   s_trk_qp,
    input  wire logic [15:0]      s_trk_id,
    input  wire logic [23:0]      s_trk_first_psn,
    input  wire logic [23:0]      s_trk_last_psn,
    input  wire logic [1:0]       s_trk_class,
    input  wire logic             s_trk_se,
    input  wire logic [63:0]      s_trk_va,
    input  wire logic [31:0]      s_trk_rkey,
    input  wire logic [31:0]      s_trk_len,
    input  wire logic [31:0]      s_trk_imm,
    input  wire logic [63:0]      s_trk_laddr,

    input  wire logic             s_rel_valid,
    input  wire logic [QPW-1:0]   s_rel_qp,
    input  wire logic [23:0]      s_rel_una,

    input  wire logic             s_rtx_valid,
    output wire logic             s_rtx_ready,
    input  wire logic [QPW-1:0]   s_rtx_qp,
    input  wire logic [23:0]      s_rtx_psn,

    output wire logic             m_rex_valid,
    input  wire logic             m_rex_ready,
    output wire logic [QPW-1:0]   m_rex_qp,
    output wire logic [1:0]       m_rex_class,
    output wire logic             m_rex_se,
    output wire logic [63:0]      m_rex_va,
    output wire logic [31:0]      m_rex_rkey,
    output wire logic [31:0]      m_rex_len,
    output wire logic [31:0]      m_rex_imm,
    output wire logic [63:0]      m_rex_laddr,
    output wire logic [15:0]      m_rex_id,
    output wire logic [23:0]      m_rex_first_psn,
    output wire logic [23:0]      m_rex_start_psn,
    output wire logic             m_busy,

    output wire logic             m_cpl_valid,
    input  wire logic             m_cpl_ready,
    output wire logic [QPW-1:0]   m_cpl_qp,
    output wire logic [15:0]      m_cpl_id,
    output wire logic [7:0]       m_cpl_status,

    output wire logic [$clog2(DEPTH):0] stat_used
);

localparam int AW = $clog2(DEPTH);
localparam int MW = QPW + 16 + 24 + 24;               // meta: qp, id, first, last
localparam int FW = 2 + 1 + 64 + 32 + 32 + 32 + 64;   // WR fields for regeneration

// psn a < b (mod 2^24, window 2^23)
function automatic logic psn_lt(input logic [23:0] a, input logic [23:0] b);
    logic [23:0] d = b - a;
    return (d != 0) && !d[23];
endfunction

logic [AW:0] head = '0, tail = '0;
wire  logic  empty = (head == tail);
wire  logic  full  = (tail == {~head[AW], head[AW-1:0]});
assign s_trk_ready = !full;
wire  logic  trk_fire = s_trk_valid && !full;
assign stat_used = tail - head;

// meta: asynchronous-read LUTRAM (head check and scan)
(* ram_style = "distributed" *)
logic [MW-1:0] meta [DEPTH];
always_ff @(posedge clk) begin
    if (trk_fire) meta[tail[AW-1:0]] <= {s_trk_qp, s_trk_id, s_trk_first_psn, s_trk_last_psn};
end

// per-QP una: one LUTRAM write port (configuration has priority; it only happens while
// the QP is idle), asynchronous read for the retirement check
(* ram_style = "distributed" *)
logic [23:0] una [NUM_QP];
always_ff @(posedge clk) begin
    if (cfg_qp_we || s_rel_valid)
        una[cfg_qp_we ? cfg_qp : s_rel_qp] <= cfg_qp_we ? cfg_psn : s_rel_una;
end

// ---------------- retirement / completions ----------------
logic [DEPTH-1:0] dead = '0;    // lossy resume: record lost

// stage 1: the head record, registered
logic           hd_v = 1'b0, hd_dead;
logic [QPW-1:0] hd_qp;
logic [15:0]    hd_id;
logic [23:0]    hd_last;
wire  logic [MW-1:0] hm = meta[head[AW-1:0]];

// stage 2: judge it
logic           c_v = 1'b0;
logic [7:0]     c_status;
logic [QPW-1:0] c_qp;
logic [15:0]    c_id;
wire  logic     h_acked = psn_lt(hd_last, una[hd_qp]);
wire  logic     retire  = hd_v && (hd_dead || h_acked || qp_err[hd_qp]) && (!c_v || m_cpl_ready);

always_ff @(posedge clk) begin
    hd_v    <= !empty && !retire;            // re-read after a retirement (head moves)
    hd_qp   <= hm[MW-1 -: QPW];
    hd_id   <= hm[MW-1-QPW -: 16];
    hd_last <= hm[23:0];
    hd_dead <= dead[head[AW-1:0]];
    if (m_cpl_ready) c_v <= 1'b0;
    if (retire) begin
        c_v      <= 1'b1;
        c_qp     <= hd_qp;
        c_id     <= hd_id;
        c_status <= hd_dead ? WC_LOST : (h_acked ? WC_OK : WC_FLUSHED);
    end
    if (rst) begin
        hd_v <= 1'b0;
        c_v  <= 1'b0;
    end
end
assign m_cpl_valid  = c_v;
assign m_cpl_qp     = c_qp;
assign m_cpl_id     = c_id;
assign m_cpl_status = c_status;

// ---------------- re-issue scan ----------------
logic           sc_act = 1'b0;
logic [AW:0]    sc_i;
logic [QPW-1:0] sc_qp;
logic [23:0]    sc_psn;
logic           sc_wait = 1'b0;     // a record read is in flight / being offered
logic           rx_v = 1'b0;

logic [AW:0]    sc_end;             // tail when the scan started
assign s_rtx_ready = !sc_act;
assign m_busy      = sc_act;

wire logic [MW-1:0]  sm      = meta[sc_i[AW-1:0]];
wire logic [QPW-1:0] s_qp    = sm[MW-1 -: QPW];
wire logic [23:0]    s_first = sm[47:24];
wire logic [23:0]    s_last  = sm[23:0];
wire logic           s_hit   = (s_qp == sc_qp) && !psn_lt(s_last, sc_psn);

// ring distances: scan pointer behind the head; records left before the scan's end
wire logic [AW:0] behind  = head - sc_i;
wire logic [AW:0] to_end  = sc_end - sc_i;
wire logic        sc_lost = behind != 0 && behind < (AW+1)'(DEPTH);     // retired under the pointer
wire logic        sc_done = to_end == 0 || to_end > (AW+1)'(DEPTH);
wire logic        sc_take = sc_act && !sc_wait && !sc_lost && !sc_done && s_hit;

wire logic [FW-1:0] f_rd;
logic [MW-1:0]      p_meta, o_meta;
logic [23:0]        p_start, o_start;
logic [FW-1:0]      o_f;

if (REGEN) begin : g_regen
    // the record under the scan pointer is read on every scan clock and held while a
    // re-issue waits (sc_wait); only the read of the take clock is used. Not enabling
    // the read with sc_take keeps the hit / lost / done compare off the RAM enable.
    rocelet_ram_sdp #(.WIDTH(FW), .DEPTH(DEPTH), .RD_LAT(1), .RAM_STYLE(RAM_STYLE)) u_f (
        .clk(clk), .we(trk_fire), .waddr(tail[AW-1:0]),
        .wdata({s_trk_class, s_trk_se, s_trk_va, s_trk_rkey, s_trk_len, s_trk_imm, s_trk_laddr}),
        .re(sc_act && !sc_wait), .raddr(sc_i[AW-1:0]), .rdata(f_rd)
    );
end else begin : g_noregen
    assign f_rd = '0;
end

always_ff @(posedge clk) begin
    if (m_rex_ready) rx_v <= 1'b0;
    if (s_rtx_valid && !sc_act) begin
        sc_act  <= 1'b1;
        sc_end  <= tail;
        sc_i    <= head;
        sc_qp   <= s_rtx_qp;
        sc_psn  <= s_rtx_psn;
        sc_wait <= 1'b0;
    end else if (sc_act) begin
        if (!sc_wait) begin
            if (sc_lost) begin
                sc_i <= head;               // records retired under the scan pointer
            end else if (sc_done) begin
                // done; also when retirement moved the head (and so the pointer)
                // past the scan's end
                sc_act <= 1'b0;
            end else if (s_hit && !REGEN) begin
                sc_i <= sc_i + 1'b1;        // lossy: mark lost (see below)
            end else if (s_hit) begin
                sc_wait <= 1'b1;            // record read issued
                p_meta  <= sm;
                p_start <= psn_lt(s_first, sc_psn) ? sc_psn : s_first;
            end else begin
                sc_i <= sc_i + 1'b1;
            end
        end else if (!rx_v || m_rex_ready) begin
            rx_v    <= 1'b1;                // record fields are in f_rd now
            o_meta  <= p_meta;
            o_start <= p_start;
            o_f     <= f_rd;
            sc_wait <= 1'b0;
            sc_i    <= sc_i + 1'b1;
        end
    end
    if (rst) begin
        sc_act <= 1'b0;
        rx_v   <= 1'b0;
    end
end

assign m_rex_valid     = rx_v;
assign m_rex_qp        = o_meta[MW-1 -: QPW];
assign m_rex_id        = o_meta[MW-1-QPW -: 16];
assign m_rex_first_psn = o_meta[47:24];
assign m_rex_start_psn = o_start;
assign {m_rex_class, m_rex_se, m_rex_va, m_rex_rkey, m_rex_len, m_rex_imm, m_rex_laddr} = o_f;

// lost marks (lossy resume)
always_ff @(posedge clk) begin
    if (!REGEN && sc_take) dead[sc_i[AW-1:0]] <= 1'b1;
    if (trk_fire) dead[tail[AW-1:0]] <= 1'b0;
    if (rst) dead <= '0;
end

// pointer update
always_ff @(posedge clk) begin
    if (trk_fire) tail <= tail + 1'b1;
    if (retire) head <= head + 1'b1;
    if (rst) begin
        head <= '0;
        tail <= '0;
    end
end

endmodule

`resetall
