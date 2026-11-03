// SPDX-License-Identifier: MIT
//
// rocelet_ack_proc - requester ACK processing: per-QP send window, ACK / NAK decoding,
// ACK timeout, retry and RNR counters, RNR wait.
//
// Per QP: una (oldest unacknowledged PSN), nxt (next new PSN), retry and RNR counters,
// the time of the last progress, the RNR wait in force, an RNR-wait flag, the QP type
// (UC/HSB complete on send) and the error state (~110 bits). Events (packet sent,
// ACK/NAK received, configuration, forced error, timer scan) go through one
// read-modify-write pipeline (3 clocks per event) over a context RAM, so the cost grows
// with NUM_QP only by memory. Time is a free-running 20-bit microsecond counter
// (cfg_tick_div clocks per tick); a scanner visits one QP per free slot (256 QPs in
// about 2.4 us at 322 MHz), not a timer per QP.
// ACK (AETH syndrome 000xxxxx): una = PSN + 1 if PSN is inside [una, nxt) (a
// coalesced ACK retires everything it covers).
// NAK PSN sequence error: everything before PSN is acknowledged; then
//   MODE = 1 (go-back-N): retransmit from PSN (m_rtx), retry + 1;
//   MODE = 0 (lossy resume): tell the requester to resume NEW data at PSN (m_rtx =
//            "rewind next PSN"), the loss is counted.
// RNR NAK (001ttttt): implicit ACK of everything before PSN (never an ACK of PSN
// itself), then wait for the time the timer code ttttt stands for (IBTA table, 0.01 ms
// to 655 ms, clamped to [cfg_rnr_min, cfg_rnr_max]) and retransmit (resume) from PSN.
// After cfg_rnr_retry RNR NAKs without progress the QP fails (7 = retry for ever).
// NAK invalid request / remote access / remote operational: QP error.
// Timeout (packets outstanding and no progress for cfg_timeout us): MODE 1: retransmit
// from una; MODE 0: probe (m_rtx_probe): a zero-length RDMA WRITE with AckReq at PSN
// una-1, i.e. a duplicate the responder always re-ACKs (an out-of-sequence probe could
// be dropped silently after a lost NAK); the ACK reports the responder's ePSN - 1 and
// the requester resumes new data at una. After cfg_retry_cnt timeouts / NAK-sequence
// errors without progress the QP fails. With cfg_loss_fatal a NAK-sequence error or a
// timeout fails the QP at once.
// Link loss (link_up, v0.2): while link_up is low, and for cfg_link_grace ticks after it
// rises (the link partner may need seconds more than this side to come up), no ACK
// timeout is counted: a QP whose ACK becomes overdue meanwhile is only marked overdue (od),
// and times out at once (one retransmission of the window from una, retry + 1) when the
// hold ends. The elapsed time keeps running (t_prog is not touched), so a QP that is not
// yet overdue when the hold ends times out at its usual time. Nothing else is held: the
// RNR wait (a delay the responder asked for, not a loss detector; its expiry resends from
// the NAKed PSN and the held ACK timeout covers that resend if the link is down; RNR NAKs,
// not the wait, count against rnr_retry), retransmissions already requested by a NAK, and
// new packets still go out and are lost on a dead link, which the held timeout covers.
// The hold is armed once link_up has been seen high after reset, so a link_up input tied
// to 0 (or 1) behaves as v0.1.
// UC / HSB QPs (cfg_qp_uc): a packet counts as acknowledged when it is sent.
// m_rel (una moved) drives completion and buffer release; it has no back-pressure.
// qp_err is the error state of every QP (set by the events above or by cfg_err_we,
// cleared by a configuration write); the WR ring flushes the WRs of a failed QP.
// The context RAM is not cleared by rst: a per-QP "configured" bit (registers, cleared
// by rst, set by a configuration write) gates the ACK and timer events, so stale rows
// left by a previous run are never acted on after a reset.
// Lossy resume (MODE 0): every rewind flips the QP's generation bit (here and in
// rocelet_req_ctrl); a "sent" event of an older generation (a packet issued before the
// rewind reached the requester) must not advance nxt, or nxt ends up beyond the last
// PSN the responder will ever acknowledge.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_ack_proc
    import rocelet_pkg::*;
