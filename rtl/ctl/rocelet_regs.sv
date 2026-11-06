// SPDX-License-Identifier: MIT
//
// rocelet_regs - AXI4-Lite register file of rocelet (map: rocelet_regs_pkg, generated from
// regs/rocelet_regs.py; documented in docs/registers.md). Global configuration, staged QP
// and memory-window configuration with commit strobes, status, per-QP error causes and
// the statistics counters. One clock domain (the engine clock). Writes: AW and W are taken
// independently, the write takes effect when both are in, BRESP OKAY. Reads: fixed
// latency, RRESP OKAY (unmapped offsets read 0).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_regs
    import rocelet_regs_pkg::*;
#(
    parameter int          NUM_QP            = 16,
    parameter int          NUM_MR            = 16,
    parameter logic [23:0] QPN_BASE          = 24'h000100,
    parameter int          READ_DEPTH        = 16,
    parameter int          RTX_MODE_ID       = 0,       // 0 RING, 1 REREAD, 2 LOSSY
    parameter int          RING_BYTES        = 262144,
    parameter int          MAX_WR            = 128,
    parameter int          PMTU_LOG2         = 12,
    parameter bit          PMTU_RUNTIME      = 1'b1,
    parameter bit          RX_ICRC_EN        = 1'b1,
    parameter bit          IPV6_EN           = 1'b0,
    parameter bit          HSB_EN            = 1'b1,
    parameter bit          VLAN_EN           = 1'b1,
    parameter bit          PAUSE_EN          = 1'b1,
    parameter bit          ARP_EN            = 1'b1,
    parameter bit          OTHER_EN          = 1'b1,
    parameter bit          COUNTERS_EN       = 1'b1,
    parameter int          RX_FIFO_DEPTH     = 512,
    parameter int          TX_FIFO_DEPTH     = 512,
    parameter int          CLK_MHZ           = 322,
    parameter int          CLK_KHZ           = 0,       // 0 = CLK_MHZ x 1000
    parameter int          LINK_GBPS         = 100,
    parameter int          MAC_WIDTH         = 512,
    parameter bit          READ_CONT_DEFAULT = 1'b1,
    localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1,
    localparam int MRW = (NUM_MR > 1) ? $clog2(NUM_MR) : 1
) (
    input  wire logic              clk,
    input  wire logic              rst,

    // AXI4-Lite slave
    input  wire logic [15:0]       s_axil_awaddr,
    input  wire logic              s_axil_awvalid,
    output wire logic              s_axil_awready,
    input  wire logic [31:0]       s_axil_wdata,
    input  wire logic [3:0]        s_axil_wstrb,
    input  wire logic              s_axil_wvalid,
    output wire logic              s_axil_wready,
    output wire logic [1:0]        s_axil_bresp,
    output wire logic              s_axil_bvalid,
    input  wire logic              s_axil_bready,
    input  wire logic [15:0]       s_axil_araddr,
    input  wire logic              s_axil_arvalid,
    output wire logic              s_axil_arready,
    output wire logic [31:0]       s_axil_rdata,
    output wire logic [1:0]        s_axil_rresp,
    output wire logic              s_axil_rvalid,
    input  wire logic              s_axil_rready,

    // global configuration
    output logic                   ctl_reset,
    output logic                   ctl_rx_en,
    output logic                   ctl_tx_en,
    output logic                   ctl_read_cont,
    output logic                   ctl_loss_fatal,
    output logic                   ctl_vlan_rx_strip,
    output logic                   ctl_vlan_tx_tag,
    output logic                   ctl_arp_int,
    output logic                   ctl_other_rx_en,
    output logic                   ctl_pause_rx_en,
    output logic                   ctl_pause_rx_level,
    output logic                   ctl_pause_tx_en,
    output logic [47:0]            my_mac,
    output logic [31:0]            my_ip4,
    output logic [127:0]           my_ip6,
    output logic [7:0]             ip_tos,
    output logic [7:0]             ip_ttl,
    output logic [9:0]             tick_div,
    output logic [19:0]            ack_timeout,
    output logic [19:0]            rnr_min,
    output logic [19:0]            rnr_max,
    output logic [4:0]             rnr_nak_timer,
    output logic [7:0]             ackreq_n,
    output logic [15:0]            vlan_tci,
    output logic [15:0]            pause_xoff,
    output logic [15:0]            pause_xon,
    output logic [2:0]             retry_cnt,
    output logic [2:0]             rnr_retry,
    output logic [19:0]            pace_inc,
    output logic [15:0]            pace_burst,
    output logic [23:0]            link_grace,
    output logic [19:0]            pause_qclk,

    // QP / window configuration (one-clock strobes, data valid with them)
    output logic                   qp_we,
    output logic [QPW-1:0]         qp_idx,
    output logic                   qp_valid,
    output logic [1:0]             qp_type,
    output logic [23:0]            qp_sq_psn,
    output logic [23:0]            qp_rq_psn,
    output logic [3:0]             qp_pmtu,
    output logic                   qp_ipv6,
    output logic [47:0]            qp_dmac,
    output logic [127:0]           qp_dip,
    output logic [23:0]            qp_dqpn,
    output logic [15:0]            qp_sport,
    output logic [15:0]            qp_dport,
    output logic                   err_we,
    output logic [QPW-1:0]         err_qp,
    output logic                   mr_we,
    output logic [MRW-1:0]         mr_idx,
    output logic                   mr_valid,
    output logic [1:0]             mr_acc,
    output logic [31:0]            mr_rkey,
    output logic [63:0]            mr_va,
    output logic [31:0]            mr_len,
    output logic [63:0]            mr_laddr,

    // status
    input  wire logic              st_in_reset,
    input  wire logic              st_mac_rx_status,
    input  wire logic              st_link_up,
    input  wire logic              st_timer_hold,
    input  wire logic              st_pause_gate,
    input  wire logic              st_pause_req,
    input  wire logic [15:0]       st_pause_quanta,
    input  wire logic [15:0]       st_rx_fill,
    input  wire logic [15:0]       st_wr_outstanding,
    input  wire logic [23:0]       st_ring_used,
    input  wire logic [15:0]       st_vlan_last_tci,
    input  wire logic [NUM_QP-1:0] st_qp_err_req,
    input  wire logic [NUM_QP-1:0] st_qp_err_resp,
    input  wire logic              req_err_valid,
    input  wire logic [QPW-1:0]    req_err_qp,
    input  wire logic [7:0]        req_err_code,
    input  wire logic              resp_err_valid,
    input  wire logic [QPW-1:0]    resp_err_qp,
    input  wire logic [7:0]        resp_err_code,

    // statistics
    input  wire logic [NCNT-1:0]   ev,
    input  wire logic [6:0]        rx_bytes_add,
    input  wire logic [6:0]        tx_bytes_add,

    output logic                   irq
);

