// SPDX-License-Identifier: MIT
//
// rocelet_resp_rx - RoCE v2 RC responder, receive side.
//
// Takes the parsed packets of rocelet_rx_parser (header record, stripped payload,
// end-of-frame verdict) and, one packet at a time:
//   * looks up the QP (local QPN = QPN_BASE + index; direct index, no CAM) and its
//     receive context: ePSN, MSN, opcode-sequence state, running local address,
//     residual length of a multi-packet WRITE, message length, NAK-sent flag;
//   * classifies the PSN (new / duplicate / out of sequence, 24-bit modulo), checks
//     the opcode sequence (FIRST, MIDDLE, LAST, ONLY), the payload length against
//     the PMTU and the RETH DMA length, and for WRITE FIRST/ONLY and READ the R_Key
//     against the memory-window table (NUM_MR = 1: one window, else a table indexed
//     by R_Key[MRW-1:0] with a full-key compare), the access right, the bounds and
//     the 64-byte alignment of the VA;
//   * WRITE: one memory write command (local address, length) per packet, payload
//     passed cut-through; SEND: payload to the SEND stream (QP, start/end of
//     message) and a commit/discard verdict per packet (m_send_end_*), because the
//     payload is passed before the frame's ICRC is known;
//   * commits the context only if the frame's ICRC was good (m_end), then emits a
//     receive completion for WRITE with immediate / SEND, and a response request in
//     PSN order: ACK (AckReq), NAK (PSN sequence error, once per gap; invalid
//     request; remote access), RNR NAK (a SEND FIRST/ONLY while send_rnr[qp] is
//     high; the packet is dropped and the requester retries after the timer), or a
//     READ job (re-executed for duplicate READs);
//   * forwards received ACK/NAKs (the FPGA as requester) to m_ack.
// Duplicate READs are checked like new ones (window, key, bounds) and dropped if
// they fail. With cfg_read_cont = 1, a duplicate READ whose PSN lies inside an
// earlier READ of this QP (not at its first PSN) is a partial re-issue of that
// READ's tail: the job is marked m_rsp_cont and answered as a continuation of the
// original response (MIDDLE ... LAST), as the ConnectX-6 Dx requires; with 0 it is
// answered as a new response (FIRST ... LAST / ONLY), as IBTA and rxe do. The
// last READ_DEPTH READs of each QP are remembered for that ({first PSN, packets -
// 1}); the lookup scans them, one per clock, only for duplicate READs.
// Outstanding READs per QP are limited to READ_DEPTH (a power of two, as mlx5 rounds
// max_rd_atomic up); more is NAK invalid request. Only new READs (PSN = ePSN) take one of
// these READ resources, from their commit until their response has been handed to the
// transmit path: a duplicate READ (PSN behind ePSN: a whole or partial re-issue of a READ
// the requester already counts as outstanding) is re-executed without taking one, and its
// job is marked m_rsp_dup so that its end (s_rddone) does not free one either. Counting
// re-executed duplicates against READ_DEPTH (v0.1) NAKed legitimate new READs with 0x61 when
// a ConnectX-6 re-issued READs within microseconds while their stale responses were still
// queued: the requester had finished some of them from those stale responses, so the queued
// duplicates were no longer outstanding on its side.
// Errors (NAK invalid request / remote access) put the QP into the error state
// (qp_err), as does cfg_err_we; packets for a QP in error, an unconfigured QP or an
// unknown QPN are dropped. A frame with a bad ICRC leaves the context untouched:
// payload already written is overwritten when the requester retransmits.
// The per-QP state is reset only by a configuration write (cfg_qp_we).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_resp_rx
    import rocelet_pkg::*;
