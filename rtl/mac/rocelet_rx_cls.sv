// SPDX-License-Identifier: MIT
//
// rocelet_rx_cls - receive classifier between the RX frame FIFO and the engine. Decides
// on the first beat of each frame (decoded on the input, registered with the beat):
//   UDP destination port 4791 (IPv4; IPv6 with IPV6_EN)   -> RoCE (the engine checks the
//                                                             IP address and the rest)
//   ARP, or ICMP to my IPv4 address (<= MAX_CTRL bytes)    -> the ARP / ICMP responder if
//                                                             arp_int, else as "other"
//   anything else                                          -> the other-traffic port if
//                                                             other_en, else dropped
// Frame-atomic: a frame goes to one destination; back-pressure from it stalls the input.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_rx_cls #(
    parameter bit IPV6_EN  = 1'b0,
    parameter int MAX_CTRL = 2000
) (
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic [31:0]   my_ip4,
    input  wire logic          arp_int,        // ARP / ICMP to the internal responder
    input  wire logic          other_en,       // forward other frames (else drop)

    input  wire logic [511:0]  s_axis_tdata,
    input  wire logic [63:0]   s_axis_tkeep,
    input  wire logic          s_axis_tvalid,
    output wire logic          s_axis_tready,
    input  wire logic          s_axis_tlast,

    output wire logic [511:0]  m_roce_tdata,
    output wire logic [63:0]   m_roce_tkeep,
    output wire logic          m_roce_tvalid,
    input  wire logic          m_roce_tready,
    output wire logic          m_roce_tlast,

    output wire logic [511:0]  m_ctl_tdata,
    output wire logic [63:0]   m_ctl_tkeep,
    output wire logic          m_ctl_tvalid,
    input  wire logic          m_ctl_tready,
    output wire logic          m_ctl_tlast,

    output wire logic [511:0]  m_oth_tdata,
    output wire logic [63:0]   m_oth_tkeep,
    output wire logic          m_oth_tvalid,
    input  wire logic          m_oth_tready,
    output wire logic          m_oth_tlast,

    output logic               ev_roce,
    output logic               ev_arp,
    output logic               ev_icmp,
    output logic               ev_other,       // forwarded to the other-traffic port
    output logic               ev_other_drop   // dropped (other_en = 0)
);

localparam logic [1:0] D_ROCE = 2'd0, D_CTL = 2'd1, D_OTH = 2'd2, D_DROP = 2'd3;

function automatic logic [7:0] B(input logic [511:0] d, input int i);
    return d[i*8 +: 8];
endfunction

logic         a_v = 1'b0, a_l, a_first;
logic [511:0] a_d;
logic [63:0]  a_k;
logic         first_in = 1'b1;
logic [1:0]   f_dst;              // destination of the frame in stage A

// beat-0 decode on the INPUT, registered with the beat (keeps it out of tready)
wire logic [511:0] sd   = s_axis_tdata;
wire logic [15:0] et_i  = {B(sd, 12), B(sd, 13)};
wire logic        ip4_i = (et_i == 16'h0800) && (B(sd, 14) == 8'h45);
wire logic        udp4_i = ip4_i && (B(sd, 23) == 8'd17) && ({B(sd, 36), B(sd, 37)} == 16'd4791);
wire logic        udp6_i = IPV6_EN && (et_i == 16'h86DD) && (B(sd, 20) == 8'd17) &&
                           ({B(sd, 56), B(sd, 57)} == 16'd4791);
wire logic        icmp_i = ip4_i && (B(sd, 23) == 8'd1) &&
                           ({B(sd, 30), B(sd, 31), B(sd, 32), B(sd, 33)} == my_ip4) &&
                           ({B(sd, 16), B(sd, 17)} <= 16'(MAX_CTRL));
wire logic        arp_i = (et_i == 16'h0806);
logic             roce, icmp, arp;     // decode of the beat in stage A (valid on its first beat)
wire logic [1:0]  dst0 = roce ? D_ROCE : ((arp || icmp) && arp_int) ? D_CTL : other_en ? D_OTH : D_DROP;
wire logic [1:0]  dst  = a_first ? dst0 : f_dst;

wire logic out_rdy = (dst == D_ROCE) ? m_roce_tready : (dst == D_CTL) ? m_ctl_tready :
                     (dst == D_OTH) ? m_oth_tready : 1'b1;
wire logic take_a  = a_v && out_rdy;
assign s_axis_tready = !a_v || take_a;

assign m_roce_tdata  = a_d;
assign m_roce_tkeep  = a_k;
assign m_roce_tlast  = a_l;
assign m_roce_tvalid = a_v && (dst == D_ROCE);
assign m_ctl_tdata   = a_d;
assign m_ctl_tkeep   = a_k;
assign m_ctl_tlast   = a_l;
assign m_ctl_tvalid  = a_v && (dst == D_CTL);
assign m_oth_tdata   = a_d;
assign m_oth_tkeep   = a_k;
assign m_oth_tlast   = a_l;
assign m_oth_tvalid  = a_v && (dst == D_OTH);

always_ff @(posedge clk) begin
    {ev_roce, ev_arp, ev_icmp, ev_other, ev_other_drop} <= '0;
    if (take_a) begin
        a_v <= 1'b0;
        if (a_first) begin
            f_dst         <= dst0;
            ev_roce       <= roce;
            ev_arp        <= arp;
            ev_icmp       <= icmp;
            ev_other      <= dst0 == D_OTH;
            ev_other_drop <= dst0 == D_DROP;
        end
    end
    if (s_axis_tvalid && s_axis_tready) begin
        a_v      <= 1'b1;
        a_d      <= s_axis_tdata;
        a_k      <= s_axis_tkeep;
        a_l      <= s_axis_tlast;
        a_first  <= first_in;
        first_in <= s_axis_tlast;
        roce     <= udp4_i || udp6_i;
        icmp     <= icmp_i;
        arp      <= arp_i;
    end
    if (rst) begin
        a_v      <= 1'b0;
        first_in <= 1'b1;
    end
end

endmodule

`resetall