#(
    parameter int NUM_QP = 16,
    parameter bit MODE   = 1'b1,
    localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1
) (
    input  wire logic             clk,
    input  wire logic             rst,

    input  wire logic [9:0]       cfg_tick_div,       // clock cycles per microsecond
    input  wire logic [19:0]      cfg_timeout,        // ACK timeout, us
    input  wire logic [19:0]      cfg_rnr_min,        // RNR wait floor, us
    input  wire logic [19:0]      cfg_rnr_max,        // RNR wait cap, us
    input  wire logic [2:0]       cfg_retry_cnt,
    input  wire logic [2:0]       cfg_rnr_retry,      // 7 = for ever
    input  wire logic             cfg_loss_fatal,
    input  wire logic [23:0]      cfg_link_grace,     // ticks after link_up rises with timeouts still held
    input  wire logic             link_up,            // synchronous; 0 = link down (timeouts held)
    input  wire logic             cfg_qp_we,
    input  wire logic [QPW-1:0]   cfg_qp,
    input  wire logic [23:0]      cfg_psn,
    input  wire logic             cfg_qp_uc,
    input  wire logic             cfg_qp_valid,       // 0 = disabled: in the error state
    input  wire logic             cfg_err_we,
    input  wire logic [QPW-1:0]   cfg_err_qp,

    input  wire logic             s_sent_valid,
    output wire logic             s_sent_room,     // room for 4 more "sent" events
    input  wire logic [QPW-1:0]   s_sent_qp,
    input  wire logic [23:0]      s_sent_psn,
    input  wire logic             s_sent_gen,

    input  wire logic             s_ack_valid,
    output wire logic             s_ack_room,      // room for 4 more ACK events
    input  wire logic [QPW-1:0]   s_ack_qp,
    input  wire logic [23:0]      s_ack_psn,
    input  wire logic [7:0]       s_ack_syndrome,

    output wire logic             m_rel_valid,
    output wire logic [QPW-1:0]   m_rel_qp,
    output wire logic [23:0]      m_rel_una,

    output wire logic             m_rtx_valid,
    input  wire logic             m_rtx_ready,
    output wire logic [QPW-1:0]   m_rtx_qp,
    output wire logic [23:0]      m_rtx_psn,
    output wire logic             m_rtx_probe,

    output wire logic             m_err_valid,
    output wire logic [QPW-1:0]   m_err_qp,
    output wire logic [7:0]       m_err_code,
    output wire logic [NUM_QP-1:0] qp_err,

    output logic                  ev_rtx,         // a retransmission / resume / probe was requested
    output logic                  ev_timeout,     // an ACK timeout fired
    output logic                  ev_link_down,   // link_up fell (once armed)
    output logic                  st_hold         // ACK timeouts held (link down or grace)
);

typedef struct packed {
    logic        od;           // ACK overdue while the timeouts were held
    logic        uc;
    logic        gen;
    logic        probe;
    logic        err;
    logic        rnr_wait;
    logic [19:0] t_prog;
    logic [19:0] rnr_t;
    logic [2:0]  rnr;
    logic [2:0]  retry;
    logic [23:0] nxt;
    logic [23:0] una;
} st_t;
localparam int SW = $bits(st_t);

