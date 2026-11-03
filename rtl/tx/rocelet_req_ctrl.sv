// SPDX-License-Identifier: MIT
//
// rocelet_req_ctrl - requester work-request engine: segments RDMA WRITE / WRITE with
// immediate / SEND / SEND with immediate work requests into packets and hands one
// descriptor per packet to the header builder.
//
// Work requests arrive on a stream (no send queue in memory, no WQE fetch, no
// doorbells): qp, class, remote VA, rkey, length, immediate, local address, wr_id,
// flags. The per-QP state is the next send PSN, the QP type and, with PMTU_RUNTIME,
// the path MTU (log2, 8..12 = 256..4096); with PMTU_RUNTIME = 0 every QP uses
// 2^PMTU_LOG2 and segmentation is a constant shift.
// QP types:
//   RC   FIRST / MIDDLE / LAST / ONLY; RETH on WRITE FIRST / ONLY (VA, rkey, DMA length
//        = WR length); ImmDt on the LAST / ONLY of the _IMM classes; AckReq on the last
//        packet of every message and every cfg_ackreq_n packets inside a message.
//   UC   the same opcodes | 0x20, no AckReq.
//   HSB  (Holoscan Sensor Bridge data plane, HSB_EN) WRITE classes: every packet a UC
//        RDMA WRITE Only (0x2A) with its own RETH (VA = WR VA + offset, DMA length =
//        this packet); the last packet of a WRITE_IMM WR is WRITE Only with Immediate
//        (0x2B) and carries imm = {PSN[19:0], wr imm[11:0]}; with the WR flag hsb_md
//        the builder also writes {0x00, PSN} into payload bytes 4..7 of that packet
//        (the PSN field of the HSB metadata record). MigReq 0, AckReq 0, as NVIDIA's
//        HSB IP. SEND classes are sent as UC SENDs.
// The SE flag of the WR is set on the last packet of SEND / WRITE_IMM messages.
// SRC_MM = 1: one read command (local address + offset, length) per packet for the
// payload source (the on-chip ring or memory), whose per-packet output follows the
// descriptor; SRC_MM = 0: the payload is a stream in WR order (one WR = one burst).
// Every WR is recorded (m_trk: qp, wr_id, first/last PSN and the WR fields) for the
// ACK / retransmission logic before its first packet; that port's back-pressure is the
// outstanding-WR window.
// REXMIT_EN: the go-back-N re-issue port: a WR record plus the PSN to restart from; the
// WR is re-segmented from that packet on (offset = (start - first PSN) x PMTU, RETH only
// if it restarts at the first packet), with the original PSNs; the next PSN is not
// touched.
// LOSSY_EN: the lossy-resume control port (rocelet_ack_proc MODE 0): rewind (the QP's
// next PSN := the responder's expected PSN; new data continues there) and probe (a
// zero-length RDMA WRITE Only with AckReq at the given PSN, a duplicate of the last
// acknowledged one, consuming no PSN). Each QP has a rewind generation bit, flipped by
// every rewind and carried on the descriptors (m_desc_gen), so rocelet_ack_proc can
// ignore the "sent" events of packets issued before a rewind took effect.
// A WR for a QP in the error state (qp_err) is recorded (it completes as FLUSHED) but
// sends nothing: with SRC_MM no packet is issued; without, its packets are issued as
// `drop` descriptors so that the payload stream is consumed.
// Priority: configuration > control > re-issue > new WR.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_req_ctrl
    import rocelet_pkg::*;