#(
    parameter int          NUM_QP       = 16,
    parameter int          NUM_MR       = 16,
    parameter bit          PMTU_RUNTIME = 1'b1,
    parameter int          PMTU_LOG2    = 12,
    parameter logic [23:0] QPN_BASE     = 24'h000100,
    parameter bit          READ_EN      = 1'b1,
    parameter int          READ_DEPTH   = 16,
    parameter bit          CONT_EN      = 1'b1,      // build the READ continuation history
    parameter bit          SEND_EN      = 1'b1,
    localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1,
    localparam int MRW = (NUM_MR > 1) ? $clog2(NUM_MR) : 1,
    localparam int RCW = $clog2(READ_DEPTH) + 2       // outstanding READ counters (new READs only, <= READ_DEPTH)
) (
    input  wire logic             clk,
    input  wire logic             rst,

    // run-time controls
    input  wire logic             cfg_read_cont,       // partial duplicate READ -> continuation
    input  wire logic [4:0]       cfg_rnr_timer,       // timer code of the RNR NAKs sent
    input  wire logic [NUM_QP-1:0] send_rnr,           // registered by the caller

    // QP receive context initialisation (resets the QP's state)
    input  wire logic             cfg_qp_we,
    input  wire logic [QPW-1:0]   cfg_qp,
    input  wire logic             cfg_qp_valid,
    input  wire logic [23:0]      cfg_qp_epsn,
    input  wire logic [3:0]       cfg_qp_pmtu,
    // force a QP into the error state
    input  wire logic             cfg_err_we,
    input  wire logic [QPW-1:0]   cfg_err_qp,
    // memory-window table
    input  wire logic             cfg_mr_we,
    input  wire logic [MRW-1:0]   cfg_mr_idx,
    input  wire logic             cfg_mr_valid,
    input  wire logic [31:0]      cfg_mr_rkey,
    input  wire logic [63:0]      cfg_mr_va,
    input  wire logic [31:0]      cfg_mr_len,
    input  wire logic [63:0]      cfg_mr_laddr,
    input  wire logic [1:0]       cfg_mr_acc,      // [0] remote write, [1] remote read

    // from rocelet_rx_parser
    input  wire logic             s_hdr_valid,
    output wire logic             s_hdr_ready,
    input  wire logic [7:0]       s_hdr_opcode,
    input  wire logic [23:0]      s_hdr_dqpn,
    input  wire logic             s_hdr_ackreq,
    input  wire logic [23:0]      s_hdr_psn,
    input  wire logic [63:0]      s_hdr_va,
    input  wire logic [31:0]      s_hdr_rkey,
    input  wire logic [31:0]      s_hdr_dmalen,
    input  wire logic [7:0]       s_hdr_syndrome,
    input  wire logic [23:0]      s_hdr_msn,
    input  wire logic [31:0]      s_hdr_imm,
    input  wire logic [15:0]      s_hdr_paylen,
    input  wire logic             s_hdr_malformed,
    input  wire logic [511:0]     s_pay_tdata,
    input  wire logic [63:0]      s_pay_tkeep,
    input  wire logic             s_pay_tvalid,
    output wire logic             s_pay_tready,
    input  wire logic             s_pay_tlast,
    input  wire logic             s_end_valid,
    input  wire logic             s_end_ok,

    // memory write (S2MM): one command + payload per WRITE packet
    output wire logic             m_wcmd_valid,
    input  wire logic             m_wcmd_ready,
    output wire logic [63:0]      m_wcmd_addr,
    output wire logic [12:0]      m_wcmd_len,
    output wire logic [511:0]     m_wdat_tdata,
    output wire logic [63:0]      m_wdat_tkeep,
    output wire logic             m_wdat_tvalid,
    input  wire logic             m_wdat_tready,
    output wire logic             m_wdat_tlast,
    // per WRITE packet with payload, after its payload: 1 = committed (ICRC good),
    // 0 = discarded (the cut-through data is overwritten by the retry)
    output wire logic             m_wend_valid,
    output wire logic             m_wend_ok,

    // SEND payload stream
    output wire logic [511:0]     m_send_tdata,
    output wire logic [63:0]      m_send_tkeep,
    output wire logic             m_send_tvalid,
    input  wire logic             m_send_tready,
    output wire logic             m_send_tlast,
    output wire logic [QPW-1:0]   m_send_qp,
    output wire logic             m_send_som,
    output wire logic             m_send_eom,
    output wire logic             m_send_end_valid,   // per SEND packet, after its payload:
    output wire logic             m_send_end_ok,      // 1 = commit, 0 = discard (bad ICRC)

    // receive completions (WRITE with immediate, SEND)
    output wire logic             m_cpl_valid,
    input  wire logic             m_cpl_ready,
    output wire logic [QPW-1:0]   m_cpl_qp,
    output wire logic             m_cpl_send,
    output wire logic             m_cpl_has_imm,
    output wire logic [31:0]      m_cpl_imm,
    output wire logic [31:0]      m_cpl_len,

    // response requests, in PSN order (to rocelet_resp_tx)
    output wire logic             m_rsp_valid,
    input  wire logic             m_rsp_ready,
    output wire logic             m_rsp_read,      // 1 = READ job, 0 = ACK/NAK
    output wire logic             m_rsp_cont,      // READ job continues an earlier response
    output wire logic             m_rsp_dup,       // READ job re-executes a duplicate (holds no READ resource)
    output wire logic [QPW-1:0]   m_rsp_qp,
    output wire logic [23:0]      m_rsp_psn,
    output wire logic [7:0]       m_rsp_syndrome,
    output wire logic [23:0]      m_rsp_msn,
    output wire logic [63:0]      m_rsp_laddr,
    output wire logic [31:0]      m_rsp_len,
    output wire logic [3:0]       m_rsp_pmtu,
    input  wire logic             s_rddone_valid,  // a new READ's response finished (not for m_rsp_dup jobs)
    input  wire logic [QPW-1:0]   s_rddone_qp,

    // received ACK / NAK (requester side); ack_room = the ACK processor can take one
    input  wire logic             ack_room,
    output wire logic             m_ack_valid,
    output wire logic [QPW-1:0]   m_ack_qp,
    output wire logic [23:0]      m_ack_psn,
    output wire logic [7:0]       m_ack_syndrome,
    output wire logic [23:0]      m_ack_msn,

    // QP errors
    output wire logic             m_err_valid,
    output wire logic [QPW-1:0]   m_err_qp,
    output wire logic [7:0]       m_err_syndrome,
    output wire logic [NUM_QP-1:0] qp_err,

    // event pulses (one per committed packet of that kind)
    output logic                  ev_req,          // new request executed
    output logic                  ev_dup,          // duplicate (re-ACKed / READ re-executed)
    output logic                  ev_seq,          // out of sequence (NAK-seq sent or suppressed)
    output logic                  ev_drop,         // dropped (unknown / unconfigured / error QP, bad duplicate)
    output logic                  ev_read,         // READ job issued (new or duplicate)
    output logic                  ev_read_cont,    // ... as a continuation
    output logic                  ev_rnr           // RNR NAK sent
);