// ---------------- microsecond time ----------------
logic [9:0]  pre = '0;
logic [19:0] now = '0;
wire  logic  tick = (pre >= cfg_tick_div - 10'd1);
always_ff @(posedge clk) begin
    if (tick) begin
        pre <= '0;
        now <= now + 20'd1;
    end else begin
        pre <= pre + 10'd1;
    end
    if (rst) begin
        pre <= '0;
        now <= '0;
    end
end

// ---------------- link-down hold ----------------
logic        lk_q = 1'b0, armed = 1'b0, hold = 1'b0, lk_dn = 1'b0;
logic [23:0] grace = '0;
always_ff @(posedge clk) begin
    lk_q  <= link_up;
    lk_dn <= armed && lk_q && !link_up;
    if (link_up) armed <= 1'b1;
    if (!link_up)                   grace <= cfg_link_grace;
    else if (tick && grace != '0)   grace <= grace - 24'd1;
    hold  <= armed && (!link_up || grace != '0);
    if (rst) begin
        lk_q  <= 1'b0;
        lk_dn <= 1'b0;
        armed <= 1'b0;
        hold  <= 1'b0;
        grace <= '0;
    end
end
assign ev_link_down = lk_dn;
assign st_hold      = hold;

// ---------------- event queues ----------------
wire logic           sq_v, aq_v;
wire logic [QPW-1:0] sq_qp, aq_qp;
wire logic [23:0]    sq_psn, aq_psn;
wire logic           sq_gen;
wire logic [7:0]     aq_syn;
logic                sq_pop, aq_pop;
wire  logic [4:0]    sq_cnt, aq_cnt;
// the producers hold back while fewer than 4 entries are free (their decisions are
// registered, so up to 3 events can be on the way when the room flag drops)
rocelet_fifo #(.WIDTH(QPW + 25), .DEPTH(16), .RAM_STYLE("distributed")) u_sq (
    .clk(clk), .rst(rst), .din({s_sent_gen, s_sent_qp, s_sent_psn}), .wr_en(s_sent_valid), .full(),
    .dout({sq_gen, sq_qp, sq_psn}), .valid(sq_v), .rd_en(sq_pop), .count(sq_cnt)
);
rocelet_fifo #(.WIDTH(QPW + 32), .DEPTH(16), .RAM_STYLE("distributed")) u_aq (
    .clk(clk), .rst(rst), .din({s_ack_qp, s_ack_psn, s_ack_syndrome}), .wr_en(s_ack_valid), .full(),
    .dout({aq_qp, aq_psn, aq_syn}), .valid(aq_v), .rd_en(aq_pop), .count(aq_cnt)
);
logic sent_room_r = 1'b1, ack_room_r = 1'b1;
always_ff @(posedge clk) begin
    sent_room_r <= (sq_cnt <= 5'd10);
    ack_room_r  <= (aq_cnt <= 5'd10);
end
assign s_sent_room = sent_room_r;
assign s_ack_room  = ack_room_r;

// ---------------- context RAM ----------------
logic           c_we, c_re;
logic [QPW-1:0] c_waddr, c_raddr;
st_t            c_wdata, c_rdata;
if (NUM_QP == 1) begin : g_r1
    st_t row;
    always_ff @(posedge clk) if (c_we) row <= c_wdata;
    assign c_rdata = row;
end else begin : g_ram
    wire logic [SW-1:0] rd;
    rocelet_ram_sdp #(.WIDTH(SW), .DEPTH(NUM_QP), .RD_LAT(1), .RAM_STYLE("auto")) u_ctx (
        .clk(clk), .we(c_we), .waddr(c_waddr), .wdata(c_wdata), .re(c_re), .raddr(c_raddr), .rdata(rd)
    );
    assign c_rdata = st_t'(rd);
end

// ---------------- RMW pipeline: A = select + read, P = compare, B = update + write ----------------
// one event every 3 clocks; the next event's read follows the previous write
typedef enum logic [2:0] {E_SENT, E_ACK, E_SCAN, E_CFG, E_FORCE} ev_t;
logic [1:0]     ph = 2'd0;          // 0 = A, 1 = P, 2 = B
ev_t            a_ev;
logic [QPW-1:0] a_qp;
logic [23:0]    a_psn;
logic [7:0]     a_syn;
logic           a_gen, a_uc, a_valid;
logic [QPW-1:0] scan_qp = '0;

// output queue for retransmit / resume / probe requests
logic            r_we;
logic [QPW+24:0] r_din;
wire  logic [4:0] r_cnt;
rocelet_fifo #(.WIDTH(QPW + 25), .DEPTH(16), .RAM_STYLE("distributed")) u_rq (
    .clk(clk), .rst(rst), .din(r_din), .wr_en(r_we), .full(),
    .dout({m_rtx_qp, m_rtx_psn, m_rtx_probe}), .valid(m_rtx_valid), .rd_en(m_rtx_ready), .count(r_cnt)
);
wire logic rq_room = (r_cnt < 5'd12);

// configuration writes and forced errors wait for a free stage-A slot
logic           cfg_p = 1'b0, frc_p = 1'b0;
logic [QPW-1:0] cfg_p_qp, frc_p_qp;
logic [23:0]    cfg_p_psn;
logic           cfg_p_uc, cfg_p_valid;
always_ff @(posedge clk) begin
    if (cfg_qp_we) begin
        cfg_p     <= 1'b1;
        cfg_p_qp  <= cfg_qp;
        cfg_p_psn <= cfg_psn;
        cfg_p_uc  <= cfg_qp_uc;
        cfg_p_valid <= cfg_qp_valid;
    end else if (ph == 2'd0) begin
        cfg_p <= 1'b0;
    end
    if (cfg_err_we) begin
        frc_p    <= 1'b1;
        frc_p_qp <= cfg_err_qp;
    end else if (ph == 2'd0 && !cfg_p) begin
        frc_p <= 1'b0;
    end
    if (rst) begin
        cfg_p <= 1'b0;
        frc_p <= 1'b0;
    end
end

// event select in stage A
always_comb begin
    sq_pop  = 1'b0;
    aq_pop  = 1'b0;
    c_re    = 1'b0;
    c_raddr = scan_qp;
    if (ph == 2'd0 && !rst) begin
        c_re = 1'b1;
        if (cfg_p)                   c_raddr = cfg_p_qp;
        else if (frc_p)              c_raddr = frc_p_qp;
        else if (aq_v && rq_room)  begin aq_pop = 1'b1; c_raddr = aq_qp; end
        else if (sq_v)             begin sq_pop = 1'b1; c_raddr = sq_qp; end
        else                         c_raddr = scan_qp;
    end
end

function automatic logic in_win(input logic [23:0] p, input logic [23:0] lo, input logic [23:0] hi);
    // p in [lo, hi) modulo 2^24
    return (p - lo) < (hi - lo);
endfunction

// per-QP configured bits and error bits
logic [NUM_QP-1:0] qp_on = '0, err_vec = '0;
logic              a_on;
assign qp_err = err_vec;

// stage P: the row and every comparison the update needs, registered
st_t  s;
logic f_win, f_nakwin, f_new, f_empty, f_to, f_rnr, f_psn1_nxt, f_una_nxt;
logic [19:0] rnr_raw;
always_ff @(posedge clk) begin
    if (ph == 2'd1) begin
        a_on       <= qp_on[a_qp];
        s          <= c_rdata;
        f_win      <= in_win(a_psn, c_rdata.una, c_rdata.nxt);
        f_nakwin   <= in_win(a_psn, c_rdata.una, c_rdata.nxt) || (a_psn == c_rdata.nxt);
        f_new      <= ((a_psn - c_rdata.nxt) & 24'h800000) == 24'd0;
        f_empty    <= (c_rdata.una == c_rdata.nxt);
        f_to       <= (now - c_rdata.t_prog >= cfg_timeout);
        f_rnr      <= (now - c_rdata.t_prog >= c_rdata.rnr_t);
        f_psn1_nxt <= (a_psn + 24'd1 == c_rdata.nxt);
        f_una_nxt  <= (c_rdata.una == c_rdata.nxt);
        rnr_raw    <= rnr_code_us(a_syn[4:0]);
    end
end

// stage B: update (combinational), written back at the end of B
st_t  n;
logic b_rtx, b_rel, b_err, b_to;
logic [QPW+24:0] b_rdin;
logic [7:0] b_code;
wire  logic [19:0] rnr_wait = (rnr_raw < cfg_rnr_min) ? cfg_rnr_min :
                              (rnr_raw > cfg_rnr_max) ? cfg_rnr_max : rnr_raw;
always_comb begin
    n = s;
    b_rtx = 1'b0; b_err = 1'b0; b_to = 1'b0; b_rel = 1'b0;
    b_rdin = '0; b_code = '0;
    case (a_ev)
        E_CFG: begin
            n = '{od: 1'b0, uc: a_uc, gen: 1'b0, probe: 1'b0, err: !a_valid, rnr_wait: 1'b0, t_prog: now, rnr_t: '0,
                  rnr: '0, retry: '0, nxt: a_psn, una: a_psn};
            b_rel = 1'b1;
        end
        E_FORCE: begin
            if (!s.err) begin n.err = 1'b1; b_err = 1'b1; b_code = REQ_ERR_FORCED; end
        end
        E_SENT: begin
            if (MODE || a_gen == s.gen) begin               // lossy: not from before a rewind
                if (f_empty) begin n.t_prog = now; n.od = 1'b0; end   // window was empty: start timing
                if (f_new) n.nxt = a_psn + 24'd1;           // new PSN (not a retransmission / probe)
                if (s.uc && f_new) begin                     // UC / HSB: done when sent
                    n.una = a_psn + 24'd1;
                    b_rel = 1'b1;
                end
            end
        end
        E_ACK: begin
            if (!s.err && a_on && !s.uc) begin
                if (a_syn[7:5] == 3'b000) begin
                    if (f_win) begin
                        n.una = a_psn + 24'd1; n.retry = '0; n.rnr = '0; n.t_prog = now; n.od = 1'b0;
                        b_rel = 1'b1;
                    end
                    // lossy resume: the probe's ACK tells where the responder is;
                    // anything still outstanding after it was lost: resume at una
                    if (!MODE && s.probe) begin
                        n.probe = 1'b0;
                        n.t_prog = now;
                        n.od = 1'b0;
                        if (f_win ? !f_psn1_nxt : !f_una_nxt) begin
                            if (cfg_loss_fatal) begin
                                n.err = 1'b1; b_err = 1'b1; b_code = REQ_ERR_LOSS;
                            end else begin
                                b_rtx  = 1'b1;
                                b_rdin = {a_qp, n.una, 1'b0};
                                n.nxt  = n.una;
                                n.gen  = !s.gen;
                            end
                        end
                    end
                end else if (a_syn == SYN_NAK_PSN_SEQ || a_syn[7:5] == 3'b001) begin
                    if (f_nakwin) begin
                        n.una = a_psn;               // implicit ACK of everything before
                        n.t_prog = now;
                        n.od = 1'b0;
                        b_rel = 1'b1;
                        if (a_syn[7:5] == 3'b001) begin
                            // RNR NAK: wait for the decoded timer, then resend from PSN
                            n.rnr_wait = 1'b1;
                            n.rnr_t    = rnr_wait;
                            n.rnr      = s.rnr + 3'd1;
                            if (cfg_rnr_retry != 3'd7 && s.rnr == cfg_rnr_retry) begin
                                n.err = 1'b1; b_err = 1'b1; b_code = REQ_ERR_RNR;
                            end
                        end else begin
                            n.retry = s.retry + 3'd1;
                            if (cfg_loss_fatal) begin
                                n.err = 1'b1; b_err = 1'b1; b_code = REQ_ERR_LOSS;
                            end else if (s.retry == cfg_retry_cnt) begin
                                n.err = 1'b1; b_err = 1'b1; b_code = REQ_ERR_RETRY;
                            end else begin
                                b_rtx  = 1'b1;
                                b_rdin = {a_qp, a_psn, 1'b0};
                                if (!MODE) begin n.nxt = a_psn; n.gen = !s.gen; end   // lossy: new data continues at PSN
                            end
                        end
                    end
                end else if (a_syn[7:5] == 3'b011) begin
                    n.err = 1'b1; b_err = 1'b1; b_code = a_syn;
                end
            end
        end
        E_SCAN: begin
            if (!s.err && a_on && !s.uc) begin
                if (s.rnr_wait && f_rnr && rq_room) begin
                    n.rnr_wait = 1'b0; n.t_prog = now; n.od = 1'b0;
                    b_rtx = 1'b1; b_rdin = {a_qp, s.una, 1'b0};
                    if (!MODE) begin n.nxt = s.una; n.gen = !s.gen; end
                end else if (!s.rnr_wait && !f_empty && (f_to || s.od) && rq_room && hold) begin
                    n.od = 1'b1;                                  // overdue while held: nothing counted
                end else if (!s.rnr_wait && !f_empty && (f_to || s.od) && rq_room) begin
                    n.t_prog = now;
                    n.od     = 1'b0;
                    n.retry  = s.retry + 3'd1;
                    b_to = 1'b1;
                    if (cfg_loss_fatal) begin
                        n.err = 1'b1; b_err = 1'b1; b_code = REQ_ERR_LOSS;
                    end else if (s.retry == cfg_retry_cnt) begin
                        n.err = 1'b1; b_err = 1'b1; b_code = REQ_ERR_RETRY;
                    end else begin
                        b_rtx  = 1'b1;
                        if (MODE) b_rdin = {a_qp, s.una, 1'b0};               // go-back-N: retransmit
                        else begin b_rdin = {a_qp, s.una - 24'd1, 1'b1}; n.probe = 1'b1; end  // lossy: probe
                    end
                end
            end
        end
        default: ;
    endcase
end

always_comb begin
    c_we    = (ph == 2'd2);
    c_waddr = a_qp;
    c_wdata = n;
    r_we    = (ph == 2'd2) && b_rtx;
    r_din   = b_rdin;
end

logic           rel_v = 1'b0, err_v = 1'b0;
logic [QPW-1:0] rel_qp, err_qp;
logic [23:0]    rel_una;
logic [7:0]     err_code;

always_ff @(posedge clk) begin
    rel_v      <= 1'b0;
    err_v      <= 1'b0;
    ev_rtx     <= 1'b0;
    ev_timeout <= 1'b0;
    case (ph)
        2'd0: begin
            // stage A: latch the selected event (its context row is being read)
            ph <= rst ? 2'd0 : 2'd1;
            if (cfg_p)                    begin a_ev <= E_CFG;   a_qp <= cfg_p_qp; a_psn <= cfg_p_psn; a_uc <= cfg_p_uc; a_valid <= cfg_p_valid; end
            else if (frc_p)               begin a_ev <= E_FORCE; a_qp <= frc_p_qp; end
            else if (aq_v && rq_room)     begin a_ev <= E_ACK;   a_qp <= aq_qp;  a_psn <= aq_psn; a_syn <= aq_syn; end
            else if (sq_v)                begin a_ev <= E_SENT;  a_qp <= sq_qp;  a_psn <= sq_psn; a_gen <= sq_gen; end
            else begin
                a_ev <= E_SCAN; a_qp <= scan_qp;
                scan_qp <= (int'(scan_qp) == NUM_QP - 1) ? '0 : scan_qp + 1'b1;
            end
        end
        2'd1: ph <= 2'd2;
        default: begin
            ph      <= 2'd0;
            if (a_ev == E_CFG) begin
                qp_on[a_qp]   <= a_valid;
                err_vec[a_qp] <= !a_valid;
            end
            if (b_err) err_vec[a_qp] <= 1'b1;
            rel_v      <= b_rel;
            rel_qp     <= a_qp;
            rel_una    <= n.una;
            err_v      <= b_err;
            err_qp     <= a_qp;
            err_code   <= b_code;
            ev_rtx     <= b_rtx;
            ev_timeout <= b_to;
        end
    endcase
    if (rst) begin
        ph      <= 2'd0;
        rel_v   <= 1'b0;
        err_v   <= 1'b0;
        qp_on   <= '0;
        err_vec <= '0;
    end
end

assign m_rel_valid = rel_v;
assign m_rel_qp    = rel_qp;
assign m_rel_una   = rel_una;
assign m_err_valid = err_v;
assign m_err_qp    = err_qp;
assign m_err_code  = err_code;

endmodule

`resetall
