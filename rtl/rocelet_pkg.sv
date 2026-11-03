// SPDX-License-Identifier: MIT
//
// rocelet_pkg - RoCE v2 constants, opcode helpers and the internal packet-descriptor type of
// the rocelet engine.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

package rocelet_pkg;

localparam logic [15:0] ROCE_UDP_PORT = 16'd4791;

// ---------------- BTH opcodes (RC: opcode[7:5] = 000, UC: 001) ----------------
localparam logic [7:0] OP_SEND_FIRST       = 8'h00;
localparam logic [7:0] OP_SEND_MIDDLE      = 8'h01;
localparam logic [7:0] OP_SEND_LAST        = 8'h02;
localparam logic [7:0] OP_SEND_LAST_IMM    = 8'h03;
localparam logic [7:0] OP_SEND_ONLY        = 8'h04;
localparam logic [7:0] OP_SEND_ONLY_IMM    = 8'h05;
localparam logic [7:0] OP_WRITE_FIRST      = 8'h06;
localparam logic [7:0] OP_WRITE_MIDDLE     = 8'h07;
localparam logic [7:0] OP_WRITE_LAST       = 8'h08;
localparam logic [7:0] OP_WRITE_LAST_IMM   = 8'h09;
localparam logic [7:0] OP_WRITE_ONLY       = 8'h0A;
localparam logic [7:0] OP_WRITE_ONLY_IMM   = 8'h0B;
localparam logic [7:0] OP_READ_REQ         = 8'h0C;
localparam logic [7:0] OP_READ_RESP_FIRST  = 8'h0D;
localparam logic [7:0] OP_READ_RESP_MIDDLE = 8'h0E;
localparam logic [7:0] OP_READ_RESP_LAST   = 8'h0F;
localparam logic [7:0] OP_READ_RESP_ONLY   = 8'h10;
localparam logic [7:0] OP_ACK              = 8'h11;
localparam logic [7:0] OP_UC               = 8'h20;   // UC opcode = RC opcode | 0x20 (SEND/WRITE only)
localparam logic [7:0] OP_CNP              = 8'h81;

// ---------------- AETH syndromes ----------------
localparam logic [7:0] SYN_ACK             = 8'h1F;   // ACK, credit field 11111 = no credit count
localparam logic [7:0] SYN_RNR_NAK         = 8'h20;   // | 5-bit RNR timer code
localparam logic [7:0] SYN_NAK_PSN_SEQ     = 8'h60;
localparam logic [7:0] SYN_NAK_INV_REQ     = 8'h61;
localparam logic [7:0] SYN_NAK_REM_ACCESS  = 8'h62;
localparam logic [7:0] SYN_NAK_REM_OP      = 8'h63;

// ---------------- requester work-request classes (WR descriptor opcode[1:0]) ----------------
localparam logic [1:0] WR_WRITE     = 2'd0;
localparam logic [1:0] WR_WRITE_IMM = 2'd1;
localparam logic [1:0] WR_SEND      = 2'd2;
localparam logic [1:0] WR_SEND_IMM  = 2'd3;

// ---------------- QP types (QP_FLAGS.TYPE) ----------------
localparam logic [1:0] QPT_RC  = 2'd0;
localparam logic [1:0] QPT_UC  = 2'd1;
localparam logic [1:0] QPT_HSB = 2'd2;     // UC, one RDMA WRITE Only (+RETH) per packet (Holoscan Sensor Bridge)

// ---------------- work completion status ----------------
localparam logic [7:0] WC_OK      = 8'h00;
localparam logic [7:0] WC_LOST    = 8'h01;   // RTX_MODE LOSSY: data of this WR was not delivered
localparam logic [7:0] WC_FLUSHED = 8'h02;   // the QP was in the error state

// ---------------- requester error causes (QP_STATUS.REQ_CODE) ----------------
// a received fatal NAK reports its syndrome (0x61..0x63)
localparam logic [7:0] REQ_ERR_RETRY  = 8'hFF;   // ACK timeout / NAK-sequence retries exhausted
localparam logic [7:0] REQ_ERR_RNR    = 8'hFE;   // RNR retries exhausted
localparam logic [7:0] REQ_ERR_FORCED = 8'hFD;   // QP_ERR_CMD
localparam logic [7:0] REQ_ERR_LOSS   = 8'hFC;   // loss with CTRL.LOSS_FATAL

// ---------------- opcode helpers (RC and UC share the header layout) ----------------
function automatic logic op_has_reth(input logic [7:0] op);
    logic [4:0] o = op[4:0];
    return (o == 5'h06) || (o == 5'h0A) || (o == 5'h0B) || (o == 5'h0C);
endfunction

function automatic logic op_has_aeth(input logic [7:0] op);
    logic [4:0] o = op[4:0];
    return (o == 5'h0D) || (o == 5'h0F) || (o == 5'h10) || (o == 5'h11);
endfunction

function automatic logic op_has_imm(input logic [7:0] op);
    logic [4:0] o = op[4:0];
    return (o == 5'h03) || (o == 5'h05) || (o == 5'h09) || (o == 5'h0B);
endfunction

// extension-header bytes after the BTH
function automatic logic [4:0] op_ext_len(input logic [7:0] op);
    return (op_has_reth(op) ? 5'd16 : 5'd0) + (op_has_aeth(op) ? 5'd4 : 5'd0) +
           (op_has_imm(op) ? 5'd4 : 5'd0);