// ---------------- receive context ----------------
localparam logic [1:0] OPS_NONE = 2'd0, OPS_WRITE = 2'd1, OPS_SEND = 2'd2;

typedef struct packed {
    logic        nak;          // NAK-sequence (or RNR NAK) sent; silent until ePSN
    logic [1:0]  opst;         // opcode-sequence state
    logic [3:0]  pmtu;
    logic [31:0] resid;        // WRITE: bytes still expected
    logic [31:0] mlen;         // message length (WRITE: DMA length; SEND: bytes so far)
    logic [63:0] cur;          // next local address
    logic [23:0] msn;
    logic [23:0] epsn;
} ctx_t;
localparam int CTXW = $bits(ctx_t);

logic            cw_we;
logic [QPW-1:0]  cw_qp;
ctx_t            cw_d;
ctx_t            cr_d;
logic            cr_re;
logic [QPW-1:0]  cr_qp;

if (NUM_QP == 1) begin : g_ctx1
    ctx_t row;
    always_ff @(posedge clk) if (cw_we) row <= cw_d;
    assign cr_d = row;
end else begin : g_ctx
    wire logic [CTXW-1:0] rd;
    rocelet_ram_sdp #(.WIDTH(CTXW), .DEPTH(NUM_QP), .RD_LAT(1), .RAM_STYLE("auto")) u_ctx (
        .clk(clk), .we(cw_we), .waddr(cw_qp), .wdata(cw_d), .re(cr_re), .raddr(cr_qp), .rdata(rd)
    );
    assign cr_d = ctx_t'(rd);
end

// configured QPs and QPs in error (registers, cleared by rst; the context RAM is not)
logic [NUM_QP-1:0] qp_on = '0, err_vec = '0;
logic              err_v = 1'b0;
logic [QPW-1:0]    o_err_qp;
always_ff @(posedge clk) begin
    if (err_v) err_vec[o_err_qp] <= 1'b1;
    if (cfg_err_we) err_vec[cfg_err_qp] <= 1'b1;
    if (cfg_qp_we) begin
        qp_on[cfg_qp]   <= cfg_qp_valid;
        err_vec[cfg_qp] <= 1'b0;
    end
    if (rst) begin
        qp_on   <= '0;
        err_vec <= '0;
    end
end
assign qp_err = err_vec;

// outstanding READ counters: issued (incremented on the commit of a new READ) and
// finished (incremented by the response engine at the end of a new READ's response) per
// QP, each a LUTRAM written by one side only; outstanding = issued - finished (mod 2^RCW).
// Duplicate READs touch neither.
logic           rd_inc;
logic [QPW-1:0] rd_inc_qp;
(* ram_style = "distributed" *) logic [RCW-1:0] rd_iss [NUM_QP];
(* ram_style = "distributed" *) logic [RCW-1:0] rd_fin [NUM_QP];
initial begin
    for (int q = 0; q < NUM_QP; q++) begin
        rd_iss[q] = '0;
        rd_fin[q] = '0;
    end
end
always_ff @(posedge clk) begin
    if (READ_EN && (cfg_qp_we || rd_inc))
        rd_iss[cfg_qp_we ? cfg_qp : rd_inc_qp] <= cfg_qp_we ? '0 : rd_iss[rd_inc_qp] + 1'b1;
    if (READ_EN && (cfg_qp_we || s_rddone_valid))
        rd_fin[cfg_qp_we ? cfg_qp : s_rddone_qp] <= cfg_qp_we ? '0 : rd_fin[s_rddone_qp] + 1'b1;
end

// ---------------- memory-window table ----------------
typedef struct packed {
    logic        valid;
    logic [1:0]  acc;
    logic [31:0] rkey;
    logic [63:0] va;
    logic [31:0] len;
    logic [63:0] laddr;
} mr_t;
localparam int MRWID = $bits(mr_t);
mr_t mr_d;
logic mr_re;
logic [MRW-1:0] mr_idx;
wire  mr_t mr_w = '{valid: cfg_mr_valid, acc: cfg_mr_acc, rkey: cfg_mr_rkey, va: cfg_mr_va,
                    len: cfg_mr_len, laddr: cfg_mr_laddr};
