// SPDX-License-Identifier: MIT
//
// rocelet_icrc_mask - RoCE v2 ICRC invariant-field masking of a 512-bit frame beat.
//
// ICRC rules (IBTA Vol 1 rel 1.x sec 7.8.1 "Invariant CRC" + Annex A17 RoCEv2
// sec A17.4.3.1; implemented identically by Linux rxe_icrc.c and
// scapy.contrib.roce.BTH.compute_icrc):
//   * CRC-32, the Ethernet polynomial 0x04C11DB7 (reflected 0xEDB88320), seed
//     0xFFFFFFFF, result inverted, appended after the payload LSB byte first
//     (same byte order as the Ethernet FCS), before the FCS.
//   * Coverage: an 8-byte all-ones pseudo LRH, then the IP header, UDP header,
//     BTH, extension headers, payload and pad bytes. The Ethernet header (and any
//     VLAN tag) and the FCS are NOT covered.
//   * Variant fields replaced with all-ones before the CRC:
//       IPv4: Type of Service (DSCP + ECN), Time to Live, Header Checksum
//       IPv6: Traffic Class (8 bits), Flow Label (20 bits), Hop Limit
//       UDP : Checksum
//       BTH : byte 4 "resv8a" (FECN, BECN and the 6 reserved bits)
//     Everything else (incl. IP total length/ID/flags, UDP ports and length,
//     P_Key, dest QP, PSN) is covered as transmitted.
// Frame offsets (no VLAN, Ethernet header 14 bytes; IPv4 without options):
//   IPv4: ToS 15, TTL 22, checksum 24-25, UDP checksum 40-41, BTH resv8a 46
//   IPv6: TC/FL 14[3:0], 15, 16, 17, hop limit 21, UDP checksum 60-61,
//         BTH resv8a 66 (= beat 1, lane 2)
// Seed folding: CRC(S, d) == CRC(0, d ^ S) for a reflected CRC, and leading zero
// bytes leave a zero register unchanged. So beat 0 lanes 0..5 are forced to
// 0x00, lanes 6..13 (the 8 pseudo-LRH 0xFF bytes) to 0xFF ^ seed, i.e. lanes
// 6..9 = 0x00 and 10..13 = 0xFF, and the CRC engine runs with INIT = 0 from
// lane 0.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_icrc_mask #(
    parameter bit IPV6_EN  = 1'b1,
    // start of the ICRC coverage (the IP header): 0 = fixed at byte 14;
    // 1 = 14 or 18 (one 802.1Q tag, detected from EtherType 0x8100);
    // 2 = any offset 8..40 from the l3_off input (programmable start offset)
    parameter int OFF_MODE = 0
) (
    input  wire logic [5:0]   l3_off,      // OFF_MODE 2: IP header offset (8..40)
    input  wire logic [5:0]   off_hold,    // OFF_MODE 1/2: offset registered from beat 0
    output wire logic [5:0]   off_det,     // OFF_MODE 1/2: offset of this beat-0 frame
    input  wire logic [511:0] din,
    input  wire logic         beat0,       // first beat of the frame
    input  wire logic         beat1,       // second beat of the frame
    input  wire logic         ipv6_hold,   // frame is IPv6 (registered from beat 0)
    output wire logic [511:0] dout,
    output wire logic         ipv6_det     // beat 0: EtherType is 0x86DD
);

if (OFF_MODE == 0) begin : g_fixed

assign off_det  = 6'd14;
assign ipv6_det = IPV6_EN && (din[12*8 +: 8] == 8'h86) && (din[13*8 +: 8] == 8'hDD);

logic [511:0] d;
always_comb begin
    d = din;
    if (beat0) begin
        for (int b = 0; b < 10; b++) d[b*8 +: 8] = 8'h00;
        for (int b = 10; b < 14; b++) d[b*8 +: 8] = 8'hFF;
        if (ipv6_det) begin
            d[14*8 +: 4] = 4'hF;
            d[15*8 +: 8] = 8'hFF;
            d[16*8 +: 8] = 8'hFF;
            d[17*8 +: 8] = 8'hFF;
            d[21*8 +: 8] = 8'hFF;
            d[60*8 +: 8] = 8'hFF;
            d[61*8 +: 8] = 8'hFF;
        end else begin
            d[15*8 +: 8] = 8'hFF;
            d[22*8 +: 8] = 8'hFF;
            d[24*8 +: 8] = 8'hFF;
            d[25*8 +: 8] = 8'hFF;
            d[40*8 +: 8] = 8'hFF;
            d[41*8 +: 8] = 8'hFF;
            d[46*8 +: 8] = 8'hFF;
        end
    end
    if (IPV6_EN && beat1 && ipv6_hold) begin
        d[2*8 +: 8] = 8'hFF;
    end
end
assign dout = d;

end else begin : g_prog

// offset of the IP header in this frame
wire logic vlan = (din[12*8 +: 8] == 8'h81) && (din[13*8 +: 8] == 8'h00);
wire logic [5:0] off0 = (OFF_MODE == 1) ? (vlan ? 6'd18 : 6'd14) : l3_off;
assign off_det = off0;
wire logic [5:0] off = beat0 ? off0 : off_hold;
// EtherType just before the IP header
logic [15:0] et;
always_comb begin
    et = '0;
    for (int o = 8; o <= 40; o++) if (off0 == 6'(o)) et = {din[(o-2)*8 +: 8], din[(o-1)*8 +: 8]};
end
assign ipv6_det = IPV6_EN && (et == 16'h86DD);
wire logic v6 = beat0 ? ipv6_det : ipv6_hold;

// byte r of the coverage (r = frame byte - off) is masked to 0xFF if:
function automatic logic m_v4(input int r);
    return (r == 1) || (r == 8) || (r == 10) || (r == 11) || (r == 26) || (r == 27) || (r == 32);
endfunction
function automatic logic m_v6(input int r);
    return (r == 1) || (r == 2) || (r == 3) || (r == 7) || (r == 46) || (r == 47) || (r == 52);
endfunction

logic [511:0] d;
always_comb begin
    d = din;
    for (int j = 0; j < 64; j++) begin
        for (int o = 8; o <= ((OFF_MODE == 1) ? 18 : 40); o++) begin
            if ((OFF_MODE == 2 || o == 14 || o == 18) && off == 6'(o)) begin
                int r;
                r = (beat0 ? j : 64 + j) - o;
                if (beat0 || beat1) begin
                    if (beat0 && r < -8)                    d[j*8 +: 8] = 8'h00;
                    else if (beat0 && r < -4)               d[j*8 +: 8] = 8'h00;   // 0xFF ^ seed
                    else if (beat0 && r < 0)                d[j*8 +: 8] = 8'hFF;
                    else if (v6 && r == 0)                  d[j*8 +: 4] = 4'hF;
                    else if (v6 ? m_v6(r) : m_v4(r))        d[j*8 +: 8] = 8'hFF;
                end
            end
        end
    end
end
assign dout = d;

end

endmodule

`resetall
