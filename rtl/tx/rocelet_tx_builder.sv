// SPDX-License-Identifier: MIT
//
// rocelet_tx_builder - RoCE v2 packetiser: turns a packet descriptor plus its payload
// into an Ethernet / IPv4 (or IPv6) / UDP / BTH [/ RETH | AETH] [/ ImmDt] frame
// at 512 bits. The ICRC is appended downstream (rocelet_icrc_tx), the FCS by the CMAC.
//
// One builder serves every TX packet source of the engine (requester data, ACK
// generator, READ responses) through its descriptor port, so the per-QP
// destination (MAC, IP, dest QPN, UDP source port, IP version) lives here, once:
// a NUM_QP-entry address table written through cfg_*. The IPv4 header checksum
// is precomputed per QP at configuration time (all fields except the total
// length are per-QP or global constants), so the packet path adds one 16-bit
// one's-complement term. ID = 0 with DF set (RFC 6864 atomic datagrams); UDP
// checksum 0 (RoCE v2 allows it, CX NICs send 0); UDP destination port 4791, or
// the QP's configured port (HSB Linux-UDP receivers); P_Key 0xFFFF, TVer 0, BTH
// MigReq 1 (ConnectX interop) except on descriptors marked mig0 (HSB format: 0).
//
// Descriptor (rocelet_pkg::tx_desc_t): qp, opcode (any RC/UC opcode; RETH/AETH/
// ImmDt presence follows the opcode), PSN, AckReq, SE, MigReq, RETH fields, AETH
// fields, ImmDt, payload length (bytes, <= PMTU), md_patch (HSB metadata record:
// payload bytes 4..7 are replaced by {0x00, PSN}, big-endian).
// Payload: packet-segmented 512-bit stream starting at lane 0;
// the builder takes ceil(len/64) beats (tkeep of the last beat ignored, bytes
// beyond len are replaced by zero pad bytes). Header lengths are 54/58/70/74
// (IPv4) and 74/78/90/94 (IPv6) bytes, so the payload realignment is a 4-way
// (7-way with IPv6) byte multiplexer per lane, not a 64-way barrel shifter
// (SHIFT_GENERIC = 1 builds the generic one for comparison).
// Header preparation (table read, lengths, checksum, header assembly) runs
// one descriptor at a time and overlaps the emission of the previous packet.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_tx_builder
    import rocelet_pkg::*;
#(
    parameter int NUM_QP        = 8,
    parameter bit IPV6_EN       = 1'b0,
    parameter bit SHIFT_GENERIC = 1'b0,
    // header formats: 0 = fixed RDMA WRITE Only (RETH, no ImmDt/AETH: one header
    // length, the payload shift is wiring); 1 = all requester opcodes (RETH and/or
    // ImmDt); 2 = 1 + READ responses / ACK (AETH)
    parameter int OPSET         = 2,
    parameter     QP_RAM_STYLE  = "auto",
    localparam int QPW = (NUM_QP > 1) ? $clog2(NUM_QP) : 1
) (
    input  wire logic             clk,
    input  wire logic             rst,

    // QP address table
    input  wire logic             cfg_we,
    input  wire logic [QPW-1:0]   cfg_qp,
    input  wire logic             cfg_ipv6,
    input  wire logic [47:0]      cfg_dmac,
    input  wire logic [127:0]     cfg_dip,       // IPv4 in [31:0]
    input  wire logic [23:0]      cfg_dqpn,
    input  wire logic [15:0]      cfg_sport,
    input  wire logic [15:0]      cfg_dport,     // 0 = 4791
    // globals (set before writing QPs: the checksum partial uses them)
    input  wire logic [47:0]      my_mac,
    input  wire logic [31:0]      my_ip4,
    input  wire logic [127:0]     my_ip6,
    input  wire logic [7:0]       ip_tos,
    input  wire logic [7:0]       ip_ttl,

    // packet descriptor
    input  wire logic             s_desc_valid,
    output wire logic             s_desc_ready,
    input  tx_desc_t              s_desc,

    // payload
    input  wire logic [511:0]     s_pay_tdata,
    input  wire logic             s_pay_tvalid,
    output wire logic             s_pay_tready,

    // frames out (no ICRC, no FCS)
    output wire logic [511:0]     m_axis_tdata,
    output wire logic [63:0]      m_axis_tkeep,
    output wire logic             m_axis_tvalid,
    input  wire logic             m_axis_tready,
    output wire logic             m_axis_tlast
);

