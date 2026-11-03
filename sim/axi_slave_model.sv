// SPDX-License-Identifier: MIT
//
// axi_slave_model - behavioural AXI4 slave memory for the rocelet testbenches (512-bit
// data, INCR bursts of 64-byte beats). Byte memory in an associative array; bytes never
// written read as pat(addr) = addr ^ (addr >> 8) ^ 0x5A. Random back-pressure on every
// channel (+axi_bp=<%>), a random delay before each burst is executed (+axi_lat=<max
// clocks>), and read bursts of different IDs may complete out of order (each ID in
// order). Writes are applied when the burst's last W beat is in and acknowledged on B
// after the delay. Checks: AWSIZE/ARSIZE 6, INCR, no burst across 4 KB, WLAST position.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module axi_slave_model #(
    parameter int ADDR_W = 64,
    parameter int ID_W   = 2
) (
    input  wire logic              clk,
    input  wire logic              rst,
    input  wire logic [ID_W-1:0]   awid,
    input  wire logic [ADDR_W-1:0] awaddr,
    input  wire logic [7:0]        awlen,
    input  wire logic [2:0]        awsize,
    input  wire logic [1:0]        awburst,
    input  wire logic              awvalid,
    output logic                   awready = 1'b0,
    input  wire logic [511:0]      wdata,
    input  wire logic [63:0]       wstrb,
    input  wire logic              wlast,
    input  wire logic              wvalid,
    output logic                   wready = 1'b0,
    output logic [ID_W-1:0]        bid,
    output logic [1:0]             bresp = 2'b00,
    output logic                   bvalid = 1'b0,
    input  wire logic              bready,
    input  wire logic [ID_W-1:0]   arid,
    input  wire logic [ADDR_W-1:0] araddr,
    input  wire logic [7:0]        arlen,
    input  wire logic [2:0]        arsize,
    input  wire logic [1:0]        arburst,
    input  wire logic              arvalid,
    output logic                   arready = 1'b0,
    output logic [ID_W-1:0]        rid,
    output logic [511:0]           rdata,
    output logic [1:0]             rresp = 2'b00,
    output logic                   rlast,
    output logic                   rvalid = 1'b0,
    input  wire logic              rready
);

byte unsigned mem [longint unsigned];
int  bp = 20, lat = 8;
int  errors = 0;
longint n_wbursts = 0, n_rbursts = 0;

initial begin
    if (!$value$plusargs("axi_bp=%d", bp)) bp = 20;
    if (!$value$plusargs("axi_lat=%d", lat)) lat = 8;
end

function automatic byte unsigned pat(input longint unsigned a);
    return 8'(a ^ (a >> 8) ^ 8'h5A);
endfunction

function automatic byte unsigned rd_byte(input longint unsigned a);
    if (mem.exists(a)) return mem[a];
    return pat(a);
endfunction

function automatic void chk(input longint unsigned a, input int len, input logic [2:0] sz, input logic [1:0] bu,
                            input string what);
    if (sz != 3'd6 || bu != 2'b01 || (a % 64) != 0 || ((a % 4096) + 64 * (len + 1)) > 4096) begin
        $display("TB_ERROR axi %s burst addr=%0h len=%0d size=%0d burst=%0d", what, a, len, sz, bu);
        errors++;
    end
endfunction

// dump the bytes written: one line per run of up to 64 contiguous bytes, "addr hexbytes"
task automatic dump(input string path);
    int fd;
    longint unsigned a, start;
    string line;
    int n;
    fd = $fopen(path, "w");
    n = 0;
    if (mem.first(a)) begin
        start = a;
        line = $sformatf("%02x", mem[a]);
        n = 1;
        while (mem.next(a)) begin
            if (a == start + n && n < 64) begin
                line = {line, $sformatf("%02x", mem[a])};
                n++;
            end else begin
                $fdisplay(fd, "%0h %s", start, line);
                start = a;
                line = $sformatf("%02x", mem[a]);
                n = 1;
            end
        end
        $fdisplay(fd, "%0h %s", start, line);
    end
    $fclose(fd);