#(
    parameter int NUM_QP       = 16,
    parameter bit PMTU_RUNTIME = 1'b1,
    parameter int PMTU_LOG2    = 12,
    parameter bit HSB_EN       = 1'b1,
    parameter bit SRC_MM       = 1'b1,
    parameter bit REXMIT_EN    = 1'b1,
    parameter bit LOSSY_EN     = 1'b0,
    localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1
) (
    input  wire logic             clk,
    input  wire logic             rst,

    input  wire logic [7:0]       cfg_ackreq_n,     // AckReq every N packets in a message (0 = last only)
    input  wire logic [NUM_QP-1:0] qp_err,

    // per-QP send state initialisation
    input  wire logic             cfg_we,
    input  wire logic [QPW-1:0]   cfg_qp,
    input  wire logic [23:0]      cfg_psn,
    input  wire logic [3:0]       cfg_pmtu_log2,
    input  wire logic [1:0]       cfg_type,

    // work requests
    input  wire logic             s_wr_valid,
    output wire logic             s_wr_ready,
    input  wire logic [QPW-1:0]   s_wr_qp,
    input  wire logic [1:0]       s_wr_class,
    input  wire logic             s_wr_se,
    input  wire logic             s_wr_md,
    input  wire logic [63:0]      s_wr_va,
    input  wire logic [31:0]      s_wr_rkey,
    input  wire logic [31:0]      s_wr_len,
    input  wire logic [31:0]      s_wr_imm,
    input  wire logic [63:0]      s_wr_laddr,
    input  wire logic [15:0]      s_wr_id,

    // go-back-N re-issue (REXMIT_EN)
    input  wire logic             s_rex_valid,
    output wire logic             s_rex_ready,
    input  wire logic [QPW-1:0]   s_rex_qp,
    input  wire logic [1:0]       s_rex_class,
    input  wire logic             s_rex_se,
    input  wire logic [63:0]      s_rex_va,
    input  wire logic [31:0]      s_rex_rkey,
    input  wire logic [31:0]      s_rex_len,
    input  wire logic [31:0]      s_rex_imm,
    input  wire logic [63:0]      s_rex_laddr,
    input  wire logic [15:0]      s_rex_id,
    input  wire logic [23:0]      s_rex_first_psn,
    input  wire logic [23:0]      s_rex_start_psn,

    // lossy-resume control (LOSSY_EN): rewind next PSN / send a probe
    input  wire logic             s_ctl_valid,
    output wire logic             s_ctl_ready,
    input  wire logic [QPW-1:0]   s_ctl_qp,
    input  wire logic [23:0]      s_ctl_psn,
    input  wire logic             s_ctl_probe,

    // packet descriptors to the TX arbiter
    output wire logic             m_desc_valid,
    input  wire logic             m_desc_ready,
    output tx_desc_t              m_desc,
    output wire logic             m_desc_gen,

    // payload read commands (SRC_MM)
    output wire logic             m_rd_valid,
    input  wire logic             m_rd_ready,
    output wire logic [63:0]      m_rd_addr,
    output wire logic [12:0]      m_rd_len,

    // per-WR record
    output wire logic             m_trk_valid,
    input  wire logic             m_trk_ready,
    output wire logic [QPW-1:0]   m_trk_qp,
    output wire logic [15:0]      m_trk_id,
    output wire logic [23:0]      m_trk_first_psn,
    output wire logic [23:0]      m_trk_last_psn,
    output wire logic [1:0]       m_trk_class,
    output wire logic             m_trk_se,
    output wire logic [63:0]      m_trk_va,
    output wire logic [31:0]      m_trk_rkey,
    output wire logic [31:0]      m_trk_len,
    output wire logic [31:0]      m_trk_imm,
    output wire logic [63:0]      m_trk_laddr
);

localparam int ROWW = 2 + (PMTU_RUNTIME ? 4 : 0) + 24;    // {type, [pmtu], psn}

// ---------------- per-QP table ----------------
logic            tw_we;
logic [QPW-1:0]  tw_qp;
logic [ROWW-1:0] tw_data;
wire  logic [ROWW-1:0] t_rdata;
wire  logic      wr_fire  = s_wr_valid && s_wr_ready;
wire  logic      rex_fire = REXMIT_EN && s_rex_valid && s_rex_ready;
wire  logic      ctl_fire = LOSSY_EN && s_ctl_valid && s_ctl_ready;
wire  logic [QPW-1:0] rd_qp = ctl_fire ? s_ctl_qp : (rex_fire ? s_rex_qp : s_wr_qp);

if (NUM_QP == 1) begin : g_t1
    logic [ROWW-1:0] row;
    always_ff @(posedge clk) if (tw_we) row <= tw_data;
    assign t_rdata = row;
