// SPDX-License-Identifier: MIT
//
// rocelet_arp_icmp - minimal ARP and ICMP-echo responder at 512 bits, so
// a host NIC can resolve the FPGA's MAC (the RoCE stack needs a neighbour
// entry) and ping it. ARP request for my IP -> ARP reply (one 60-byte beat);
// ICMP echo request (IPv4, IHL 5, to my IP; the classifier bounds its length)
// -> echo reply: MACs and IPs swapped, type 0, checksum adjusted (RFC 1624),
// payload passed through. Everything else is consumed and dropped.
// Output goes through a small store-and-forward FIFO to the TX arbiter.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_arp_icmp (
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic [47:0]   my_mac,
    input  wire logic [31:0]   my_ip4,

    input  wire logic [511:0]  s_axis_tdata,
    input  wire logic [63:0]   s_axis_tkeep,
    input  wire logic          s_axis_tvalid,
    output wire logic          s_axis_tready,
    input  wire logic          s_axis_tlast,

    output wire logic [511:0]  m_axis_tdata,
    output wire logic [63:0]   m_axis_tkeep,
    output wire logic          m_axis_tvalid,
    input  wire logic          m_axis_tready,
    output wire logic          m_axis_tlast,

    output logic               ev_arp,
    output logic               ev_icmp
);

function automatic logic [7:0] B(input logic [511:0] d, input int i);
    return d[i*8 +: 8];
endfunction

typedef enum logic [1:0] {S_HEAD, S_PASS, S_DROP} st_t;
st_t st = S_HEAD;

wire logic [511:0] d = s_axis_tdata;
wire logic is_arp  = ({B(d, 12), B(d, 13)} == 16'h0806) && ({B(d, 14), B(d, 15)} == 16'h0001) &&
                     ({B(d, 16), B(d, 17)} == 16'h0800) && ({B(d, 20), B(d, 21)} == 16'h0001) &&
                     ({B(d, 38), B(d, 39), B(d, 40), B(d, 41)} == my_ip4);
wire logic is_icmp = ({B(d, 12), B(d, 13)} == 16'h0800) && (B(d, 14) == 8'h45) && (B(d, 23) == 8'd1) &&
                     ({B(d, 30), B(d, 31), B(d, 32), B(d, 33)} == my_ip4) &&
                     (B(d, 34) == 8'd8) && (B(d, 35) == 8'd0);

// ARP reply
logic [511:0] arp_d;
always_comb begin
    arp_d = '0;
    for (int i = 0; i < 6; i++) begin
        arp_d[i*8 +: 8]        = B(d, 22 + i);              // dst = requester's MAC
        arp_d[(6 + i)*8 +: 8]  = my_mac[(5-i)*8 +: 8];
        arp_d[(22 + i)*8 +: 8] = my_mac[(5-i)*8 +: 8];       // sender hw addr
        arp_d[(32 + i)*8 +: 8] = B(d, 22 + i);              // target hw addr
    end
    {arp_d[12*8 +: 8], arp_d[13*8 +: 8]} = 16'h0806;
    {arp_d[14*8 +: 8], arp_d[15*8 +: 8]} = 16'h0001;
    {arp_d[16*8 +: 8], arp_d[17*8 +: 8]} = 16'h0800;
    arp_d[18*8 +: 8] = 8'd6;
    arp_d[19*8 +: 8] = 8'd4;
    {arp_d[20*8 +: 8], arp_d[21*8 +: 8]} = 16'h0002;
    for (int i = 0; i < 4; i++) begin
        arp_d[(28 + i)*8 +: 8] = my_ip4[(3-i)*8 +: 8];       // sender protocol addr
        arp_d[(38 + i)*8 +: 8] = B(d, 28 + i);              // target protocol addr
    end
end

// ICMP echo reply header
logic [511:0] icmp_d;
logic [16:0]  cs_s;
always_comb begin
    icmp_d = d;
    for (int i = 0; i < 6; i++) begin
        icmp_d[i*8 +: 8]       = B(d, 6 + i);
        icmp_d[(6 + i)*8 +: 8] = my_mac[(5-i)*8 +: 8];
    end
    for (int i = 0; i < 4; i++) begin
        icmp_d[(26 + i)*8 +: 8] = my_ip4[(3-i)*8 +: 8];
        icmp_d[(30 + i)*8 +: 8] = B(d, 26 + i);
    end
    icmp_d[34*8 +: 8] = 8'd0;
    // HC' = ~(~HC + ~m + m'), m = 0x0800 (type 8 code 0), m' = 0x0000
    cs_s = {1'b0, ~{B(d, 36), B(d, 37)}} + 17'h0F7FF;
    {icmp_d[36*8 +: 8], icmp_d[37*8 +: 8]} = ~(cs_s[15:0] + {15'd0, cs_s[16]});
end

logic         o_v = 1'b0, o_l;
logic [511:0] o_d;
logic [63:0]  o_k;
wire  logic   o_slot = !o_v || m_axis_tready;
wire  logic   in_fire = s_axis_tvalid && s_axis_tready;
assign s_axis_tready = (st == S_DROP) || o_slot;

always_ff @(posedge clk) begin
    ev_arp  <= 1'b0;
    ev_icmp <= 1'b0;
    if (m_axis_tready) o_v <= 1'b0;
    if (in_fire) begin
        case (st)
            S_HEAD: begin
                if (is_arp) begin
                    o_v <= 1'b1; o_d <= arp_d; o_k <= {4'h0, 60'hFFF_FFFF_FFFF_FFFF}; o_l <= 1'b1;
                    ev_arp <= 1'b1;
                    st <= s_axis_tlast ? S_HEAD : S_DROP;
                end else if (is_icmp) begin
                    o_v <= 1'b1; o_d <= icmp_d; o_k <= s_axis_tkeep; o_l <= s_axis_tlast;
                    ev_icmp <= 1'b1;
                    st <= s_axis_tlast ? S_HEAD : S_PASS;
                end else begin
                    st <= s_axis_tlast ? S_HEAD : S_DROP;
                end
            end
            S_PASS: begin
                o_v <= 1'b1; o_d <= s_axis_tdata; o_k <= s_axis_tkeep; o_l <= s_axis_tlast;
                if (s_axis_tlast) st <= S_HEAD;
            end
            default: if (s_axis_tlast) st <= S_HEAD;
        endcase
    end
    if (rst) begin
        st  <= S_HEAD;
        o_v <= 1'b0;
    end
end

assign m_axis_tdata  = o_d;
assign m_axis_tkeep  = o_k;
assign m_axis_tvalid = o_v;
assign m_axis_tlast  = o_l;

endmodule

`resetall