endtask

// ---------------- write ----------------
longint unsigned aw_q_addr [$];
int              aw_q_len [$];
logic [ID_W-1:0] aw_q_id [$];
longint unsigned b_due [$];
logic [ID_W-1:0] b_q_id [$];
int              w_beat = 0;
longint          cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

always @(posedge clk) begin
    if (rst) begin
        awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0;
    end else begin
        awready <= ($urandom_range(99, 0) >= bp);
        wready  <= ($urandom_range(99, 0) >= bp);
        if (awvalid && awready) begin
            chk(awaddr, awlen, awsize, awburst, "write");
            aw_q_addr.push_back(awaddr); aw_q_len.push_back(awlen); aw_q_id.push_back(awid);
        end
        if (wvalid && wready) begin
            if (aw_q_addr.size() == 0) begin
                $display("TB_ERROR axi W beat without AW");
                errors++;
            end else begin
                longint unsigned a;
                a = aw_q_addr[0] + 64 * w_beat;
                for (int j = 0; j < 64; j++) if (wstrb[j]) mem[a + j] = wdata[j*8 +: 8];
                if (wlast != (w_beat == aw_q_len[0])) begin
                    $display("TB_ERROR axi WLAST at beat %0d of %0d", w_beat, aw_q_len[0] + 1);
                    errors++;
                end
                if (w_beat == aw_q_len[0]) begin
                    w_beat = 0;
                    b_due.push_back(cyc + $urandom_range(lat, 0));
                    b_q_id.push_back(aw_q_id[0]);
                    void'(aw_q_addr.pop_front()); void'(aw_q_len.pop_front()); void'(aw_q_id.pop_front());
                    n_wbursts++;
                end else begin
                    w_beat++;
                end
            end
        end
        if (bvalid && bready) bvalid <= 1'b0;
        if ((!bvalid || bready) && b_due.size() > 0 && b_due[0] <= cyc) begin
            bvalid <= 1'b1;
            bid    <= b_q_id.pop_front();
            void'(b_due.pop_front());
        end
    end
end

// ---------------- read ----------------
typedef struct {
    longint unsigned addr;
    int              len;
    logic [ID_W-1:0] id;
    longint unsigned due;
} rb_t;
rb_t rq [$];
int  r_cur = -1, r_beat = 0;

always @(posedge clk) begin
    if (rst) begin
        arready <= 1'b0; rvalid <= 1'b0;
    end else begin
        arready <= ($urandom_range(99, 0) >= bp);
        if (arvalid && arready) begin
            rb_t b;
            chk(araddr, arlen, arsize, arburst, "read");
            b.addr = araddr; b.len = arlen; b.id = arid; b.due = cyc + $urandom_range(lat, 0);
            rq.push_back(b);
        end
        if (rvalid && rready) begin
            rvalid <= 1'b0;
            if (r_beat == rq[r_cur].len) begin
                rq.delete(r_cur);
                r_cur = -1;
                r_beat = 0;
                n_rbursts++;
            end else begin
                r_beat++;
            end
        end
        if ((!rvalid || rready) && $urandom_range(99, 0) >= bp) begin
            if (r_cur < 0) begin
                // the oldest due burst of a random ID that has one (IDs complete in order)
                for (int i = 0; i < rq.size(); i++) begin
                    bit older_same_id = 0;
                    for (int k = 0; k < i; k++) if (rq[k].id == rq[i].id) older_same_id = 1;
                    if (!older_same_id && rq[i].due <= cyc && (r_cur < 0 || $urandom_range(1, 0) == 1)) r_cur = i;
                end
            end
            if (r_cur >= 0 && !(rvalid && !rready)) begin
                longint unsigned a;
                a = rq[r_cur].addr + 64 * r_beat;
                for (int j = 0; j < 64; j++) rdata[j*8 +: 8] <= rd_byte(a + j);
                rid    <= rq[r_cur].id;
                rlast  <= (r_beat == rq[r_cur].len);
                rvalid <= 1'b1;
            end
        end
    end
end

endmodule