end else begin : g_t
    rocelet_ram_sdp #(.WIDTH(ROWW), .DEPTH(NUM_QP), .RD_LAT(1), .RAM_STYLE("auto")) u_t (
        .clk(clk), .we(tw_we), .waddr(tw_qp), .wdata(tw_data),
        .re(wr_fire || rex_fire || ctl_fire), .raddr(rd_qp), .rdata(t_rdata)
    );
end
wire logic [23:0] t_psn  = t_rdata[23:0];
wire logic [3:0]  t_pmtu = PMTU_RUNTIME ? t_rdata[27:24] : 4'(PMTU_LOG2);
wire logic [1:0]  t_type = t_rdata[ROWW-1 -: 2];

function automatic logic [ROWW-1:0] row(input logic [1:0] ty, input logic [3:0] pm, input logic [23:0] psn);
    if (PMTU_RUNTIME) return ROWW'({ty, pm, psn});
    else              return ROWW'({ty, psn});
endfunction

// rewind generation per QP (LOSSY_EN)
(* ram_style = "distributed" *) logic qgen [NUM_QP];
initial for (int q = 0; q < NUM_QP; q++) qgen[q] = 1'b0;

// ---------------- WR state machine ----------------
typedef enum logic [2:0] {S_IDLE, S_LOOK, S_TRK, S_PKT, S_DONE, S_CTL} st_t;
st_t st = S_IDLE;

logic [QPW-1:0] w_qp;
logic [1:0]     w_class;
logic           w_se, w_md;
logic [63:0]    w_va, w_laddr;
logic [31:0]    w_rkey, w_len, w_imm;
logic [15:0]    w_id;
logic [23:0]    w_psn0;        // first PSN
logic [23:0]    w_psn;         // PSN of the next packet
logic [3:0]     w_pmtu;        // log2
logic [1:0]     w_type;
logic           w_skip;        // QP in error: send nothing
logic [31:0]    w_rem;         // bytes not yet segmented
logic [31:0]    w_off;
logic           w_first;
logic [7:0]     w_since_ack;
logic           w_rex;          // re-issue: original PSNs, no next-PSN write-back, no record
logic           w_probe;
logic [23:0]    w_start;
logic [23:0]    c_psn;          // control: rewind PSN

wire  logic idle_ok = (st == S_IDLE) && !cfg_we && !tw_we;   // cfg writes only while idle; no read during the write-back
assign s_ctl_ready = LOSSY_EN && idle_ok;
assign s_rex_ready = REXMIT_EN && idle_ok && !(LOSSY_EN && s_ctl_valid);
// a new WR is only taken when its record will fit: waiting for window space inside the
// WR would block the re-issue path that frees it (deadlock)
assign s_wr_ready  = idle_ok && !(LOSSY_EN && s_ctl_valid) && !(REXMIT_EN && s_rex_valid) && m_trk_ready;

