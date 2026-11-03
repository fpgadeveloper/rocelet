// SPDX-License-Identifier: MIT
//
// rocelet_axi_mem - AXI4 master (512-bit data) for the engine's per-packet memory ports.
//
//   write: responder RDMA WRITE packets: a command (address, length <= 4096) followed by
//          its data stream (tkeep = byte enables on the last beat) -> AW / W (AWID 0);
//   read 0: RDMA READ response packets (address, length) -> AR (ARID 0) -> R -> data;
//   read 1: requester payload re-reads (RTX_MODE "REREAD", RD1_EN) -> AR (ARID 1).
// Addresses are 64-byte aligned (the engine guarantees it), bursts are INCR, AxSIZE 6, and
// a packet that crosses a 4 KB boundary is split into two bursts (at most 64 beats each).
// W data of a burst follows its AW handshake.
// Ordering: a read-0 burst is issued only after every write burst accepted before its
// command has been acknowledged on B, so an RDMA READ after an RDMA WRITE to the same
// memory returns the written data (IBTA ordering on one QP), whatever the interconnect.
// Read data: one MEM_RD_BUF-beat buffer per source; a burst is issued only when its beats
// are reserved in its source's buffer, so RREADY is always 1 and the two sources can be
// consumed in any order without deadlock.
// Error responses (BRESP / RRESP != OKAY) are counted (ev_wr_err, ev_rd_err); the data is
// used as returned.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module rocelet_axi_mem #(
    parameter int ADDR_W  = 64,
    parameter int ID_W    = 2,
    parameter int RD_BUF  = 256,          // beats per read source, power of 2, >= 128
    parameter bit RD1_EN  = 1'b0
) (
    input  wire logic              clk,
    input  wire logic              rst,

    // engine: write command + data
    input  wire logic              s_wcmd_valid,
    output wire logic              s_wcmd_ready,
    input  wire logic [63:0]       s_wcmd_addr,
    input  wire logic [12:0]       s_wcmd_len,
    input  wire logic [511:0]      s_wdat_tdata,
    input  wire logic [63:0]       s_wdat_tkeep,
    input  wire logic              s_wdat_tvalid,
    output wire logic              s_wdat_tready,
    input  wire logic              s_wdat_tlast,
    // engine: read source 0 (READ responses)
    input  wire logic              s_r0cmd_valid,
    output wire logic              s_r0cmd_ready,
    input  wire logic [63:0]       s_r0cmd_addr,
    input  wire logic [12:0]       s_r0cmd_len,
    output wire logic [511:0]      m_r0dat_tdata,
    output wire logic              m_r0dat_tvalid,
    input  wire logic              m_r0dat_tready,
    // engine: read source 1 (requester payload)
    input  wire logic              s_r1cmd_valid,
    output wire logic              s_r1cmd_ready,
    input  wire logic [63:0]       s_r1cmd_addr,
    input  wire logic [12:0]       s_r1cmd_len,
    output wire logic [511:0]      m_r1dat_tdata,
    output wire logic              m_r1dat_tvalid,
    input  wire logic              m_r1dat_tready,

    // AXI4 master
    output wire logic [ID_W-1:0]   m_axi_awid,
    output wire logic [ADDR_W-1:0] m_axi_awaddr,
    output wire logic [7:0]        m_axi_awlen,
    output wire logic [2:0]        m_axi_awsize,
    output wire logic [1:0]        m_axi_awburst,
    output wire logic              m_axi_awlock,
    output wire logic [3:0]        m_axi_awcache,
    output wire logic [2:0]        m_axi_awprot,
    output wire logic              m_axi_awvalid,
    input  wire logic              m_axi_awready,
    output wire logic [511:0]      m_axi_wdata,
    output wire logic [63:0]       m_axi_wstrb,
    output wire logic              m_axi_wlast,
    output wire logic              m_axi_wvalid,
    input  wire logic              m_axi_wready,
    input  wire logic [ID_W-1:0]   m_axi_bid,
    input  wire logic [1:0]        m_axi_bresp,
    input  wire logic              m_axi_bvalid,
    output wire logic              m_axi_bready,
    output wire logic [ID_W-1:0]   m_axi_arid,
    output wire logic [ADDR_W-1:0] m_axi_araddr,
    output wire logic [7:0]        m_axi_arlen,
    output wire logic [2:0]        m_axi_arsize,
    output wire logic [1:0]        m_axi_arburst,
    output wire logic              m_axi_arlock,
    output wire logic [3:0]        m_axi_arcache,
    output wire logic [2:0]        m_axi_arprot,
    output wire logic              m_axi_arvalid,
    input  wire logic              m_axi_arready,
    input  wire logic [ID_W-1:0]   m_axi_rid,
    input  wire logic [511:0]      m_axi_rdata,
    input  wire logic [1:0]        m_axi_rresp,
    input  wire logic              m_axi_rlast,
    input  wire logic              m_axi_rvalid,
    output wire logic              m_axi_rready,

    output logic                   ev_wr_err,
    output logic                   ev_rd_err
);