endfunction

// IBTA RNR NAK timer code (AETH syndrome[4:0]) -> wait in microseconds
// (IBTA Vol 1, Table 45: code 0 = 655.36 ms, 1 = 0.01 ms ... 31 = 491.52 ms)
function automatic logic [19:0] rnr_code_us(input logic [4:0] code);
    case (code)
        5'd0:  return 20'd655360;
        5'd1:  return 20'd10;
        5'd2:  return 20'd20;
        5'd3:  return 20'd30;
        5'd4:  return 20'd40;
        5'd5:  return 20'd60;
        5'd6:  return 20'd80;
        5'd7:  return 20'd120;
        5'd8:  return 20'd160;
        5'd9:  return 20'd240;
        5'd10: return 20'd320;
        5'd11: return 20'd480;
        5'd12: return 20'd640;
        5'd13: return 20'd960;
        5'd14: return 20'd1280;
        5'd15: return 20'd1920;
        5'd16: return 20'd2560;
        5'd17: return 20'd3840;
        5'd18: return 20'd5120;
        5'd19: return 20'd7680;
        5'd20: return 20'd10240;
        5'd21: return 20'd15360;
        5'd22: return 20'd20480;
        5'd23: return 20'd30720;
        5'd24: return 20'd40960;
        5'd25: return 20'd61440;
        5'd26: return 20'd81920;
        5'd27: return 20'd122880;
        5'd28: return 20'd163840;
        5'd29: return 20'd245760;
        5'd30: return 20'd327680;
        default: return 20'd491520;
    endcase
endfunction

// ---------------- internal TX packet descriptor ----------------
// One per packet, from the response engine and the requester to the TX arbiter and the
// header builder. The builder takes ceil(len / 64) payload beats behind it (none for
// len = 0); `drop` = consume the payload, send nothing (flushed / skipped WRs).
typedef struct packed {
    logic [7:0]  qp;         // QP index (the builder's address table row)
    logic [7:0]  opcode;
    logic [23:0] psn;
    logic        ackreq;
    logic        se;
    logic        mig0;       // BTH MigReq = 0 (HSB format); else 1
    logic        md_patch;   // HSB metadata: payload bytes 4..7 := {0x00, psn}
    logic        drop;
    logic [63:0] va;         // RETH
    logic [31:0] rkey;
    logic [31:0] dmalen;
    logic [7:0]  syndrome;   // AETH
    logic [23:0] msn;
    logic [31:0] imm;        // ImmDt
    logic [12:0] len;        // payload bytes (<= PMTU)
} tx_desc_t;

localparam int TX_DESC_W = $bits(tx_desc_t);

// ---------------- event pulses of rocelet_core (statistics) ----------------
typedef struct packed {
    logic rx_icrc_bad;     // RoCE frame with a bad ICRC
    logic rx_parse_drop;   // frame rejected by the parser (IP, port, opcode, TVer)
    logic rx_cnp;          // CNP dropped
    logic rx_ack;          // ACK received
    logic rx_nak_seq;      // NAK PSN sequence error received
    logic rx_rnr_nak;      // RNR NAK received
    logic rx_nak_fatal;    // NAK invalid request / remote access / remote operational received
    logic rx_req;          // request executed (new PSN)
    logic rx_dup;          // duplicate request
    logic rx_oos;          // out-of-sequence request
    logic rx_qp_drop;      // packet for an unknown / unconfigured / failed QP
    logic rx_read;         // READ job issued
    logic rx_read_cont;    // ... as a continuation
    logic rx_rnr_sent;     // RNR NAK sent
    logic tx_req;          // requester packet to the builder
    logic tx_ack;          // ACK to the builder
    logic tx_nak;          // NAK to the builder
    logic tx_read_resp;    // READ response packet to the builder
    logic req_rtx;         // retransmission / resume / probe requested
    logic req_timeout;     // ACK timeout
    logic req_rex;         // WR re-issued (go-back-N)
    logic wr_data_err;     // WR payload tlast mismatch
    logic link_down;       // link_up fell (requester timeouts held)
} core_ev_t;

// ---------------- event pulses of rocelet_mac (statistics) ----------------
typedef struct packed {
    logic       rx_frame;        // a frame from the CMAC (each tlast)
    logic       rx_fcs_err;      // ... flagged bad by the CMAC, dropped
    logic       rx_fifo_drop;    // ... dropped by the RX FIFO (full, oversize, reset)
    logic       rx_roce;         // a frame to the engine
    logic       rx_arp;
    logic       rx_icmp;
    logic       rx_other;        // forwarded to the other-traffic port
    logic       rx_other_drop;   // dropped (other traffic disabled)
    logic       rx_vlan_strip;
    logic       rx_vlan_other;
    logic       tx_frame;        // a frame started towards the CMAC
    logic       tx_arp_icmp;
    logic       tx_other;
    logic       tx_underrun;     // tvalid low inside a frame towards the CMAC
    logic       tx_vlan_tag;
    logic       pause_load;      // received PAUSE in force (timer loaded)
    logic       pause_xoff;      // PAUSE requested from the RX FIFO level
    logic [6:0] rx_bytes;        // bytes received from the CMAC this clock
    logic [6:0] tx_bytes;        // bytes sent to the CMAC this clock
} mac_ev_t;

endpackage

`resetall