wire logic [3:0]  pm      = PMTU_RUNTIME ? w_pmtu : 4'(PMTU_LOG2);
wire logic [13:0] pmtu_b  = 14'd1 << pm;
wire logic        last_pk = (w_rem <= {18'd0, pmtu_b});
wire logic [12:0] pk_len  = last_pk ? w_rem[12:0] : pmtu_b[12:0];

// opcode
wire logic is_send = w_class[1];
wire logic is_imm  = w_class[0];
wire logic is_uc   = (w_type != QPT_RC);
wire logic is_hsb  = HSB_EN && (w_type == QPT_HSB);
wire logic hsb_wr  = is_hsb && !is_send;          // one WRITE Only per packet
logic [7:0] op;
always_comb begin
    if (hsb_wr)                  op = (is_imm && last_pk) ? OP_WRITE_ONLY_IMM : OP_WRITE_ONLY;
    else if (w_first && last_pk) op = is_send ? (is_imm ? OP_SEND_ONLY_IMM : OP_SEND_ONLY)
                                              : (is_imm ? OP_WRITE_ONLY_IMM : OP_WRITE_ONLY);
    else if (w_first)            op = is_send ? OP_SEND_FIRST : OP_WRITE_FIRST;
    else if (!last_pk)           op = is_send ? OP_SEND_MIDDLE : OP_WRITE_MIDDLE;
    else                         op = is_send ? (is_imm ? OP_SEND_LAST_IMM : OP_SEND_LAST)
                                              : (is_imm ? OP_WRITE_LAST_IMM : OP_WRITE_LAST);
    if (is_uc) op = op | OP_UC;
end

wire logic ackreq = !is_uc && (last_pk || ((cfg_ackreq_n != 8'd0) && (w_since_ack == cfg_ackreq_n - 8'd1)));

logic d_v = 1'b0;     // descriptor (and read command) pending
logic r_v = 1'b0;
wire  logic d_free = (!d_v || m_desc_ready) && (!SRC_MM || !r_v || m_rd_ready);

tx_desc_t       o_d;
logic [63:0]    o_raddr;
logic           o_gen;
logic           t_v = 1'b0;

always_ff @(posedge clk) begin
    tw_we <= 1'b0;
    if (m_desc_ready) d_v <= 1'b0;
    if (m_rd_ready) r_v <= 1'b0;

    case (st)
        S_IDLE: begin
            if (cfg_we) begin
                if (LOSSY_EN) qgen[cfg_qp] <= 1'b0;
                tw_we   <= 1'b1;
                tw_qp   <= cfg_qp;
                tw_data <= row(HSB_EN ? cfg_type : ((cfg_type != QPT_RC) ? QPT_UC : QPT_RC), cfg_pmtu_log2, cfg_psn);
            end else if (ctl_fire && !s_ctl_probe) begin
                w_qp  <= s_ctl_qp;
                c_psn <= s_ctl_psn;
                st    <= S_CTL;
            end else if (ctl_fire || rex_fire || wr_fire) begin
                w_qp    <= ctl_fire ? s_ctl_qp : (rex_fire ? s_rex_qp : s_wr_qp);
                w_class <= (rex_fire && !ctl_fire) ? s_rex_class : (ctl_fire ? WR_WRITE : s_wr_class);
                w_se    <= ctl_fire ? 1'b0 : (rex_fire ? s_rex_se : s_wr_se);
                w_md    <= wr_fire && !ctl_fire && !rex_fire && s_wr_md;
                w_va    <= ctl_fire ? 64'd0 : (rex_fire ? s_rex_va : s_wr_va);
                w_laddr <= ctl_fire ? 64'd0 : (rex_fire ? s_rex_laddr : s_wr_laddr);
                w_rkey  <= ctl_fire ? 32'd0 : (rex_fire ? s_rex_rkey : s_wr_rkey);
                w_len   <= ctl_fire ? 32'd0 : (rex_fire ? s_rex_len : s_wr_len);
                w_imm   <= rex_fire ? s_rex_imm : s_wr_imm;
                w_id    <= rex_fire ? s_rex_id : s_wr_id;
                w_rem   <= ctl_fire ? 32'd0 : (rex_fire ? s_rex_len : s_wr_len);
                w_skip  <= qp_err[rd_qp];
                w_off   <= '0;
                w_first <= 1'b1;
                w_since_ack <= '0;
                w_rex   <= rex_fire && !ctl_fire;
                w_probe <= ctl_fire;
                c_psn   <= s_ctl_psn;
                w_psn0  <= s_rex_first_psn;
                w_start <= s_rex_start_psn;
                st      <= S_LOOK;
            end
        end
        S_LOOK: begin
            // table row available; packet count = max(1, ceil(len / pmtu))
            w_pmtu <= t_pmtu;
            w_type <= t_type;
            if ((w_rex || w_probe) && w_skip && SRC_MM) begin
                st <= S_IDLE;                         // QP in error: nothing to resend
            end else if (w_rex) begin
                // restart inside the WR: skip the packets before the start PSN
                logic [31:0] skip;
                skip = {8'd0, w_start - w_psn0} << t_pmtu;
                w_psn   <= w_start;
                w_off   <= skip;
                w_rem   <= w_len - skip;
                w_first <= (skip == 32'd0);
                st      <= S_PKT;
            end else if (w_probe) begin
                // probe: a duplicate at the given PSN (una - 1), no PSN consumed
                w_psn  <= c_psn;
                st     <= S_PKT;
            end else begin
                w_psn0 <= t_psn;
                w_psn  <= t_psn;
                st     <= S_TRK;
            end
        end
        S_TRK: begin
            // one record per WR, accepted before its first packet (window gating)
            t_v <= 1'b1;
            if (t_v && m_trk_ready) begin
                t_v <= 1'b0;
                // a QP in error sends nothing (the record completes as FLUSHED)
                st  <= (w_skip && SRC_MM) ? S_IDLE : S_PKT;
            end
        end
        S_PKT: begin
            if (d_free) begin
                logic imm_pk;
                imm_pk = is_imm && last_pk;
                d_v          <= 1'b1;
                r_v          <= SRC_MM && (pk_len != 0) && !w_skip;
                o_d          <= '0;
                o_d.qp       <= 8'(w_qp);
                o_d.opcode   <= op;
                o_d.psn      <= w_psn;
                o_d.ackreq   <= ackreq;
                o_d.se       <= w_se && last_pk && (is_send || is_imm);
                o_d.mig0     <= is_hsb;
                o_d.md_patch <= hsb_wr && imm_pk && w_md && (pk_len >= 13'd8);
                o_d.drop     <= w_skip;
                o_d.va       <= hsb_wr ? (w_va + {32'd0, w_off}) : w_va;
                o_d.rkey     <= w_rkey;
                o_d.dmalen   <= hsb_wr ? {19'd0, pk_len} : w_len;
                o_d.imm      <= hsb_wr ? {w_psn[19:0], w_imm[11:0]} : w_imm;
                o_d.len      <= pk_len;
                o_raddr      <= w_laddr + {32'd0, w_off};
                o_gen        <= LOSSY_EN && qgen[w_qp];
                w_psn        <= w_psn + 24'd1;
                w_rem        <= w_rem - {19'd0, pk_len};
                w_off        <= w_off + {19'd0, pk_len};
                w_first      <= 1'b0;
                w_since_ack  <= ackreq ? 8'd0 : w_since_ack + 8'd1;
                if (last_pk) st <= S_DONE;
            end
        end
        S_DONE: begin
            // write back the next PSN (not for re-issues, probes or skipped WRs)
            tw_we   <= !w_rex && !w_probe && !w_skip;
            tw_qp   <= w_qp;
            tw_data <= row(w_type, w_pmtu, w_psn);
            st      <= S_IDLE;
        end
        S_CTL: begin
            // rewind: keep the type and PMTU, replace the next PSN, new generation
            if (LOSSY_EN) qgen[w_qp] <= !qgen[w_qp];
            tw_we   <= 1'b1;
            tw_qp   <= w_qp;
            tw_data <= row(t_type, t_pmtu, c_psn);
            st      <= S_IDLE;
        end
        default: st <= S_IDLE;
    endcase
    if (rst) begin
        st  <= S_IDLE;
        d_v <= 1'b0;
        r_v <= 1'b0;
        t_v <= 1'b0;
        tw_we <= 1'b0;
    end
end

// last PSN of the WR, for the record: psn0 + npk - 1 (HSB WRs have the same packet count)
wire logic [31:0] npk_m1 = (w_len == 0) ? 32'd0 : ((w_len - 32'd1) >> pm);
assign m_trk_valid     = t_v;
assign m_trk_qp        = w_qp;
assign m_trk_id        = w_id;
assign m_trk_first_psn = w_psn0;
assign m_trk_last_psn  = w_psn0 + npk_m1[23:0];
assign m_trk_class     = w_class;
assign m_trk_se        = w_se;
assign m_trk_va        = w_va;
assign m_trk_rkey      = w_rkey;
assign m_trk_len       = w_len;
assign m_trk_imm       = w_imm;
assign m_trk_laddr     = w_laddr;

assign m_desc_valid = d_v;
assign m_desc       = o_d;
assign m_desc_gen   = o_gen;

assign m_rd_valid = SRC_MM && r_v;
assign m_rd_addr  = o_raddr;
assign m_rd_len   = o_d.len;

endmodule

`resetall