// ---------------- write channel ----------------
logic        aw_have = 1'b0, w_have = 1'b0, b_v = 1'b0;
logic [15:0] aw_a;
logic [31:0] w_d;
logic [3:0]  w_s;
assign s_axil_awready = !aw_have && !b_v;
assign s_axil_wready  = !w_have && !b_v;
assign s_axil_bvalid  = b_v;
assign s_axil_bresp   = 2'b00;
wire logic do_wr = aw_have && w_have && !b_v;
wire logic [15:0] wa = {aw_a[15:2], 2'b00};

function automatic logic [31:0] wmask(input logic [31:0] old, input logic [31:0] d, input logic [3:0] s);
    for (int i = 0; i < 4; i++) wmask[i*8 +: 8] = s[i] ? d[i*8 +: 8] : old[i*8 +: 8];
endfunction

// ---------------- configuration registers ----------------
localparam logic [31:0] CTRL_RST = 32'h00001AA6 | (READ_CONT_DEFAULT ? 32'h8 : 32'h0);
// engine clock in kHz; one PAUSE quantum (512 bit times at LINK_GBPS) in clocks x 256, rounded up
localparam longint KHZ = (CLK_KHZ != 0) ? longint'(CLK_KHZ) : longint'(CLK_MHZ) * 1000;
localparam longint QCLK_RST = (131072 * KHZ + longint'(LINK_GBPS) * 1000000 - 1) / (longint'(LINK_GBPS) * 1000000);
if (QCLK_RST < 1 || QCLK_RST > 1048575) begin : g_bad_qclk
    $error("rocelet_regs: PAUSE_QCLK reset value out of range (CLK_KHZ / LINK_GBPS)");
end
logic [31:0] r_ctrl, r_mac_lo, r_mac_hi, r_ip4, r_ip_hdr, r_tick, r_ackto, r_rnrmin, r_rnrmax, r_rnrnak,
             r_ackreq, r_vtci, r_pwm, r_retry, r_prate, r_pburst, r_lgrace, r_pqclk, r_ip6 [4];
logic [31:0] q_index, q_flags, q_sqpsn, q_rqpsn, q_pmtu, q_dmac_lo, q_dmac_hi, q_dip [4], q_dqpn, q_udp, q_ipv6;
logic [31:0] m_index, m_flags, m_rkey, m_va_lo, m_va_hi, m_len, m_la_lo, m_la_hi;
logic        clr_cnt, clr_err;

always_ff @(posedge clk) begin
    qp_we   <= 1'b0;
    mr_we   <= 1'b0;
    err_we  <= 1'b0;
    clr_cnt <= 1'b0;
    clr_err <= 1'b0;
    if (s_axil_awvalid && s_axil_awready) begin aw_have <= 1'b1; aw_a <= s_axil_awaddr; end
    if (s_axil_wvalid && s_axil_wready) begin w_have <= 1'b1; w_d <= s_axil_wdata; w_s <= s_axil_wstrb; end
    if (b_v && s_axil_bready) b_v <= 1'b0;
    if (do_wr) begin
        aw_have <= 1'b0;
        w_have  <= 1'b0;
        b_v     <= 1'b1;
        case (wa)
            R_CTRL:        r_ctrl   <= wmask(r_ctrl, w_d, w_s);
            R_CMD:         begin clr_cnt <= w_d[0] && w_s[0]; clr_err <= w_d[1] && w_s[0]; end
            R_MAC_LO:      r_mac_lo <= wmask(r_mac_lo, w_d, w_s);
            R_MAC_HI:      r_mac_hi <= wmask(r_mac_hi, w_d, w_s);
            R_IP4:         r_ip4    <= wmask(r_ip4, w_d, w_s);
            R_IP_HDR:      r_ip_hdr <= wmask(r_ip_hdr, w_d, w_s);
            R_TICK_DIV:    r_tick   <= wmask(r_tick, w_d, w_s);
            R_ACK_TIMEOUT: r_ackto  <= wmask(r_ackto, w_d, w_s);
            R_RNR_MIN:     r_rnrmin <= wmask(r_rnrmin, w_d, w_s);
            R_RNR_MAX:     r_rnrmax <= wmask(r_rnrmax, w_d, w_s);
            R_RNR_NAK_TIMER: r_rnrnak <= wmask(r_rnrnak, w_d, w_s);
            R_ACKREQ_N:    r_ackreq <= wmask(r_ackreq, w_d, w_s);
            R_VLAN_TCI:    r_vtci   <= wmask(r_vtci, w_d, w_s);
            R_PAUSE_WM:    r_pwm    <= wmask(r_pwm, w_d, w_s);
            R_RETRY:       r_retry  <= wmask(r_retry, w_d, w_s);
            R_PACE_RATE:   r_prate  <= wmask(r_prate, w_d, w_s);
            R_PACE_BURST:  r_pburst <= wmask(r_pburst, w_d, w_s);
            R_LINK_GRACE:  r_lgrace <= wmask(r_lgrace, w_d, w_s);
            R_PAUSE_QCLK:  r_pqclk  <= wmask(r_pqclk, w_d, w_s);
            R_QP_ERR_CMD:  begin err_we <= 1'b1; err_qp <= QPW'(w_d[7:0]); end
            R_QP_INDEX:    q_index  <= wmask(q_index, w_d, w_s);
            R_QP_FLAGS:    q_flags  <= wmask(q_flags, w_d, w_s);
            R_QP_SQ_PSN:   q_sqpsn  <= wmask(q_sqpsn, w_d, w_s);
            R_QP_RQ_PSN:   q_rqpsn  <= wmask(q_rqpsn, w_d, w_s);
            R_QP_PMTU:     q_pmtu   <= wmask(q_pmtu, w_d, w_s);
            R_QP_DMAC_LO:  q_dmac_lo <= wmask(q_dmac_lo, w_d, w_s);
            R_QP_DMAC_HI:  q_dmac_hi <= wmask(q_dmac_hi, w_d, w_s);
            R_QP_DIP0:     q_dip[0] <= wmask(q_dip[0], w_d, w_s);
            R_QP_DIP1:     q_dip[1] <= wmask(q_dip[1], w_d, w_s);
            R_QP_DIP2:     q_dip[2] <= wmask(q_dip[2], w_d, w_s);
            R_QP_DIP3:     q_dip[3] <= wmask(q_dip[3], w_d, w_s);
            R_QP_DQPN:     q_dqpn   <= wmask(q_dqpn, w_d, w_s);
            R_QP_UDP:      q_udp    <= wmask(q_udp, w_d, w_s);
            R_QP_IPV6:     q_ipv6   <= wmask(q_ipv6, w_d, w_s);
            R_QP_COMMIT:   qp_we    <= 1'b1;
            R_MR_INDEX:    m_index  <= wmask(m_index, w_d, w_s);
            R_MR_FLAGS:    m_flags  <= wmask(m_flags, w_d, w_s);
            R_MR_RKEY:     m_rkey   <= wmask(m_rkey, w_d, w_s);
            R_MR_VA_LO:    m_va_lo  <= wmask(m_va_lo, w_d, w_s);
            R_MR_VA_HI:    m_va_hi  <= wmask(m_va_hi, w_d, w_s);
            R_MR_LEN:      m_len    <= wmask(m_len, w_d, w_s);
            R_MR_LADDR_LO: m_la_lo  <= wmask(m_la_lo, w_d, w_s);
            R_MR_LADDR_HI: m_la_hi  <= wmask(m_la_hi, w_d, w_s);
            R_MR_COMMIT:   mr_we    <= 1'b1;
            R_IP6_0:       r_ip6[0] <= wmask(r_ip6[0], w_d, w_s);
            R_IP6_1:       r_ip6[1] <= wmask(r_ip6[1], w_d, w_s);
            R_IP6_2:       r_ip6[2] <= wmask(r_ip6[2], w_d, w_s);
            R_IP6_3:       r_ip6[3] <= wmask(r_ip6[3], w_d, w_s);
            default: ;
        endcase
    end
    if (rst) begin
        aw_have <= 1'b0; w_have <= 1'b0; b_v <= 1'b0;
        qp_we <= 1'b0; mr_we <= 1'b0; err_we <= 1'b0;
        r_ctrl <= CTRL_RST; r_mac_lo <= RST_MAC_LO; r_mac_hi <= RST_MAC_HI; r_ip4 <= RST_IP4;
        r_ip_hdr <= RST_IP_HDR; r_tick <= 32'(CLK_MHZ); r_ackto <= RST_ACK_TIMEOUT; r_rnrmin <= RST_RNR_MIN;
        r_rnrmax <= RST_RNR_MAX; r_rnrnak <= RST_RNR_NAK_TIMER; r_ackreq <= RST_ACKREQ_N; r_vtci <= RST_VLAN_TCI;
        r_pwm <= RST_PAUSE_WM; r_retry <= RST_RETRY; r_prate <= RST_PACE_RATE; r_pburst <= RST_PACE_BURST;
        r_lgrace <= RST_LINK_GRACE; r_pqclk <= 32'(QCLK_RST);
        for (int i = 0; i < 4; i++) begin r_ip6[i] <= '0; q_dip[i] <= '0; end
        q_index <= '0; q_flags <= '0; q_sqpsn <= '0; q_rqpsn <= '0; q_pmtu <= RST_QP_PMTU;
        q_dmac_lo <= '0; q_dmac_hi <= '0; q_dqpn <= '0; q_udp <= '0; q_ipv6 <= '0;
        m_index <= '0; m_flags <= '0; m_rkey <= '0; m_va_lo <= '0; m_va_hi <= '0; m_len <= '0;
        m_la_lo <= '0; m_la_hi <= '0;
    end
end

always_comb begin
    ctl_reset          = r_ctrl[0];
    ctl_rx_en          = r_ctrl[1];
    ctl_tx_en          = r_ctrl[2];
    ctl_read_cont      = r_ctrl[3];
    ctl_loss_fatal     = r_ctrl[4];
    ctl_vlan_rx_strip  = r_ctrl[5];
    ctl_vlan_tx_tag    = r_ctrl[6];
    ctl_arp_int        = r_ctrl[7];
    ctl_other_rx_en    = r_ctrl[8];
    ctl_pause_rx_en    = r_ctrl[9];
    ctl_pause_rx_level = r_ctrl[10];
    ctl_pause_tx_en    = r_ctrl[11];
    my_mac        = {r_mac_hi[15:0], r_mac_lo};
    my_ip4        = r_ip4;
    my_ip6        = {r_ip6[3], r_ip6[2], r_ip6[1], r_ip6[0]};
    ip_tos        = r_ip_hdr[7:0];
    ip_ttl        = r_ip_hdr[15:8];
    tick_div      = r_tick[9:0];
    ack_timeout   = r_ackto[19:0];
    rnr_min       = r_rnrmin[19:0];
    rnr_max       = r_rnrmax[19:0];
    rnr_nak_timer = r_rnrnak[4:0];
    ackreq_n      = r_ackreq[7:0];
    vlan_tci      = r_vtci[15:0];
    pause_xoff    = r_pwm[15:0];
    pause_xon     = r_pwm[31:16];
    retry_cnt     = r_retry[2:0];
    rnr_retry     = r_retry[6:4];
    pace_inc      = r_prate[19:0];
    pace_burst    = r_pburst[15:0];
    link_grace    = r_lgrace[23:0];
    pause_qclk    = r_pqclk[19:0];
    qp_idx        = QPW'(q_index);
    qp_valid      = q_flags[0];
    qp_type       = q_flags[2:1];
    qp_sq_psn     = q_sqpsn[23:0];
    qp_rq_psn     = q_rqpsn[23:0];
    qp_pmtu       = q_pmtu[3:0];
    qp_ipv6       = q_ipv6[0];
    qp_dmac       = {q_dmac_hi[15:0], q_dmac_lo};
    qp_dip        = {q_dip[3], q_dip[2], q_dip[1], q_dip[0]};
    qp_dqpn       = q_dqpn[23:0];
    qp_sport      = q_udp[15:0];
    qp_dport      = q_udp[31:16];
    mr_idx        = MRW'(m_index);
    mr_valid      = m_flags[0];
    mr_acc        = {m_flags[2], m_flags[1]};
    mr_rkey       = m_rkey;
    mr_va         = {m_va_hi, m_va_lo};
    mr_len        = m_len;
    mr_laddr      = {m_la_hi, m_la_lo};
end

// ---------------- per-QP state and error causes ----------------
logic [NUM_QP-1:0] qp_on = '0;
(* ram_style = "distributed" *) logic [7:0] req_code  [NUM_QP];
(* ram_style = "distributed" *) logic [7:0] resp_code [NUM_QP];
logic [31:0] last_req_err = '0, last_resp_err = '0;
logic        err_latch = 1'b0;
always_ff @(posedge clk) begin
    if (qp_we) begin
        qp_on[qp_idx]     <= qp_valid;
        req_code[qp_idx]  <= '0;
        resp_code[qp_idx] <= '0;
    end else begin
        if (req_err_valid) req_code[req_err_qp] <= req_err_code;
        if (resp_err_valid) resp_code[resp_err_qp] <= resp_err_code;
    end
    if (req_err_valid) begin
        last_req_err <= {1'b1, 15'd0, 8'(req_err_qp), req_err_code};
        err_latch    <= 1'b1;
    end
    if (resp_err_valid) begin
        last_resp_err <= {1'b1, 15'd0, 8'(resp_err_qp), resp_err_code};
        err_latch     <= 1'b1;
    end
    if (clr_err) begin
        last_req_err  <= '0;
        last_resp_err <= '0;
        err_latch     <= 1'b0;
    end
    irq <= err_latch && r_ctrl[12];
    if (rst) begin
        qp_on         <= '0;
        last_req_err  <= '0;
        last_resp_err <= '0;
        err_latch     <= 1'b0;
        irq           <= 1'b0;
    end
end
wire logic [255:0] err_map = 256'(st_qp_err_req | st_qp_err_resp);

// ---------------- counters ----------------
logic [31:0] cnt [NCNT];
logic [63:0] c64 [NCNT64];
logic [15:0] fill_max = '0;
if (COUNTERS_EN) begin : g_cnt
    always_ff @(posedge clk) begin
        for (int i = 0; i < NCNT; i++) cnt[i] <= (clr_cnt || rst) ? 32'd0 : cnt[i] + {31'd0, ev[i]};
        c64[C64_CYCLES]   <= (clr_cnt || rst) ? 64'd0 : c64[C64_CYCLES] + 64'd1;
        c64[C64_RX_BYTES] <= (clr_cnt || rst) ? 64'd0 : c64[C64_RX_BYTES] + {57'd0, rx_bytes_add};
        c64[C64_TX_BYTES] <= (clr_cnt || rst) ? 64'd0 : c64[C64_TX_BYTES] + {57'd0, tx_bytes_add};
        fill_max <= (clr_cnt || rst) ? 16'd0 : (st_rx_fill > fill_max ? st_rx_fill : fill_max);
    end