if (NUM_MR == 1) begin : g_mr1
    mr_t row;
    always_ff @(posedge clk) if (cfg_mr_we) row <= mr_w;
    assign mr_d = row;
end else begin : g_mr
    wire logic [MRWID-1:0] rd;
    rocelet_ram_sdp #(.WIDTH(MRWID), .DEPTH(NUM_MR), .RD_LAT(1), .RAM_STYLE("auto")) u_mr (
        .clk(clk), .we(cfg_mr_we), .waddr(cfg_mr_idx), .wdata(mr_w), .re(mr_re), .raddr(mr_idx), .rdata(rd)
    );
    assign mr_d = mr_t'(rd);
end

// ---------------- READ history (continuation of partial re-issues) ----------------
localparam int HAW = (READ_DEPTH > 1) ? $clog2(READ_DEPTH) : 1;     // entry index
localparam bit HIST = READ_EN && CONT_EN;
localparam int HDEPTH = NUM_QP * (1 << HAW);                         // {qp, entry} addressing
localparam int HW = 48;                                              // {first PSN, packets - 1}
logic            hw_we;
logic [QPW+HAW-1:0] hw_addr, hr_addr;
logic [HW-1:0]   hw_data;
wire  logic [HW-1:0] hr_data;
logic            hr_re;
(* ram_style = "distributed" *) logic [HAW-1:0] h_wp  [NUM_QP];   // next entry to write
(* ram_style = "distributed" *) logic [HAW:0]   h_cnt [NUM_QP];   // entries valid (saturating)
if (HIST) begin : g_hist
    if (HDEPTH > 1) begin : g_ram
        rocelet_ram_sdp #(.WIDTH(HW), .DEPTH(HDEPTH), .RD_LAT(1),
                          .RAM_STYLE((HDEPTH >= 128) ? "block" : "distributed")) u_hist (
            .clk(clk), .we(hw_we), .waddr(hw_addr), .wdata(hw_data), .re(hr_re), .raddr(hr_addr), .rdata(hr_data)
        );
    end else begin : g_reg
        logic [HW-1:0] row;
        always_ff @(posedge clk) if (hw_we) row <= hw_data;
        assign hr_data = row;
    end
    initial begin
        for (int q = 0; q < NUM_QP; q++) begin
            h_wp[q]  = '0;
            h_cnt[q] = '0;
        end
    end
end else begin : g_nohist
    assign hr_data = '0;
end

// ---------------- end-of-frame verdict queue ----------------
wire logic e_ok, e_v;
logic      e_pop;
rocelet_fifo #(.WIDTH(1), .DEPTH(4), .RAM_STYLE("registers")) u_endq (
    .clk(clk), .rst(rst), .din(s_end_ok), .wr_en(s_end_valid), .full(),
    .dout(e_ok), .valid(e_v), .rd_en(e_pop), .count()
);

// ---------------- packet FSM ----------------
typedef enum logic [3:0] {S_IDLE, S_CHK1, S_CHK2, S_DEC, S_HIST, S_CMD, S_PAY, S_END, S_COMMIT,
                          S_GAP} st_t;
st_t st = S_IDLE;

typedef enum logic [3:0] {A_DROP, A_WRITE, A_SEND, A_READ, A_NOPAY, A_ACKIN, A_DUP, A_DUPREAD,
                          A_NAK_SEQ, A_NAK_INV, A_NAK_ACC, A_RNR} act_t;
act_t act;

// latched header
logic [7:0]  h_op;
logic [QPW-1:0] h_qp;
logic        h_qp_ok, h_ackreq, h_mal;
logic [23:0] h_psn, h_msn;
logic [63:0] h_va;
logic [31:0] h_rkey, h_dmalen, h_imm;
logic [7:0]  h_syn;
logic [15:0] h_pl;

assign s_hdr_ready = (st == S_IDLE) && !cfg_qp_we;
wire logic hdr_fire = s_hdr_valid && s_hdr_ready;

always_comb begin
    cr_re  = hdr_fire;
    cr_qp  = s_hdr_dqpn[QPW-1:0];
    mr_re  = hdr_fire;
    mr_idx = s_hdr_rkey[MRW-1:0];
end