// beats of a packet and of its first burst (up to the next 4 KB boundary)
function automatic logic [6:0] nbeats(input logic [12:0] len);
    return 7'((len + 13'd63) >> 6);
endfunction
function automatic logic [6:0] to_4k(input logic [63:0] a);
    return 7'd64 - {1'b0, a[11:6]};
endfunction

assign m_axi_awsize  = 3'd6;
assign m_axi_awburst = 2'b01;
assign m_axi_awlock  = 1'b0;
assign m_axi_awcache = 4'b0011;
assign m_axi_awprot  = 3'b000;
assign m_axi_awid    = '0;
assign m_axi_arsize  = 3'd6;
assign m_axi_arburst = 2'b01;
assign m_axi_arlock  = 1'b0;
assign m_axi_arcache = 4'b0011;
assign m_axi_arprot  = 3'b000;
assign m_axi_bready  = 1'b1;
assign m_axi_rready  = 1'b1;

// =====================================================================
// write
// =====================================================================
typedef enum logic [1:0] {W_IDLE, W_AW1, W_AW2} wst_t;
wst_t        ws = W_IDLE;
logic [63:0] w_addr;
logic [6:0]  w_b1, w_b2;
logic [31:0] wr_planned = '0, wr_done = '0;     // write bursts accepted / acknowledged

wire logic   wq_full, wq_v;
wire logic [6:0] wq_n;
logic        wq_push;
logic [6:0]  wq_din;
logic        wq_pop;
rocelet_fifo #(.WIDTH(7), .DEPTH(8), .RAM_STYLE("distributed")) u_wq (
    .clk(clk), .rst(rst), .din(wq_din), .wr_en(wq_push), .full(wq_full),
    .dout(wq_n), .valid(wq_v), .rd_en(wq_pop), .count()
);

assign s_wcmd_ready  = (ws == W_IDLE);
assign m_axi_awvalid = (ws != W_IDLE) && !wq_full;
assign m_axi_awaddr  = ADDR_W'(w_addr);
assign m_axi_awlen   = 8'((ws == W_AW1 ? w_b1 : w_b2) - 7'd1);
wire logic aw_fire   = m_axi_awvalid && m_axi_awready;
assign wq_push = aw_fire;
assign wq_din  = (ws == W_AW1) ? w_b1 : w_b2;