end else begin : g_nocnt
    always_comb begin
        for (int i = 0; i < NCNT; i++) cnt[i] = '0;
        for (int i = 0; i < NCNT64; i++) c64[i] = '0;
    end
end

// ---------------- read channel ----------------
// stage 1: address; stage 2: registers / status mux and counter mux; stage 3: select
logic        ar1 = 1'b0, ar2 = 1'b0, r_v = 1'b0;
logic [15:0] ra1;
logic [31:0] rd_reg, rd_cnt, r_d, hi_latch [NCNT64];
logic        sel_cnt;
assign s_axil_arready = !ar1 && !ar2 && !r_v;
assign s_axil_rvalid  = r_v;
assign s_axil_rdata   = r_d;
assign s_axil_rresp   = 2'b00;

function automatic logic [31:0] build0();
    return {COUNTERS_EN, PMTU_RUNTIME, OTHER_EN, ARP_EN, PAUSE_EN, VLAN_EN, HSB_EN, IPV6_EN, RX_ICRC_EN,
            2'(RTX_MODE_ID), 5'(READ_DEPTH), 7'(NUM_MR), 9'(NUM_QP)};
endfunction

always_ff @(posedge clk) begin
    ar1 <= s_axil_arvalid && s_axil_arready;
    if (s_axil_arvalid && s_axil_arready) ra1 <= {s_axil_araddr[15:2], 2'b00};
    // stage 2
    ar2 <= ar1;
    if (ar1) begin
        int ci;
        ci = (int'(ra1) - int'(R_CNT_BASE)) / 4;
        sel_cnt <= (ra1 >= R_CNT_BASE) && (ra1 < R_CNT_BASE + 16'(4 * NCNT));
        rd_cnt  <= (ci >= 0 && ci < NCNT) ? cnt[ci] : 32'd0;
        rd_reg  <= 32'd0;
        case (ra1)
            R_ID:            rd_reg <= 32'h52434C54;
            R_VERSION:       rd_reg <= {8'd0, VER_MAJOR, VER_MINOR, VER_PATCH};
            R_BUILD0:        rd_reg <= build0();
            R_BUILD1:        rd_reg <= {3'd0, 4'(PMTU_LOG2), 9'(MAX_WR), 16'(RTX_MODE_ID == 0 ? RING_BYTES / 1024 : 0)};
            R_BUILD2:        rd_reg <= {8'd0, QPN_BASE};
            R_BUILD3:        rd_reg <= {16'(TX_FIFO_DEPTH), 16'(RX_FIFO_DEPTH)};
            R_CAPS:          rd_reg <= {8'd0, 8'(LINK_GBPS), 16'(MAC_WIDTH)};
            R_CLK_KHZ:       rd_reg <= {8'd0, 24'(KHZ)};
            R_CTRL:          rd_reg <= r_ctrl;
            R_STATUS:        rd_reg <= {25'd0, st_timer_hold, st_link_up, err_latch, st_pause_req, st_pause_gate,
                                        st_mac_rx_status, st_in_reset};
            R_MAC_LO:        rd_reg <= r_mac_lo;
            R_MAC_HI:        rd_reg <= r_mac_hi;
            R_IP4:           rd_reg <= r_ip4;
            R_IP_HDR:        rd_reg <= r_ip_hdr;
            R_TICK_DIV:      rd_reg <= r_tick;
            R_ACK_TIMEOUT:   rd_reg <= r_ackto;
            R_RNR_MIN:       rd_reg <= r_rnrmin;
            R_RNR_MAX:       rd_reg <= r_rnrmax;
            R_RNR_NAK_TIMER: rd_reg <= r_rnrnak;
            R_ACKREQ_N:      rd_reg <= r_ackreq;
            R_VLAN_TCI:      rd_reg <= r_vtci;
            R_PAUSE_WM:      rd_reg <= r_pwm;
            R_RETRY:         rd_reg <= r_retry;
            R_PACE_RATE:     rd_reg <= r_prate;
            R_PACE_BURST:    rd_reg <= r_pburst;
            R_LINK_GRACE:    rd_reg <= {8'd0, r_lgrace[23:0]};
            R_PAUSE_QCLK:    rd_reg <= {12'd0, r_pqclk[19:0]};
            R_QP_INDEX:      rd_reg <= q_index;
            R_QP_FLAGS:      rd_reg <= q_flags;
            R_QP_SQ_PSN:     rd_reg <= q_sqpsn;
            R_QP_RQ_PSN:     rd_reg <= q_rqpsn;
            R_QP_PMTU:       rd_reg <= q_pmtu;
            R_QP_DMAC_LO:    rd_reg <= q_dmac_lo;
            R_QP_DMAC_HI:    rd_reg <= q_dmac_hi;
            R_QP_DIP0:       rd_reg <= q_dip[0];
            R_QP_DIP1:       rd_reg <= q_dip[1];
            R_QP_DIP2:       rd_reg <= q_dip[2];
            R_QP_DIP3:       rd_reg <= q_dip[3];
            R_QP_DQPN:       rd_reg <= q_dqpn;
            R_QP_UDP:        rd_reg <= q_udp;
            R_QP_IPV6:       rd_reg <= q_ipv6;
            R_QP_STATUS:     rd_reg <= {8'd0, resp_code[qp_idx], req_code[qp_idx], 5'd0,
                                        st_qp_err_resp[qp_idx], st_qp_err_req[qp_idx], qp_on[qp_idx]};
            R_MR_INDEX:      rd_reg <= m_index;
            R_MR_FLAGS:      rd_reg <= m_flags;
            R_MR_RKEY:       rd_reg <= m_rkey;
            R_MR_VA_LO:      rd_reg <= m_va_lo;
            R_MR_VA_HI:      rd_reg <= m_va_hi;
            R_MR_LEN:        rd_reg <= m_len;
            R_MR_LADDR_LO:   rd_reg <= m_la_lo;
            R_MR_LADDR_HI:   rd_reg <= m_la_hi;
            R_IP6_0:         rd_reg <= r_ip6[0];
            R_IP6_1:         rd_reg <= r_ip6[1];
            R_IP6_2:         rd_reg <= r_ip6[2];
            R_IP6_3:         rd_reg <= r_ip6[3];
            R_QP_ERR_MAP0:   rd_reg <= err_map[0 +: 32];
            R_QP_ERR_MAP1:   rd_reg <= err_map[32 +: 32];
            R_QP_ERR_MAP2:   rd_reg <= err_map[64 +: 32];
            R_QP_ERR_MAP3:   rd_reg <= err_map[96 +: 32];
            R_QP_ERR_MAP4:   rd_reg <= err_map[128 +: 32];
            R_QP_ERR_MAP5:   rd_reg <= err_map[160 +: 32];
            R_QP_ERR_MAP6:   rd_reg <= err_map[192 +: 32];
            R_QP_ERR_MAP7:   rd_reg <= err_map[224 +: 32];
            R_RX_FIFO_LEVEL: rd_reg <= {fill_max, st_rx_fill};
            R_WR_OUTSTANDING: rd_reg <= {16'd0, st_wr_outstanding};
            R_RING_USED:     rd_reg <= {8'd0, st_ring_used};
            R_LAST_REQ_ERR:  rd_reg <= last_req_err;
            R_LAST_RESP_ERR: rd_reg <= last_resp_err;
            R_PAUSE_STATUS:  rd_reg <= {14'd0, st_pause_req, st_pause_gate, st_pause_quanta};
            R_VLAN_LAST_TCI: rd_reg <= {16'd0, st_vlan_last_tci};
            R_CYCLES_LO:     begin rd_reg <= c64[C64_CYCLES][31:0];   hi_latch[C64_CYCLES]   <= c64[C64_CYCLES][63:32]; end
            R_CYCLES_HI:     rd_reg <= hi_latch[C64_CYCLES];
            R_RX_BYTES_LO:   begin rd_reg <= c64[C64_RX_BYTES][31:0]; hi_latch[C64_RX_BYTES] <= c64[C64_RX_BYTES][63:32]; end
            R_RX_BYTES_HI:   rd_reg <= hi_latch[C64_RX_BYTES];
            R_TX_BYTES_LO:   begin rd_reg <= c64[C64_TX_BYTES][31:0]; hi_latch[C64_TX_BYTES] <= c64[C64_TX_BYTES][63:32]; end
            R_TX_BYTES_HI:   rd_reg <= hi_latch[C64_TX_BYTES];
            default: ;
        endcase
    end
    // stage 3
    if (ar2) begin
        r_v <= 1'b1;
        r_d <= sel_cnt ? rd_cnt : rd_reg;
    end else if (r_v && s_axil_rready) begin
        r_v <= 1'b0;
    end
    if (rst) begin
        ar1 <= 1'b0;
        ar2 <= 1'b0;
        r_v <= 1'b0;
    end
end

endmodule

`resetall
