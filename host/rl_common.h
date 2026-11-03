/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_common.h - shared definitions of the rocelet host helper (rocelet_host):
 * exit codes, the test payload pattern (bit-exact with the traffic generator and
 * checker of the reference designs, first defined as rl_sys_pkg::pat_beat in the
 * research prototype, and with pat_beat() in their MicroBlaze firmware), and the
 * one-line parameter records exchanged with the FPGA console (see README.md,
 * "Parameter records").
 */
#ifndef RL_COMMON_H_
#define RL_COMMON_H_

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RL_HOST_VERSION "0.2.1"

/* ---------------- exit codes ---------------- */
enum {
    EX_OK     = 0,  /* finished as asked, no errors */
    EX_USAGE  = 1,  /* bad command line */
    EX_SETUP  = 2,  /* local setup failed: device, port, GID, MTU, memory, QP */
    EX_PEER   = 3,  /* FPGA record missing/invalid, or QP could not reach RTR/RTS */
    EX_ERRORS = 4,  /* test ran but found errors (data, sequence, WC, QP error) */
    EX_NODATA = 5   /* sink: nothing arrived before the silence timeout */
};

/* ---------------- logging ---------------- */
void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void logerr(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
double now_s(void);              /* CLOCK_MONOTONIC seconds */
int parse_size(const char *s, uint64_t *out);   /* 64K, 1M, 2G, 0x..., plain */
int parse_rate(const char *s, double *bps);     /* 1G, 25G, 500M, max -> 0 */
int parse_u64(const char *s, uint64_t *out);    /* strtoull base 0, full string */

/* ---------------- payload pattern ----------------
 * Every 64-byte beat of test payload is a function of its address A and a
 * 32-bit seed S:  bytes 0..7 = A (little endian);  bytes 8i..8i+7 =
 * (A ^ {S, ~S}) + K[i] for i = 1..7 (little endian). A region "with pattern
 * address P" holds pat_beat(P + 64k) in its k-th 64-byte beat, whatever the
 * alignment of P (the FPGA WR generator uses P = remote VA of the WR). */
#define RL_PAT_K_INIT                                                                          \
    { 0x0000000000000000ull, 0x9E3779B97F4A7C15ull, 0x3C6EF372FE94F82Aull, 0xDAA66D2C7DDF743Full,  \
      0x78DDE6E5FD29F054ull, 0x1715609F7C746C69ull, 0xB54CDA58FBBEE87Eull, 0x538454127B096493ull }
static const uint64_t RL_PAT_K[8] = RL_PAT_K_INIT;   /* also the GPU kernel's constants */

static inline void rl_pat_beat(uint64_t a, uint32_t seed, uint8_t out[64])
{
    uint64_t x = a ^ (((uint64_t)seed << 32) | (uint64_t)(uint32_t)~seed);
    for (int i = 0; i < 8; i++) {
        uint64_t w = (i == 0) ? a : x + RL_PAT_K[i];
        for (int b = 0; b < 8; b++)
            out[8 * i + b] = (uint8_t)(w >> (8 * b));
    }
}

/* Fill len bytes with the pattern of pattern address pat. */
void rl_pat_fill(uint8_t *buf, uint64_t pat, size_t len, uint32_t seed);
/* Compare len bytes with the pattern. Returns the number of mismatching
 * bytes; *first gets the offset of the first one (or len if none). */
size_t rl_pat_check(const uint8_t *buf, uint64_t pat, size_t len, uint32_t seed, size_t *first);

/* WR generator slot model (rl_wrgen.sv): the VA walks base, base+len, ...
 * and wraps to base when the next WR would not fit in the window. */
static inline uint64_t rl_wg_nslots(uint64_t window, uint64_t len)
{
    if (len == 0)
        return 1;
    uint64_t n = window / len;
    return n ? n : 1;
}

/* ---------------- parameter records ----------------
 * Host -> FPGA (typed into the FPGA console, one line each, <= 96 chars):
 *   RLH qpn=0x1b psn=0x3c2b1a ip=192.168.20.1 mac=6cfe549177f0 mtu=4096 ord=16
 *   RLHM rkey=0x12ab va=0x7f3e40000000 len=0x4000000
 * FPGA -> host (printed by the FPGA console, pasted to rocelet_host):
 *   RLF qp=0 qpn=0x100 psn=0x10123 ip=192.168.20.2 mac=020a35726c01 mtu=4096 rd=16 seed=0x5eed1234
 *   RLFM mr=0 rkey=0x1000 va=0x10000000000 len=0x40000000 pat=0x10000000000 acc=rw
 * Numbers: C syntax (0x.. hex, otherwise decimal), as strtoul(s, 0, 0)
 * reads them. mac: 12 hex digits, colons optional. Unknown keys are ignored.
 * A record may be preceded by anything (a console prompt); the parser looks
 * for the tag as a whole word. */
#define RL_MAX_MR 8

struct rl_mr_rec {
    int      idx;
    uint32_t rkey;
    uint64_t va, len, pat;
    int      acc;        /* bit 0 remote write, bit 1 remote read */
};

struct rl_fpga_rec {     /* RLF + RLFM */
    int      have_conn;
    int      qp;
    uint32_t qpn, psn;
    uint8_t  ip[4];
    uint8_t  mac[6];
    int      have_mac;
    uint32_t mtu;        /* bytes, 0 = not given */
    uint32_t rd;         /* FPGA READ responder depth, 0 = not given */
    uint32_t seed;
    int      have_seed;
    int      nmr;
    struct rl_mr_rec mr[RL_MAX_MR];
};

struct rl_host_rec {     /* RLH + RLHM */
    int      have_conn;
    uint32_t qpn, psn;
    uint8_t  ip[4];
    uint8_t  mac[6];
    uint32_t mtu;
    uint32_t ord;
    int      have_mr;
    uint32_t rkey;
    uint64_t va, len;
};

/* Parse one line. Returns: 0 = no record on the line, 1 = RLF, 2 = RLFM,
 * 3 = RLH, 4 = RLHM, -1 = a record with an error (err filled). RLF/RLFM fill
 * *f, RLH/RLHM fill *h (either may be NULL to ignore that direction). */
int rl_parse_record(const char *line, struct rl_fpga_rec *f, struct rl_host_rec *h,
                    char *err, size_t errlen);
void rl_format_host(const struct rl_host_rec *h, char *l1, size_t n1, char *l2, size_t n2);
void rl_format_fpga(const struct rl_fpga_rec *f, char *l1, size_t n1, char *l2, size_t n2, int mr);
const char *ip4_str(const uint8_t ip[4], char *s, size_t n);
const char *mac_str(const uint8_t mac[6], char *s, size_t n);

#ifdef __cplusplus
}
#endif

#endif