always_ff @(posedge clk) begin
    case (ws)
        W_IDLE: if (s_wcmd_valid) begin
            logic [6:0] nb, f;
            nb = nbeats(s_wcmd_len);
            f  = to_4k(s_wcmd_addr);
            w_addr     <= s_wcmd_addr;
            w_b1       <= (nb > f) ? f : nb;
            w_b2       <= (nb > f) ? nb - f : 7'd0;
            wr_planned <= wr_planned + ((nb > f) ? 32'd2 : 32'd1);
            ws         <= W_AW1;
        end
        W_AW1: if (aw_fire) begin
            w_addr <= w_addr + {51'd0, w_b1, 6'd0};
            ws     <= (w_b2 != 0) ? W_AW2 : W_IDLE;
        end
        W_AW2: if (aw_fire) ws <= W_IDLE;
        default: ws <= W_IDLE;
    endcase
    if (m_axi_bvalid) wr_done <= wr_done + 32'd1;
    ev_wr_err <= m_axi_bvalid && (m_axi_bresp != 2'b00);
    if (rst) begin
        ws         <= W_IDLE;
        wr_planned <= '0;
        wr_done    <= '0;
    end
end

logic [6:0] wcnt = '0;
assign m_axi_wdata   = s_wdat_tdata;
assign m_axi_wstrb   = s_wdat_tkeep;
assign m_axi_wvalid  = s_wdat_tvalid && wq_v;
assign m_axi_wlast   = (wcnt == wq_n - 7'd1);
assign s_wdat_tready = m_axi_wready && wq_v;
wire logic w_fire = m_axi_wvalid && m_axi_wready;
assign wq_pop = w_fire && m_axi_wlast;
always_ff @(posedge clk) begin
    if (w_fire) wcnt <= m_axi_wlast ? 7'd0 : wcnt + 7'd1;
    if (rst) wcnt <= '0;
end

// =====================================================================
// read
// =====================================================================
localparam int BW = $clog2(RD_BUF) + 1;
typedef enum logic [1:0] {R_IDLE, R_AR1, R_AR2} rst_t;
rst_t        rs = R_IDLE;
logic        r_src;
logic [63:0] r_addr;
logic [6:0]  r_b1, r_b2;
logic [31:0] r_snap;
logic        r_last_src = 1'b1;              // round robin
logic [BW-1:0] cred0 = BW'(RD_BUF), cred1 = BW'(RD_BUF);

wire logic pick1 = RD1_EN && s_r1cmd_valid && (!s_r0cmd_valid || !r_last_src);
assign s_r0cmd_ready = (rs == R_IDLE) && s_r0cmd_valid && !pick1;
assign s_r1cmd_ready = (rs == R_IDLE) && pick1;

wire logic [6:0]  r_b     = (rs == R_AR1) ? r_b1 : r_b2;
wire logic        r_order = r_src || ($signed(wr_done - r_snap) >= 0);
wire logic        r_cred  = r_src ? (cred1 >= BW'(r_b)) : (cred0 >= BW'(r_b));
assign m_axi_arvalid = (rs != R_IDLE) && r_order && r_cred;
assign m_axi_araddr  = ADDR_W'(r_addr);
assign m_axi_arlen   = 8'(r_b - 7'd1);
assign m_axi_arid    = ID_W'(r_src);
wire logic ar_fire   = m_axi_arvalid && m_axi_arready;

wire logic r_fire = m_axi_rvalid;
wire logic pop0   = m_r0dat_tvalid && m_r0dat_tready;
wire logic pop1   = m_r1dat_tvalid && m_r1dat_tready;

always_ff @(posedge clk) begin
    case (rs)
        R_IDLE: if (s_r0cmd_ready || s_r1cmd_ready) begin
            logic [63:0] a;
            logic [6:0]  nb, f;
            a  = pick1 ? s_r1cmd_addr : s_r0cmd_addr;
            nb = nbeats(pick1 ? s_r1cmd_len : s_r0cmd_len);
            f  = to_4k(a);
            r_src      <= pick1;
            r_last_src <= pick1;
            r_addr     <= a;
            r_b1       <= (nb > f) ? f : nb;
            r_b2       <= (nb > f) ? nb - f : 7'd0;
            r_snap     <= wr_planned;
            rs         <= R_AR1;
        end
        R_AR1: if (ar_fire) begin
            r_addr <= r_addr + {51'd0, r_b1, 6'd0};
            rs     <= (r_b2 != 0) ? R_AR2 : R_IDLE;
        end
        R_AR2: if (ar_fire) rs <= R_IDLE;
        default: rs <= R_IDLE;
    endcase
    cred0 <= cred0 - ((ar_fire && !r_src) ? BW'(r_b) : '0) + (pop0 ? BW'(1) : '0);
    cred1 <= cred1 - ((ar_fire &&  r_src) ? BW'(r_b) : '0) + (pop1 ? BW'(1) : '0);
    ev_rd_err <= r_fire && (m_axi_rresp != 2'b00);
    if (rst) begin
        rs    <= R_IDLE;
        cred0 <= BW'(RD_BUF);
        cred1 <= BW'(RD_BUF);
    end
end

rocelet_fifo #(.WIDTH(512), .DEPTH(RD_BUF), .RAM_STYLE("block")) u_rb0 (
    .clk(clk), .rst(rst), .din(m_axi_rdata), .wr_en(r_fire && !m_axi_rid[0]), .full(),
    .dout(m_r0dat_tdata), .valid(m_r0dat_tvalid), .rd_en(m_r0dat_tready), .count()
);
if (RD1_EN) begin : g_rb1
    rocelet_fifo #(.WIDTH(512), .DEPTH(RD_BUF), .RAM_STYLE("block")) u_rb1 (
        .clk(clk), .rst(rst), .din(m_axi_rdata), .wr_en(r_fire && m_axi_rid[0]), .full(),
        .dout(m_r1dat_tdata), .valid(m_r1dat_tvalid), .rd_en(m_r1dat_tready), .count()
    );
end else begin : g_norb1
    assign m_r1dat_tdata = '0;
    assign m_r1dat_tvalid = 1'b0;
end

endmodule

`resetall