// opcode classes
wire logic [4:0] o5      = h_op[4:0];
wire logic       is_rc   = (h_op[7:5] == 3'b000);
wire logic       c_send  = (o5 <= 5'h05);
wire logic       c_wr    = (o5 >= 5'h06) && (o5 <= 5'h0B);
wire logic       c_rd    = (o5 == 5'h0C);
wire logic       c_ack   = (o5 == 5'h11);
wire logic       c_first = (o5 == 5'h00) || (o5 == 5'h06);
wire logic       c_mid   = (o5 == 5'h01) || (o5 == 5'h07);
wire logic       c_last  = (o5 == 5'h02) || (o5 == 5'h03) || (o5 == 5'h08) || (o5 == 5'h09);
wire logic       c_only  = (o5 == 5'h04) || (o5 == 5'h05) || (o5 == 5'h0A) || (o5 == 5'h0B);
wire logic       c_imm   = op_has_imm(h_op);

// stage CHK1 results
ctx_t        k_ctx;
logic        k_on, k_err, k_rnr;
logic [23:0] k_diff;
logic [3:0]  k_pm;
logic [64:0] k_off;          // VA - window base (bit 64 = borrow)
mr_t         k_mr;
logic [RCW-1:0] k_rdcnt;
logic [HAW:0]   k_hcnt;
logic [HAW-1:0] k_hwp;
// stage CHK2 results
logic        k_inb;
logic [63:0] k_laddr;
logic [23:0] k_npk;          // packets of a READ response

// READ history scan
logic [HAW:0]   hs_i;         // next entry to read
logic [HAW:0]   hs_n;         // entries compared
logic           hs_v1 = 1'b0; // read address registered (RAM reads next clock)
logic           hs_v2 = 1'b0; // entry data in hr_data
logic           hs_hit;
logic           x_cont;

// data path
logic [63:0] x_addr;
logic        wc_v = 1'b0;
logic        som;

wire logic pay_to_wr   = (st == S_PAY) && (act == A_WRITE);
wire logic pay_to_send = (st == S_PAY) && (act == A_SEND);
assign s_pay_tready  = (st == S_PAY) && (pay_to_wr ? m_wdat_tready : (pay_to_send ? m_send_tready : 1'b1));
assign m_wdat_tdata  = s_pay_tdata;
assign m_wdat_tkeep  = s_pay_tkeep;
assign m_wdat_tvalid = pay_to_wr && s_pay_tvalid;
assign m_wdat_tlast  = s_pay_tlast;
assign m_send_tdata  = s_pay_tdata;
assign m_send_tkeep  = s_pay_tkeep;
assign m_send_tvalid = SEND_EN && pay_to_send && s_pay_tvalid;
assign m_send_tlast  = s_pay_tlast;
assign m_send_qp     = h_qp;
assign m_send_som    = som;
assign m_send_eom    = c_last || c_only;

// outputs held in registers
logic           cpl_v = 1'b0, rsp_v = 1'b0, ack_v = 1'b0, se_v = 1'b0, se_ok;
logic           we_v = 1'b0, we_ok;
logic           o_cpl_send, o_cpl_imm_v, o_rsp_read, o_rsp_cont, o_rsp_dup;
logic [31:0]    o_cpl_imm, o_cpl_len;
logic [23:0]    o_rsp_psn, o_rsp_msn;
logic [7:0]     o_rsp_syn;
logic [63:0]    o_rsp_laddr;
logic [31:0]    o_rsp_len;
logic [7:0]     o_err_syn;
logic [QPW-1:0] o_cpl_qp, o_rsp_qp, o_ack_qp;
logic [3:0]     o_rsp_pmtu;
logic [23:0]    o_ack_psn, o_ack_msn;
logic [7:0]     o_ack_syn;

wire logic pl_eq_pmtu = (h_pl == (16'd1 << k_pm));
wire logic pl_le_pmtu = (h_pl <= (16'd1 << k_pm));

always_ff @(posedge clk) begin
    cw_we   <= 1'b0;
    rd_inc  <= 1'b0;
    ack_v   <= 1'b0;
    err_v   <= 1'b0;
    e_pop   <= 1'b0;
    se_v    <= 1'b0;
    we_v    <= 1'b0;
    hw_we   <= 1'b0;
    hr_re   <= 1'b0;
    hs_v1   <= 1'b0;
    hs_v2   <= hs_v1;
    ev_req  <= 1'b0;
    ev_dup  <= 1'b0;
    ev_seq  <= 1'b0;
    ev_drop <= 1'b0;
    ev_read <= 1'b0;
    ev_read_cont <= 1'b0;
    ev_rnr  <= 1'b0;
    if (m_wcmd_ready) wc_v <= 1'b0;
    if (m_cpl_ready) cpl_v <= 1'b0;
    if (m_rsp_ready) rsp_v <= 1'b0;

    case (st)
        S_IDLE: begin
            if (cfg_qp_we) begin
                cw_we <= 1'b1;
                cw_qp <= cfg_qp;
                cw_d  <= '{nak: 1'b0, opst: OPS_NONE, pmtu: PMTU_RUNTIME ? cfg_qp_pmtu : 4'(PMTU_LOG2),
                           resid: '0, mlen: '0, cur: '0, msn: '0, epsn: cfg_qp_epsn};
                if (HIST) begin
                    h_wp[cfg_qp]  <= '0;
                    h_cnt[cfg_qp] <= '0;
                end
            end else if (hdr_fire) begin
                h_op     <= s_hdr_opcode;
                h_qp     <= s_hdr_dqpn[QPW-1:0];
                h_qp_ok  <= (s_hdr_dqpn[23:QPW] == QPN_BASE[23:QPW]) &&
                            ((NUM_QP > 1) || (s_hdr_dqpn[0] == QPN_BASE[0])) &&
                            (int'(s_hdr_dqpn[QPW-1:0]) < NUM_QP);
                h_ackreq <= s_hdr_ackreq;
                h_psn    <= s_hdr_psn;
                h_va     <= s_hdr_va;
                h_rkey   <= s_hdr_rkey;
                h_dmalen <= s_hdr_dmalen;
                h_imm    <= s_hdr_imm;
                h_syn    <= s_hdr_syndrome;
                h_msn    <= s_hdr_msn;
                h_pl     <= s_hdr_paylen;
                h_mal    <= s_hdr_malformed;
                st       <= S_CHK1;
            end
        end
        S_CHK1: begin
            k_on    <= qp_on[h_qp];
            k_err   <= err_vec[h_qp];
            k_rnr   <= send_rnr[h_qp];
            k_ctx   <= cr_d;
            k_diff  <= h_psn - cr_d.epsn;
            k_pm    <= PMTU_RUNTIME ? cr_d.pmtu : 4'(PMTU_LOG2);
            k_mr    <= mr_d;
            k_off   <= {1'b0, h_va} - {1'b0, mr_d.va};
            k_rdcnt <= rd_iss[h_qp] - rd_fin[h_qp];
            if (HIST) begin
                k_hcnt <= h_cnt[h_qp];
                k_hwp  <= h_wp[h_qp];
            end
            st      <= S_CHK2;
        end
        S_CHK2: begin
            // in bounds: VA >= base and offset + length <= window length
            k_inb   <= !k_off[64] && (k_off[63:32] == 32'd0) &&
                       ({1'b0, k_off[31:0]} + {1'b0, h_dmalen} <= {1'b0, k_mr.len});
            k_laddr <= k_mr.laddr + k_off[63:0];
            k_npk   <= (h_dmalen == 32'd0) ? 24'd1 : 24'((h_dmalen - 32'd1) >> k_pm) + 24'd1;
            st      <= S_DEC;
        end
        S_DEC: begin
            logic key_ok, mem_ok;
            key_ok = k_mr.valid && (k_mr.rkey == h_rkey);
            mem_ok = (h_dmalen == 32'd0) ||
                     (key_ok && (c_rd ? k_mr.acc[1] : k_mr.acc[0]) && k_inb && (h_va[5:0] == 6'd0));
            som    <= c_first || c_only;
            x_cont <= 1'b0;
            st     <= S_CMD;
            if (!h_qp_ok || !k_on || k_err || h_mal) begin
                act <= A_DROP;
            end else if (!is_rc) begin
                act <= A_DROP;                          // UC/UD/CNP... (the responder is RC only)
            end else if (c_ack) begin
                act <= A_ACKIN;
            end else if (k_diff[23]) begin
                // duplicate (PSN behind ePSN): re-ACK; READs are re-executed if they still
                // address a valid window range
                if (c_rd && READ_EN) begin
                    act    <= mem_ok ? A_DUPREAD : A_DROP;
                    x_addr <= k_laddr;
                    if (HIST && cfg_read_cont && mem_ok && k_hcnt != '0) st <= S_HIST;
                end else begin
                    act <= A_DUP;
                end
            end else if (k_diff != 24'd0) begin
                act <= A_NAK_SEQ;
            end else if (((c_mid || c_last) && (k_ctx.opst != (c_send ? OPS_SEND : OPS_WRITE))) ||
                         ((c_first || c_only || c_rd) && k_ctx.opst != OPS_NONE) ||
                         ((c_first || c_mid) && !pl_eq_pmtu) || ((c_last || c_only) && !pl_le_pmtu) ||
                         (c_send && !SEND_EN) || (c_rd && !READ_EN) ||
                         (c_rd && k_rdcnt >= RCW'(READ_DEPTH)) ||
                         (c_wr && c_last && k_ctx.resid != {16'd0, h_pl}) ||
                         (c_wr && c_only && h_dmalen != {16'd0, h_pl}) ||
                         (!(c_send || c_wr || c_rd))) begin
                act <= A_NAK_INV;
            end else if ((c_wr && (c_first || c_only) && h_dmalen != 0) || (c_rd && h_dmalen != 0)) begin
                if (!mem_ok)
                    act <= A_NAK_ACC;
                else
                    act <= c_rd ? A_READ : (h_pl != 0 ? A_WRITE : A_NOPAY);
                x_addr <= k_laddr;
            end else if (c_send && (c_first || c_only) && k_rnr) begin
                act    <= A_RNR;                        // no receive buffer: RNR NAK, packet dropped
                x_addr <= k_ctx.cur;
            end else begin
                act    <= c_rd ? A_READ : ((h_pl == 0) ? A_NOPAY : (c_send ? A_SEND : A_WRITE));
                x_addr <= k_ctx.cur;
            end
            // history scan of a duplicate READ starts at the oldest entry
            hs_i   <= '0;
            hs_n   <= '0;
            hs_hit <= 1'b0;
        end
        S_HIST: begin
            // one entry read per clock (address and read registered, so the entry is in
            // hr_data two clocks later); hit: the PSN lies strictly inside an earlier READ
            // (0 < psn - first <= packets - 1)
            if (HIST) begin
                if (hs_i < k_hcnt) begin
                    hr_re   <= 1'b1;
                    hr_addr <= (QPW+HAW)'({h_qp, HAW'(hs_i)});
                    hs_i    <= hs_i + 1'b1;
                    hs_v1   <= 1'b1;
                end
                if (hs_v2) begin
                    logic [23:0] d;
                    d = h_psn - hr_data[47:24];
                    if ((d != 24'd0) && (d <= hr_data[23:0])) hs_hit <= 1'b1;
                    hs_n <= hs_n + 1'b1;
                end
                if (hs_n == k_hcnt) begin
                    x_cont <= hs_hit;
                    st     <= S_CMD;
                end
            end else begin
                st <= S_CMD;
            end
        end
        S_CMD: begin
            if (act == A_WRITE) begin
                // command accepted before its data (data-mover S2MM order)
                if (!wc_v) wc_v <= 1'b1;
                else if (m_wcmd_ready) st <= S_PAY;
            end else begin
                st <= (h_pl != 0) ? S_PAY : S_END;
            end
        end
        S_PAY: begin
            if (s_pay_tvalid && s_pay_tready && s_pay_tlast) st <= S_END;
        end
        S_END: begin
            if (e_v) begin
                e_pop <= 1'b1;
                se_v  <= SEND_EN && (act == A_SEND);
                se_ok <= e_ok;
                we_v  <= (act == A_WRITE);
                we_ok <= e_ok;
                st    <= e_ok ? S_COMMIT : S_GAP;
            end
        end
        S_COMMIT: begin
            // every output register used below must be free
            if ((!rsp_v || m_rsp_ready) && (!cpl_v || m_cpl_ready) && (!wc_v || m_wcmd_ready) &&
                (act != A_ACKIN || ack_room)) begin
                ctx_t n;
                logic done_msg;
                n = k_ctx;
                done_msg = c_last || c_only || c_rd;
                case (act)
                    A_WRITE, A_SEND, A_NOPAY, A_READ: begin
                        n.epsn  = c_rd ? k_ctx.epsn + k_npk : k_ctx.epsn + 24'd1;
                        n.msn   = k_ctx.msn + (done_msg ? 24'd1 : 24'd0);
                        n.nak   = 1'b0;
                        n.opst  = (c_first) ? (c_send ? OPS_SEND : OPS_WRITE) : (c_mid ? k_ctx.opst : OPS_NONE);
                        n.cur   = x_addr + {48'd0, h_pl};
                        n.resid = c_first ? (h_dmalen - {16'd0, h_pl}) : (k_ctx.resid - {16'd0, h_pl});
                        if (c_wr)
                            n.mlen = (c_first || c_only) ? h_dmalen : k_ctx.mlen;
                        else
                            n.mlen = ((c_first || c_only) ? 32'd0 : k_ctx.mlen) + {16'd0, h_pl};
                        cw_we  <= 1'b1;
                        ev_req <= 1'b1;
                        if ((c_last || c_only) && (c_send || c_imm)) begin
                            cpl_v       <= 1'b1;
                            o_cpl_send  <= c_send;
                            o_cpl_imm_v <= c_imm;
                            o_cpl_imm   <= h_imm;
                            o_cpl_len   <= n.mlen;
                        end
                        if (act == A_READ) begin
                            rsp_v <= 1'b1; o_rsp_read <= 1'b1; o_rsp_cont <= 1'b0; o_rsp_dup <= 1'b0;
                            o_rsp_psn <= h_psn;
                            o_rsp_syn <= SYN_ACK; o_rsp_msn <= n.msn;
                            o_rsp_laddr <= x_addr; o_rsp_len <= h_dmalen;
                            rd_inc  <= 1'b1;
                            ev_read <= 1'b1;
                            if (HIST) begin
                                // remember {first PSN, packets - 1}
                                hw_we   <= 1'b1;
                                hw_addr <= (QPW+HAW)'({h_qp, k_hwp});
                                hw_data <= {h_psn, k_npk - 24'd1};
                                h_wp[h_qp]  <= (READ_DEPTH == 1) ? '0 : k_hwp + 1'b1;
                                h_cnt[h_qp] <= (k_hcnt == (HAW+1)'(READ_DEPTH)) ? k_hcnt : k_hcnt + 1'b1;
                            end
                        end else if (h_ackreq) begin
                            rsp_v <= 1'b1; o_rsp_read <= 1'b0; o_rsp_psn <= h_psn;
                            o_rsp_syn <= SYN_ACK; o_rsp_msn <= n.msn;
                        end
                    end
                    A_DUP: begin
                        ev_dup <= 1'b1;
                        if (h_ackreq) begin
                            rsp_v <= 1'b1; o_rsp_read <= 1'b0; o_rsp_psn <= k_ctx.epsn - 24'd1;
                            o_rsp_syn <= SYN_ACK; o_rsp_msn <= k_ctx.msn;
                        end
                    end
                    A_DUPREAD: begin
                        // re-execute (the duplicate carries VA, R_Key and length; checked in S_DEC);
                        // no READ resource: the requester counts this READ once, as the original
                        rsp_v <= 1'b1; o_rsp_read <= 1'b1; o_rsp_cont <= x_cont; o_rsp_dup <= 1'b1;
                        o_rsp_psn <= h_psn;
                        o_rsp_syn <= SYN_ACK; o_rsp_msn <= k_ctx.msn;
                        o_rsp_laddr <= x_addr; o_rsp_len <= h_dmalen;
                        ev_dup <= 1'b1;
                        ev_read <= 1'b1;
                        ev_read_cont <= x_cont;
                    end
                    A_NAK_SEQ: begin
                        ev_seq <= 1'b1;
                        if (!k_ctx.nak) begin
                            rsp_v <= 1'b1; o_rsp_read <= 1'b0; o_rsp_psn <= k_ctx.epsn;
                            o_rsp_syn <= SYN_NAK_PSN_SEQ; o_rsp_msn <= k_ctx.msn;
                            n.nak = 1'b1;
                            cw_we <= 1'b1;
                        end
                    end
                    A_RNR: begin
                        // the requester retransmits from this PSN after the timer; later packets
                        // of the message are dropped silently (no NAK-sequence) until then
                        rsp_v <= 1'b1; o_rsp_read <= 1'b0; o_rsp_psn <= h_psn;
                        o_rsp_syn <= SYN_RNR_NAK | {3'd0, cfg_rnr_timer}; o_rsp_msn <= k_ctx.msn;
                        n.nak = 1'b1;
                        cw_we <= 1'b1;
                        ev_rnr <= 1'b1;
                    end
                    A_NAK_INV, A_NAK_ACC: begin
                        rsp_v <= 1'b1; o_rsp_read <= 1'b0; o_rsp_psn <= h_psn;
                        o_rsp_syn <= (act == A_NAK_INV) ? SYN_NAK_INV_REQ : SYN_NAK_REM_ACCESS;
                        o_rsp_msn <= k_ctx.msn;
                        err_v <= 1'b1;
                        o_err_syn <= (act == A_NAK_INV) ? SYN_NAK_INV_REQ : SYN_NAK_REM_ACCESS;
                    end
                    A_ACKIN: begin
                        ack_v <= 1'b1;
                    end
                    default: begin
                        ev_drop <= 1'b1;
                    end
                endcase
                cw_qp <= h_qp;
                cw_d  <= n;
                rd_inc_qp <= h_qp;
                o_cpl_qp  <= h_qp;
                o_rsp_qp  <= h_qp;
                o_rsp_pmtu <= k_pm;
                o_ack_qp  <= h_qp;
                o_ack_psn <= h_psn;
                o_ack_msn <= h_msn;
                o_ack_syn <= h_syn;
                o_err_qp  <= h_qp;
                st <= S_GAP;
            end
        end
        S_GAP: st <= S_IDLE;     // context write lands before the next read
        default: st <= S_IDLE;
    endcase
    if (rst) begin
        st     <= S_IDLE;
        wc_v   <= 1'b0;
        cpl_v  <= 1'b0;
        rsp_v  <= 1'b0;
        cw_we  <= 1'b0;
        rd_inc <= 1'b0;
        hw_we  <= 1'b0;
        err_v  <= 1'b0;
    end
end

assign m_wcmd_valid = wc_v;
assign m_wcmd_addr  = x_addr;
assign m_wcmd_len   = h_pl[12:0];

assign m_wend_valid = we_v;
assign m_wend_ok    = we_ok;

assign m_send_end_valid = se_v;
assign m_send_end_ok    = se_ok;

assign m_cpl_valid   = cpl_v;
assign m_cpl_qp      = o_cpl_qp;
assign m_cpl_send    = o_cpl_send;
assign m_cpl_has_imm = o_cpl_imm_v;
assign m_cpl_imm     = o_cpl_imm;
assign m_cpl_len     = o_cpl_len;

assign m_rsp_valid    = rsp_v;
assign m_rsp_read     = o_rsp_read;
assign m_rsp_cont     = o_rsp_cont;
assign m_rsp_dup      = o_rsp_dup;
assign m_rsp_qp       = o_rsp_qp;
assign m_rsp_psn      = o_rsp_psn;
assign m_rsp_syndrome = o_rsp_syn;
assign m_rsp_msn      = o_rsp_msn;
assign m_rsp_laddr    = o_rsp_laddr;
assign m_rsp_len      = o_rsp_len;
assign m_rsp_pmtu     = o_rsp_pmtu;

assign m_ack_valid    = ack_v;
assign m_ack_qp       = o_ack_qp;
assign m_ack_psn      = o_ack_psn;
assign m_ack_syndrome = o_ack_syn;
assign m_ack_msn      = o_ack_msn;

assign m_err_valid    = err_v;
assign m_err_qp       = o_err_qp;
assign m_err_syndrome = o_err_syn;

endmodule

`resetall
