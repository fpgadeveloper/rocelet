// SPDX-License-Identifier: MIT
//
// rocelet_rx_parser - RoCE v2 receive parser / classifier / header strip at 512 bits.
//
// s_axis: Ethernet frames (no FCS) from the MAC, after the ICRC check
//         (rocelet_icrc_rx PASS_DATA = 1: tuser = ICRC bad on the last beat; the MAC
//         FCS-error flag can be OR-ed in).
// Classification on beat 0: EtherType 0x0800 (IPv4, IHL 5, not fragmented,
// protocol 17) or 0x86DD (IPV6_EN, next header 17), destination IP = my IP, UDP
// destination port 4791, BTH TVer 0, an RC/UC opcode this engine knows
// (0x00..0x11, UC 0x20..0x2B). CNPs (0x81) are reported (ev_cnp) and dropped (a
// ConnectX sends them even without ECN marking). Anything else is dropped (ev_drop);
// non-RoCE traffic is split off before this block (rocelet_rx_cls).
// Outputs, all in frame order:
//   m_hdr: one record per accepted RoCE frame, as soon as the headers are in
//          (beat 1, or beat 0 for single-beat frames): addresses, BTH, RETH,
//          AETH, ImmDt, payload length (from the IP/UDP length; Ethernet padding
//          ignored), malformed flag.
//   m_pay: the payload only (headers, pad bytes and ICRC stripped), realigned to
//          lane 0, tlast on its last beat; frames without payload send nothing.
//   m_end: one per m_hdr record after the frame's last beat: ok = ICRC good and
//          frame long enough. Consumers write payload cut-through and commit
//          (PSN, MSN, completions, ACK) only on ok.
// The payload realignment is an N-way byte multiplexer over the header lengths
// 54/58/70/74 (+20 with IPv6); SHIFT_GENERIC = 1 builds a 64-way one.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_rx_parser
    import rocelet_pkg::*;
#(
    parameter bit IPV6_EN       = 1'b0,
    parameter bit SHIFT_GENERIC = 1'b0
) (
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic [31:0]   my_ip4,
    input  wire logic [127:0]  my_ip6,

    input  wire logic [511:0]  s_axis_tdata,
    input  wire logic [63:0]   s_axis_tkeep,
    input  wire logic          s_axis_tvalid,
    output wire logic          s_axis_tready,
    input  wire logic          s_axis_tlast,
    input  wire logic          s_axis_tuser,

    output wire logic          m_hdr_valid,
    input  wire logic          m_hdr_ready,
    output wire logic          m_hdr_ipv6,
    output wire logic [127:0]  m_hdr_sip,
    output wire logic [7:0]    m_hdr_opcode,
    output wire logic          m_hdr_se,
    output wire logic [1:0]    m_hdr_padcnt,
    output wire logic [23:0]   m_hdr_dqpn,
    output wire logic          m_hdr_ackreq,
    output wire logic [23:0]   m_hdr_psn,
    output wire logic [63:0]   m_hdr_va,
    output wire logic [31:0]   m_hdr_rkey,
    output wire logic [31:0]   m_hdr_dmalen,
    output wire logic [7:0]    m_hdr_syndrome,
    output wire logic [23:0]   m_hdr_msn,
    output wire logic [31:0]   m_hdr_imm,
    output wire logic [15:0]   m_hdr_paylen,
    output wire logic          m_hdr_malformed,

    output wire logic [511:0]  m_pay_tdata,
    output wire logic [63:0]   m_pay_tkeep,
    output wire logic          m_pay_tvalid,
    input  wire logic          m_pay_tready,
    output wire logic          m_pay_tlast,

    output wire logic          m_end_valid,
    output wire logic          m_end_ok,

    output logic               ev_cnp,          // a CNP was dropped
    output logic               ev_drop          // a frame was dropped (not a RoCE frame for this engine)
);

function automatic logic [7:0] B(input logic [511:0] d, input int i);
    return d[i*8 +: 8];
endfunction

function automatic logic [63:0] therm(input logic [6:0] n);
    for (int i = 0; i < 64; i++) therm[i] = (i < n);
endfunction