localparam int IPW = IPV6_EN ? 128 : 32;
// table row: {dport 16, csum partial 16, sport 16, dqpn 24, dip IPW, dmac 48, ipv6 1}
localparam int ROWW = 16 + 16 + 16 + 24 + IPW + 48 + 1;

// ---------------- configuration: checksum partial, then table write ----------------
function automatic logic [15:0] ocadd(input logic [15:0] a, input logic [15:0] b);
    logic [16:0] s = {1'b0, a} + {1'b0, b};
    return s[15:0] + {15'd0, s[16]};
endfunction

logic             cw_v = 1'b0;
logic [QPW-1:0]   cw_qp;
logic             cw_ipv6;
logic [47:0]      cw_dmac;
logic [IPW-1:0]   cw_dip;
logic [23:0]      cw_dqpn;
logic [15:0]      cw_sport, cw_dport;
logic [15:0]      cw_p0, cw_p1, cw_p2;

always_ff @(posedge clk) begin
    cw_v     <= cfg_we;
    cw_qp    <= cfg_qp;
    cw_ipv6  <= IPV6_EN ? cfg_ipv6 : 1'b0;
    cw_dmac  <= cfg_dmac;
    cw_dip   <= cfg_dip[IPW-1:0];
    cw_dqpn  <= cfg_dqpn;
    cw_sport <= cfg_sport;
    cw_dport <= (cfg_dport == 16'd0) ? ROCE_UDP_PORT : cfg_dport;
    // 16'h4500|tos + 16'h4000 (DF) + ttl<<8|17 + sip + dip
    cw_p0 <= ocadd(ocadd({8'h45, ip_tos}, 16'h4000), {ip_ttl, 8'd17});
    cw_p1 <= ocadd(my_ip4[31:16], my_ip4[15:0]);
    cw_p2 <= ocadd(cfg_dip[31:16], cfg_dip[15:0]);
    if (rst) cw_v <= 1'b0;
end

// second stage: the row is written one clock later, so the checksum sum (two
// ones'-complement adds) does not end at the table's write data (timing)
logic                tw_v = 1'b0;
logic [QPW-1:0]      tw_qp;
logic [ROWW-1:0]     tbl_wdata;
always_ff @(posedge clk) begin
    tw_v      <= cw_v;
    tw_qp     <= cw_qp;
    tbl_wdata <= {cw_dport, ocadd(ocadd(cw_p0, cw_p1), cw_p2), cw_sport, cw_dqpn, cw_dip, cw_dmac, cw_ipv6};
    if (rst) tw_v <= 1'b0;
end
wire logic [ROWW-1:0] tbl_rdata;
wire logic            desc_fire = s_desc_valid && s_desc_ready;

if (NUM_QP == 1) begin : g_tbl1
    logic [ROWW-1:0] row;
    always_ff @(posedge clk) if (tw_v) row <= tbl_wdata;
    assign tbl_rdata = row;
end else begin : g_tbl
    rocelet_ram_sdp #(.WIDTH(ROWW), .DEPTH(NUM_QP), .RD_LAT(1), .RAM_STYLE(QP_RAM_STYLE)) u_tbl (
        .clk(clk), .we(tw_v), .waddr(tw_qp), .wdata(tbl_wdata),
        .re(desc_fire), .raddr(s_desc.qp[QPW-1:0]), .rdata(tbl_rdata)
    );
end

// ---------------- header preparation (one descriptor at a time) ----------------
logic hdr_v = 1'b0;          // hdr / pk_* hold a prepared packet, not loaded yet
logic hdr_busy = 1'b0;       // hdr is in use by the emitting packet (until its beat HB)
logic [3:0] pv = '0;         // prep stage valid bits
wire  logic prep_busy = |pv;
assign s_desc_ready = !prep_busy && !hdr_v && !hdr_busy;

// stage 0: descriptor capture (table read in flight)
logic [7:0]  d_op;
logic [23:0] d_psn;
logic        d_ackreq, d_se, d_mig0, d_md;
logic [63:0] d_va;
logic [31:0] d_rkey, d_dmalen, d_imm;
logic [7:0]  d_syn;
logic [23:0] d_msn;
logic [12:0] d_len;

always_ff @(posedge clk) begin
    if (desc_fire) begin
        d_op     <= s_desc.opcode;
        d_psn    <= s_desc.psn;
        d_ackreq <= s_desc.ackreq;
        d_se     <= s_desc.se;
        d_mig0   <= s_desc.mig0;
        d_md     <= s_desc.md_patch;
        d_va     <= s_desc.va;
        d_rkey   <= s_desc.rkey;
        d_dmalen <= s_desc.dmalen;
        d_imm    <= s_desc.imm;
        d_syn    <= s_desc.syndrome;
        d_msn    <= s_desc.msn;
        d_len    <= s_desc.len;
    end
end

// stage 1: table row + lengths
wire logic             r_ipv6  = tbl_rdata[0];
wire logic [47:0]      r_dmac  = tbl_rdata[1 +: 48];
wire logic [IPW-1:0]   r_dip   = tbl_rdata[49 +: IPW];
wire logic [23:0]      r_dqpn  = tbl_rdata[49 + IPW +: 24];
wire logic [15:0]      r_sport = tbl_rdata[73 + IPW +: 16];
wire logic [15:0]      r_part  = tbl_rdata[89 + IPW +: 16];
wire logic [15:0]      r_dport = tbl_rdata[105 + IPW +: 16];

logic             p_ipv6;
logic [47:0]      p_dmac;
logic [IPW-1:0]   p_dip;
logic [23:0]      p_dqpn;
logic [15:0]      p_sport, p_dport;
logic [15:0]      p_part;
logic             p_reth, p_aeth, p_imm;
logic [1:0]       p_pad;
logic [15:0]      p_udp_len;     // UDP header .. ICRC
logic [16:0]      p_ck_sum;
logic [6:0]       p_hlen;        // header length H
logic [13:0]      p_flen;        // frame length without ICRC

wire logic [1:0]  pad_c   = 2'(-d_len[1:0]);
wire logic f_reth = (OPSET == 0) ? 1'b1 : op_has_reth(d_op);
wire logic f_aeth = (OPSET == 2) ? op_has_aeth(d_op) : 1'b0;
wire logic f_imm  = (OPSET == 0) ? 1'b0 : op_has_imm(d_op);
wire logic [5:0]  ext_c   = (f_reth ? 6'd16 : 6'd0) + (f_aeth ? 6'd4 : 6'd0) + (f_imm ? 6'd4 : 6'd0);
wire logic [15:0] l4_c    = 16'd12 + 16'(ext_c) + 16'(d_len) + 16'(pad_c) + 16'd4;

always_ff @(posedge clk) begin
    if (pv[0]) begin
        p_ipv6    <= IPV6_EN ? r_ipv6 : 1'b0;
        p_dmac    <= r_dmac;
        p_dip     <= r_dip;
        p_dqpn    <= r_dqpn;
        p_sport   <= r_sport;
        p_dport   <= r_dport;
        p_part    <= r_part;
        p_reth    <= f_reth;
        p_aeth    <= f_aeth;
        p_imm     <= f_imm;
        p_pad     <= pad_c;
        p_udp_len <= 16'd8 + l4_c;
        p_ck_sum  <= {1'b0, r_part} + {1'b0, 16'd28 + l4_c};      // + IPv4 total length
        p_hlen    <= ((IPV6_EN && r_ipv6) ? 7'd74 : 7'd54) + 7'(ext_c);
        p_flen    <= ((IPV6_EN && r_ipv6) ? 14'd74 : 14'd54) + 14'(ext_c) + 14'(d_len) + 14'(pad_c);
    end
end

// stage 2: checksum fold, beat counts
logic [15:0] q_csum;
logic [6:0]  q_no;           // output beats
logic [6:0]  q_np;           // payload beats
logic [6:0]  q_last_keep;    // bytes in the last output beat
logic [6:0]  q_pay_last;     // payload bytes in the last payload beat (excl. pad)
always_ff @(posedge clk) begin
    if (pv[1]) begin
        q_csum      <= ~(p_ck_sum[15:0] + {15'd0, p_ck_sum[16]});
        q_no        <= 7'((p_flen + 14'd63) >> 6);
        q_np        <= 7'((d_len + 13'd63) >> 6);
        q_last_keep <= (p_flen[5:0] == 6'd0) ? 7'd64 : {1'b0, p_flen[5:0]};
        q_pay_last  <= (d_len[5:0] == 6'd0) ? 7'd64 : {1'b0, d_len[5:0]};
    end
end

// stage 3: header assembly (128 bytes, beats 0 and 1)
logic [7:0] hb [128];
always_comb begin
    int u, e;
    for (int i = 0; i < 128; i++) hb[i] = 8'h00;
    for (int i = 0; i < 6; i++) begin
        hb[i]     = p_dmac[(5-i)*8 +: 8];
        hb[6 + i] = my_mac[(5-i)*8 +: 8];
    end
    if (IPV6_EN && p_ipv6) begin
        hb[12] = 8'h86; hb[13] = 8'hDD;
        hb[14] = {4'h6, ip_tos[7:4]};
        hb[15] = {ip_tos[3:0], 4'h0};
        hb[18] = p_udp_len[15:8]; hb[19] = p_udp_len[7:0];
        hb[20] = 8'd17;
        hb[21] = ip_ttl;
        for (int i = 0; i < 16; i++) begin
            hb[22 + i] = my_ip6[(15-i)*8 +: 8];
            hb[38 + i] = p_dip[((IPW/8)-1-i)*8 +: 8];
        end
        u = 54;
    end else begin
        hb[12] = 8'h08; hb[13] = 8'h00;
        hb[14] = 8'h45; hb[15] = ip_tos;
        {hb[16], hb[17]} = p_udp_len + 16'd20;
        hb[20] = 8'h40;
        hb[22] = ip_ttl; hb[23] = 8'd17;
        {hb[24], hb[25]} = q_csum;
        for (int i = 0; i < 4; i++) begin
            hb[26 + i] = my_ip4[(3-i)*8 +: 8];
            hb[30 + i] = p_dip[(3-i)*8 +: 8];
        end
        u = 34;
    end
    // UDP
    {hb[u], hb[u+1]} = p_sport;
    {hb[u+2], hb[u+3]} = p_dport;
    {hb[u+4], hb[u+5]} = p_udp_len;
    // BTH
    hb[u+8]  = d_op;
    hb[u+9]  = {d_se, !d_mig0, p_pad, 4'h0};   // SE, MigReq (1: ConnectX interop; 0: HSB format), pad, TVer 0
    hb[u+10] = 8'hFF; hb[u+11] = 8'hFF;
    {hb[u+13], hb[u+14], hb[u+15]} = p_dqpn;
    hb[u+16] = {d_ackreq, 7'd0};
    {hb[u+17], hb[u+18], hb[u+19]} = d_psn;
    e = u + 20;
    if (p_reth) begin
        for (int i = 0; i < 8; i++) hb[e + i] = d_va[(7-i)*8 +: 8];
        {hb[e+8], hb[e+9], hb[e+10], hb[e+11]} = d_rkey;
        {hb[e+12], hb[e+13], hb[e+14], hb[e+15]} = d_dmalen;
        e = e + 16;
    end
    if (p_aeth) begin
        hb[e] = d_syn;
        {hb[e+1], hb[e+2], hb[e+3]} = d_msn;
        e = e + 4;
    end
    if (p_imm) begin
        {hb[e], hb[e+1], hb[e+2], hb[e+3]} = d_imm;
    end
end

logic [1023:0] hdr;
logic [5:0]    pk_s;          // H mod 64
logic          pk_hb;         // H >= 64
logic [6:0]    pk_no, pk_np, pk_last_keep, pk_pay_last;
logic          pk_md;
logic [23:0]   pk_psn;

always_ff @(posedge clk) begin
    pv <= {pv[2:0], desc_fire};
    if (pv[2]) begin
        for (int i = 0; i < 128; i++) hdr[i*8 +: 8] <= hb[i];
        pk_s         <= p_hlen[5:0];
        pk_hb        <= p_hlen[6];
        pk_no        <= q_no;
        pk_np        <= q_np;
        pk_last_keep <= q_last_keep;
        pk_pay_last  <= q_pay_last;
        pk_md        <= d_md;
        pk_psn       <= d_psn;
    end
    if (rst) pv <= '0;
end

// ---------------- emission ----------------
logic         e_act = 1'b0;
logic [6:0]   e_k;
logic [5:0]   e_s;
logic         e_hb;
logic [6:0]   e_no, e_np, e_last_keep, e_pay_last;
logic         e_md;
logic [23:0]  e_psn;
logic [511:0] prev;

logic [511:0] o_data;
logic [63:0]  o_keep;
logic         o_valid = 1'b0, o_last;
wire  logic   out_slot = !o_valid || m_axis_tready;

wire logic [6:0] e_pk     = e_k - {6'd0, e_hb};                // payload beat index
wire logic       need_pay = (e_k >= {6'd0, e_hb}) && (e_pk < e_np);
wire logic       e_go     = e_act && out_slot && (!need_pay || s_pay_tvalid);
wire logic       e_last   = (e_k == e_no - 7'd1);
assign s_pay_tready = e_act && out_slot && need_pay;

// current payload beat, pad lanes zeroed
logic [511:0] cur;
always_comb begin
    cur = '0;
    if (need_pay) begin
        for (int j = 0; j < 64; j++) begin
            if ((e_pk != e_np - 7'd1) || (j < int'(e_pay_last))) cur[j*8 +: 8] = s_pay_tdata[j*8 +: 8];
        end
        // HSB metadata record: its PSN field (bytes 4..7, big-endian) is this packet's PSN
        if (e_md && e_pk == 7'd0) cur[4*8 +: 32] = {e_psn[7:0], e_psn[15:8], e_psn[23:16], 8'h00};
    end
end

// shift = 64 - (H mod 64): IPv4 H = 54/58/70/74, IPv6 H = 74/78/90/94
localparam int NSH = (OPSET == 0) ? (IPV6_EN ? 2 : 1) : (IPV6_EN ? 7 : 4);
localparam logic [NSH*8-1:0] SHL = (OPSET == 0) ? (IPV6_EN ? {8'd38, 8'd58} : 8'd58) :
    IPV6_EN ? {8'd34, 8'd38, 8'd50, 8'd54, 8'd58, 8'd6, 8'd10} : {8'd54, 8'd58, 8'd6, 8'd10};
wire logic [511:0] shifted;
rocelet_byte_shift #(.GENERIC(SHIFT_GENERIC), .NS(NSH), .SLIST(SHL)) u_sh (
    .lo(prev), .hi(cur), .sh(6'd0 - e_s), .y(shifted)
);

wire logic [511:0] hdr_beat = e_hb ? hdr[1023:512] : hdr[511:0];
logic [511:0] beat;
always_comb begin
    if (e_k < {6'd0, e_hb}) begin
        beat = hdr[511:0];
    end else if (e_k == {6'd0, e_hb}) begin
        for (int j = 0; j < 64; j++) beat[j*8 +: 8] = (j < int'(e_s)) ? hdr_beat[j*8 +: 8] : shifted[j*8 +: 8];
    end else begin
        beat = shifted;
    end
end

function automatic logic [63:0] therm(input logic [6:0] n);
    for (int i = 0; i < 64; i++) therm[i] = (i < n);
endfunction

wire logic load = hdr_v && (!e_act || (e_go && e_last));

always_ff @(posedge clk) begin
    if (m_axis_tready) o_valid <= 1'b0;
    if (e_go) begin
        o_valid <= 1'b1;
        o_data  <= beat;
        o_keep  <= e_last ? therm(e_last_keep) : '1;
        o_last  <= e_last;
        prev    <= cur;
        e_k     <= e_k + 7'd1;
        if (e_last) e_act <= 1'b0;
        // header no longer needed once the beat at index HB is out
        if (e_k == {6'd0, e_hb}) hdr_busy <= 1'b0;
    end
    if (pv[2]) hdr_v <= 1'b1;
    if (load) begin
        hdr_v       <= 1'b0;
        hdr_busy    <= 1'b1;
        e_act       <= 1'b1;
        e_k         <= '0;
        e_s         <= pk_s;
        e_hb        <= pk_hb;
        e_no        <= pk_no;
        e_np        <= pk_np;
        e_last_keep <= pk_last_keep;
        e_pay_last  <= pk_pay_last;
        e_md        <= pk_md;
        e_psn       <= pk_psn;
    end
    if (rst) begin
        o_valid <= 1'b0;
        e_act   <= 1'b0;
        hdr_v   <= 1'b0;
        hdr_busy <= 1'b0;
    end
end

assign m_axis_tdata  = o_data;
assign m_axis_tkeep  = o_keep;
assign m_axis_tvalid = o_valid;
assign m_axis_tlast  = o_last;

endmodule

`resetall