// ---------------- beat-0 classification ----------------
// Two clocks after beat 0 is taken (C1: classify the registered beat, C2: act
// on the registered result), so the 128-bit address compare and the length
// arithmetic are never in series with the input or the decisions; the input
// pauses for those two clocks once per frame (the 512-bit path has 65 % headroom
// over 100 Gb/s).
logic [511:0]  h0, h1;
wire logic [511:0] d0 = h0;
wire logic [15:0]  et = {B(d0, 12), B(d0, 13)};
wire logic         v4 = (et == 16'h0800) && (B(d0, 14) == 8'h45) && (B(d0, 23) == 8'd17) &&
                        ((B(d0, 20) & 8'h3F) == 8'h00) && (B(d0, 21) == 8'h00) &&
                        ({B(d0, 30), B(d0, 31), B(d0, 32), B(d0, 33)} == my_ip4);
wire logic [7:0] b43 = B(d0, 43);
wire logic [7:0] b63 = B(d0, 63);
logic v6;
always_comb begin
    v6 = IPV6_EN && (et == 16'h86DD) && (B(d0, 14) >> 4 == 8'h6) && (B(d0, 20) == 8'd17);
    for (int i = 0; i < 16; i++) if (B(d0, 38 + i) != my_ip6[(15-i)*8 +: 8]) v6 = 1'b0;
end
wire logic [7:0]  op0   = v6 ? B(d0, 62) : B(d0, 42);
wire logic [15:0] dport = v6 ? {B(d0, 56), B(d0, 57)} : {B(d0, 36), B(d0, 37)};
wire logic [3:0]  tver  = v6 ? b63[3:0] : b43[3:0];
wire logic        op_rc = (op0 <= OP_ACK);
wire logic        op_uc = (op0[7:5] == 3'b001) && (op0[4:0] <= 5'h0B);
wire logic        is_cnp = (op0 == 8'h81);
wire logic        udp_ok = (v4 || v6) && (dport == ROCE_UDP_PORT) && (tver == 4'h0);
wire logic        roce0 = udp_ok && (op_rc || op_uc);
wire logic [6:0]  hlen0 = (v6 ? 7'd74 : 7'd54) + 7'(op_ext_len(op0));
wire logic [15:0] udp_len0 = v6 ? {B(d0, 58), B(d0, 59)} : {B(d0, 38), B(d0, 39)};
wire logic [1:0]  pad0  = v6 ? b63[5:4] : b43[5:4];
// payload = UDP length - UDP 8 - BTH 12 - ext - pad - ICRC 4
wire logic [16:0] pl0 = {1'b0, udp_len0} - 17'd24 - 17'(op_ext_len(op0)) - 17'(pad0);

// ---------------- frame state ----------------
logic          f_in = 1'b0;     // inside a frame (beat 0 seen)
logic [6:0]    f_k;             // index of the next input beat
logic          f_roce;
logic          f_ipv6;
logic [5:0]    f_s;             // H mod 64
logic          f_hb;            // H >= 64
logic [15:0]   f_pl;            // payload bytes
logic          f_mal;
logic [6:0]    f_np;            // payload beats
logic [6:0]    f_pk;            // payload beats emitted
logic [511:0]  prev;
logic          flush = 1'b0;    // one payload beat left after the frame's last beat
logic          f_bad;

// header capture
logic          dec_go = 1'b0;   // decode h0/h1 this cycle
logic [1:0]    cls = 2'd0;      // 1 = C1, 2 = C2
logic          f_single;        // the frame is one beat
logic          c_roce, c_v6, c_cnp, c_udp;
logic [16:0]   c_pl;
logic [6:0]    c_hlen;

// output registers
logic [511:0]  p_data;
logic [63:0]   p_keep;
logic          p_valid = 1'b0, p_last;
wire  logic    p_slot = !p_valid || m_pay_tready;

logic          hd_valid = 1'b0;
wire  logic    hd_slot = !hd_valid || m_hdr_ready;

// payload beat produced by this input beat (index f_k >= 1, payload index f_k-1-HB)
wire  logic       in_first = !f_in;
wire  logic       pay_now  = f_in && f_roce && (f_k >= 7'd1 + {6'd0, f_hb}) && (f_pk < f_np);

// input can move when: no flush pending, header decode slot free for beats 0/1,
// payload output slot free when this beat produces payload
wire  logic       need_hd = !in_first && (f_k == 7'd1) && f_roce;
assign s_axis_tready = !flush && !dec_go && (cls == 2'd0) && (!need_hd || hd_slot) && (!pay_now || p_slot);
wire  logic       in_fire = s_axis_tvalid && s_axis_tready;

wire logic [511:0] shifted;
localparam int NSH = IPV6_EN ? 7 : 4;
localparam logic [NSH*8-1:0] SHL = IPV6_EN ?
    {8'd30, 8'd26, 8'd14, 8'd10, 8'd58, 8'd54, 8'd6} : {8'd54, 8'd58, 8'd6, 8'd10};
rocelet_byte_shift #(.GENERIC(SHIFT_GENERIC), .NS(NSH), .SLIST(SHL)) u_sh (
    .lo(prev), .hi(flush ? 512'd0 : s_axis_tdata), .sh(f_s), .y(shifted)
);

logic        e_valid = 1'b0, e_ok;

always_ff @(posedge clk) begin
    dec_go  <= 1'b0;
    e_valid <= 1'b0;
    ev_cnp  <= 1'b0;
    ev_drop <= 1'b0;
    if (m_pay_tready) p_valid <= 1'b0;

    if (flush && p_slot) begin
        flush   <= 1'b0;
        p_valid <= 1'b1;
        p_data  <= shifted;
        p_last  <= 1'b1;
        p_keep  <= therm((f_pl[5:0] == 6'd0) ? 7'd64 : {1'b0, f_pl[5:0]});
        f_pk    <= f_pk + 7'd1;
        e_valid <= 1'b1;
        e_ok    <= !f_bad;
    end

    // C1: classify the registered beat 0
    if (cls == 2'd1) begin
        c_roce <= roce0;
        c_v6   <= v6;
        c_cnp  <= is_cnp;
        c_udp  <= udp_ok;
        c_pl   <= pl0;
        c_hlen <= hlen0;
        cls    <= 2'd2;
    end
    // C2: act on it (a single-beat RoCE frame also needs the header slot)
    if (cls == 2'd2 && !(c_roce && f_single && !hd_slot)) begin
        cls    <= 2'd0;
        f_roce <= c_roce;
        f_ipv6 <= c_v6;
        f_s    <= c_hlen[5:0];
        f_hb   <= c_hlen[6];
        f_pl   <= c_pl[15:0];
        f_mal  <= c_pl[16] || (c_pl[15:0] > 16'd4096);
        f_np   <= c_pl[16] ? 7'd0 : 7'((c_pl[12:0] + 13'd63) >> 6);
        ev_cnp  <= !c_roce && c_cnp && c_udp;
        ev_drop <= !c_roce && !(c_cnp && c_udp);
        if (f_single && c_roce) begin
            h1     <= '0;
            dec_go <= 1'b1;
            // a single-beat frame's payload (if any) is a flush beat
            if (!c_pl[16] && c_pl[15:0] != 0) flush <= 1'b1;
            else begin e_valid <= 1'b1; e_ok <= !f_bad && !c_pl[16]; end
        end
    end

    if (in_fire) begin
        prev <= s_axis_tdata;
        if (in_first) begin
            f_in     <= !s_axis_tlast;
            f_single <= s_axis_tlast;
            f_k      <= 7'd1;
            f_roce   <= 1'b0;
            f_pk     <= '0;
            f_bad    <= s_axis_tuser;
            h0       <= s_axis_tdata;
            cls      <= 2'd1;
        end else begin
            f_k   <= f_k + 7'd1;
            f_bad <= f_bad | s_axis_tuser;
            if (f_k == 7'd1) begin
                h1 <= s_axis_tdata;
                if (f_roce) dec_go <= 1'b1;
            end
            if (pay_now) begin
                p_valid <= 1'b1;
                p_data  <= shifted;
                p_last  <= (f_pk == f_np - 7'd1);
                p_keep  <= (f_pk == f_np - 7'd1) ?
                           therm((f_pl[5:0] == 6'd0) ? 7'd64 : {1'b0, f_pl[5:0]}) : '1;
                f_pk    <= f_pk + 7'd1;
            end
            if (s_axis_tlast) begin
                f_in <= 1'b0;
                if (f_roce) begin
                    if (pay_now ? (f_pk + 7'd1 < f_np) : (f_pk < f_np)) begin
                        flush <= 1'b1;
                    end else begin
                        e_valid <= 1'b1;
                        e_ok    <= !(f_bad | s_axis_tuser) && !f_mal;
                    end
                end
            end
        end
    end
    if (rst) begin
        f_in    <= 1'b0;
        cls     <= 2'd0;
        flush   <= 1'b0;
        p_valid <= 1'b0;
        dec_go  <= 1'b0;
        e_valid <= 1'b0;
    end
end

// ---------------- header decode (h0/h1 = frame bytes 0..127) ----------------
logic [7:0] hb [128];
always_comb begin
    for (int i = 0; i < 64; i++) begin
        hb[i]      = h0[i*8 +: 8];
        hb[64 + i] = h1[i*8 +: 8];
    end
end

logic         r_ipv6, r_se, r_ackreq, r_mal;
logic [127:0] r_sip;
logic [7:0]   r_op, r_syn;
logic [1:0]   r_pad;
logic [23:0]  r_dqpn, r_psn, r_msn;
logic [63:0]  r_va;
logic [31:0]  r_rkey, r_dmalen, r_imm;
logic [15:0]  r_pl;

always_ff @(posedge clk) begin
    int u, e;
    logic [7:0] op;
    if (m_hdr_ready) hd_valid <= 1'b0;
    if (dec_go) begin
        u = (IPV6_EN && f_ipv6) ? 54 : 34;
        op = hb[u+8];
        hd_valid <= 1'b1;
        r_ipv6   <= IPV6_EN && f_ipv6;
        r_sip    <= '0;
        if (IPV6_EN && f_ipv6) begin
            for (int i = 0; i < 16; i++) r_sip[(15-i)*8 +: 8] <= hb[22 + i];
        end else begin
            r_sip[31:0] <= {hb[26], hb[27], hb[28], hb[29]};
        end
        r_op     <= op;
        r_se     <= hb[u+9][7];
        r_pad    <= hb[u+9][5:4];
        r_dqpn   <= {hb[u+13], hb[u+14], hb[u+15]};
        r_ackreq <= hb[u+16][7];
        r_psn    <= {hb[u+17], hb[u+18], hb[u+19]};
        e = u + 20;
        r_va     <= {hb[e], hb[e+1], hb[e+2], hb[e+3], hb[e+4], hb[e+5], hb[e+6], hb[e+7]};
        r_rkey   <= {hb[e+8], hb[e+9], hb[e+10], hb[e+11]};
        r_dmalen <= {hb[e+12], hb[e+13], hb[e+14], hb[e+15]};
        r_syn    <= hb[e];
        r_msn    <= {hb[e+1], hb[e+2], hb[e+3]};
        r_imm    <= op_has_reth(op) ? {hb[e+16], hb[e+17], hb[e+18], hb[e+19]}
                                    : {hb[e], hb[e+1], hb[e+2], hb[e+3]};
        r_pl     <= f_pl;
        r_mal    <= f_mal;
    end
    if (rst) hd_valid <= 1'b0;
end

assign m_hdr_valid     = hd_valid;
assign m_hdr_ipv6      = r_ipv6;
assign m_hdr_sip       = r_sip;
assign m_hdr_opcode    = r_op;
assign m_hdr_se        = r_se;
assign m_hdr_padcnt    = r_pad;
assign m_hdr_dqpn      = r_dqpn;
assign m_hdr_ackreq    = r_ackreq;
assign m_hdr_psn       = r_psn;
assign m_hdr_va        = r_va;
assign m_hdr_rkey      = r_rkey;
assign m_hdr_dmalen    = r_dmalen;
assign m_hdr_syndrome  = r_syn;
assign m_hdr_msn       = r_msn;
assign m_hdr_imm       = r_imm;
assign m_hdr_paylen    = r_pl;
assign m_hdr_malformed = r_mal;

assign m_pay_tdata  = p_data;
assign m_pay_tkeep  = p_keep;
assign m_pay_tvalid = p_valid;
assign m_pay_tlast  = p_last;

assign m_end_valid = e_valid;
assign m_end_ok    = e_ok;

endmodule

`resetall
