/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_record.c - parameter records (RLH/RLHM host -> FPGA, RLF/RLFM FPGA ->
 * host), payload pattern helpers and small utilities.
 */
#include "rl_common.h"

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ---------------- logging / utilities ---------------- */
void logmsg(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);
}

void logerr(const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    fputs("ERROR: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int parse_u64(const char *s, uint64_t *out)
{
    char *end;
    if (!s || !*s)
        return -1;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 0);
    if (errno || *end)
        return -1;
    *out = v;
    return 0;
}

int parse_size(const char *s, uint64_t *out)
{
    char *end;
    if (!s || !*s)
        return -1;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 0);
    if (errno || end == s)
        return -1;
    uint64_t m = 1;
    if (*end) {
        switch (toupper((unsigned char)*end)) {
        case 'K': m = 1ull << 10; break;
        case 'M': m = 1ull << 20; break;
        case 'G': m = 1ull << 30; break;
        default: return -1;
        }
        end++;
        if (*end == 'i' || *end == 'B' || *end == 'b')
            end++;
        if (*end)
            return -1;
    }
    *out = (uint64_t)v * m;
    return 0;
}

int parse_rate(const char *s, double *bps)
{
    char *end;
    if (!strcmp(s, "max") || !strcmp(s, "0")) {
        *bps = 0;
        return 0;
    }
    double v = strtod(s, &end);
    if (end == s || v <= 0)
        return -1;
    switch (toupper((unsigned char)*end)) {
    case 'K': v *= 1e3; end++; break;
    case 'M': v *= 1e6; end++; break;
    case 'G': v *= 1e9; end++; break;
    case 0: break;
    default: return -1;
    }
    if (*end == 'b' || *end == 'B')
        end++;
    if (*end)
        return -1;
    *bps = v;
    return 0;
}

const char *ip4_str(const uint8_t ip[4], char *s, size_t n)
{
    snprintf(s, n, "%u.%u.%u.%u", ip[0], ip[1], ip[2], ip[3]);
    return s;
}

const char *mac_str(const uint8_t mac[6], char *s, size_t n)
{
    snprintf(s, n, "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4],
             mac[5]);
    return s;
}

/* ---------------- payload pattern ---------------- */
void rl_pat_fill(uint8_t *buf, uint64_t pat, size_t len, uint32_t seed)
{
    uint8_t b[64];
    for (size_t off = 0; off < len; off += 64) {
        rl_pat_beat(pat + off, seed, b);
        size_t n = len - off < 64 ? len - off : 64;
        memcpy(buf + off, b, n);
    }
}

size_t rl_pat_check(const uint8_t *buf, uint64_t pat, size_t len, uint32_t seed, size_t *first)
{
    uint8_t b[64];
    size_t bad = 0;
    *first = len;
    for (size_t off = 0; off < len; off += 64) {
        size_t n = len - off < 64 ? len - off : 64;
        rl_pat_beat(pat + off, seed, b);
        if (memcmp(buf + off, b, n) == 0)
            continue;
        for (size_t j = 0; j < n; j++)
            if (buf[off + j] != b[j]) {
                if (*first == len)
                    *first = off + j;
                bad++;
            }
    }
    return bad;
}

/* ---------------- records ---------------- */
static int parse_ip(const char *v, uint8_t ip[4])
{
    unsigned a, b, c, d;
    char tail;
    if (sscanf(v, "%u.%u.%u.%u%c", &a, &b, &c, &d, &tail) != 4 || a > 255 || b > 255 ||
        c > 255 || d > 255)
        return -1;
    ip[0] = (uint8_t)a; ip[1] = (uint8_t)b; ip[2] = (uint8_t)c; ip[3] = (uint8_t)d;
    return 0;
}

static int parse_mac(const char *v, uint8_t mac[6])
{
    char hex[13];
    int n = 0;
    for (const char *p = v; *p; p++) {
        if (*p == ':' || *p == '-')
            continue;
        if (!isxdigit((unsigned char)*p) || n >= 12)
            return -1;
        hex[n++] = *p;
    }
    if (n != 12)
        return -1;
    hex[12] = 0;
    uint64_t m = strtoull(hex, NULL, 16);
    for (int i = 0; i < 6; i++)
        mac[i] = (uint8_t)(m >> (8 * (5 - i)));
    return 0;
}

static int parse_acc(const char *v, int *acc)
{
    uint64_t n;
    if (!parse_u64(v, &n)) {
        *acc = (int)(n & 3);
        return 0;
    }
    *acc = 0;
    for (const char *p = v; *p; p++) {
        if (*p == 'w' || *p == 'W') *acc |= 1;
        else if (*p == 'r' || *p == 'R') *acc |= 2;
        else if (*p != '-') return -1;
    }
    return 0;
}

/* Find "TAG " as a whole word in line; returns pointer after the tag. */
static const char *find_tag(const char *line, const char *tag)
{
    size_t tl = strlen(tag);
    for (const char *p = strstr(line, tag); p; p = strstr(p + 1, tag)) {
        if (p != line && !isspace((unsigned char)p[-1]) && p[-1] != '>' && p[-1] != ':')
            continue;
        if (p[tl] != ' ' && p[tl] != '\t')
            continue;
        return p + tl;
    }
    return NULL;
}

#define NUM_OR_FAIL(dst, max)                                                        \
    do {                                                                             \
        uint64_t _v;                                                                 \
        if (parse_u64(val, &_v) || _v > (uint64_t)(max)) {                          \
            snprintf(err, errlen, "%s: bad value '%s' for %s", tag, val, key);      \
            return -1;                                                               \
        }                                                                            \
        (dst) = _v;                                                                  \
    } while (0)

int rl_parse_record(const char *line, struct rl_fpga_rec *f, struct rl_host_rec *h,
                    char *err, size_t errlen)
{
    static const char *tags[] = { "RLFM", "RLF", "RLHM", "RLH" };
    static const int kinds[] = { 2, 1, 4, 3 };
    const char *p = NULL, *tag = NULL;
    int kind = 0;
    char buf[512];

    for (int i = 0; i < 4 && !p; i++) {
        p = find_tag(line, tags[i]);
        if (p) {
            tag = tags[i];
            kind = kinds[i];
        }
    }
    if (!p)
        return 0;
    if ((kind <= 2 && !f) || (kind >= 3 && !h))
        return 0;
    snprintf(buf, sizeof(buf), "%s", p);

    struct rl_mr_rec mr = { .idx = -1, .acc = 3 };
    int have_rkey = 0, have_va = 0, have_len = 0, have_pat = 0;
    int have_qpn = 0, have_psn = 0, have_ip = 0, have_mac = 0;
    struct rl_fpga_rec fc;
    struct rl_host_rec hc;
    memset(&fc, 0, sizeof(fc));
    memset(&hc, 0, sizeof(hc));
    if (f) fc = *f;
    if (h) hc = *h;

    char *save = NULL;
    for (char *tok = strtok_r(buf, " \t\r\n", &save); tok; tok = strtok_r(NULL, " \t\r\n", &save)) {
        char *eq = strchr(tok, '=');
        if (!eq)
            continue;               /* tolerate stray words */
        *eq = 0;
        const char *key = tok, *val = eq + 1;
        if (!strcmp(key, "qpn")) {
            uint32_t v; NUM_OR_FAIL(v, 0xFFFFFF);
            if (kind == 1) fc.qpn = v; else hc.qpn = v;
            have_qpn = 1;
        } else if (!strcmp(key, "psn")) {
            uint32_t v; NUM_OR_FAIL(v, 0xFFFFFF);
            if (kind == 1) fc.psn = v; else hc.psn = v;
            have_psn = 1;
        } else if (!strcmp(key, "ip")) {
            uint8_t ip[4];
            if (parse_ip(val, ip)) {
                snprintf(err, errlen, "%s: bad ip '%s'", tag, val);
                return -1;
            }
            memcpy(kind == 1 ? fc.ip : hc.ip, ip, 4);
            have_ip = 1;
        } else if (!strcmp(key, "mac")) {
            uint8_t m[6];
            if (parse_mac(val, m)) {
                snprintf(err, errlen, "%s: bad mac '%s'", tag, val);
                return -1;
            }
            memcpy(kind == 1 ? fc.mac : hc.mac, m, 6);
            have_mac = 1;
        } else if (!strcmp(key, "mtu")) {
            uint32_t v; NUM_OR_FAIL(v, 4096);
            if (v != 256 && v != 512 && v != 1024 && v != 2048 && v != 4096) {
                snprintf(err, errlen, "%s: mtu must be 256/512/1024/2048/4096, not %u", tag, v);
                return -1;
            }
            if (kind == 1) fc.mtu = v; else hc.mtu = v;
        } else if (!strcmp(key, "qp") && kind == 1) {
            uint32_t v; NUM_OR_FAIL(v, 255); fc.qp = (int)v;
        } else if (!strcmp(key, "rd") && kind == 1) {
            uint32_t v; NUM_OR_FAIL(v, 255); fc.rd = v;
        } else if (!strcmp(key, "ord") && kind == 3) {
            uint32_t v; NUM_OR_FAIL(v, 255); hc.ord = v;
        } else if (!strcmp(key, "seed") && kind == 1) {
            uint32_t v; NUM_OR_FAIL(v, 0xFFFFFFFFu); fc.seed = v; fc.have_seed = 1;
        } else if (!strcmp(key, "mr") && kind == 2) {
            uint32_t v; NUM_OR_FAIL(v, 255); mr.idx = (int)v;
        } else if (!strcmp(key, "rkey")) {
            uint32_t v; NUM_OR_FAIL(v, 0xFFFFFFFFu);
            mr.rkey = v; have_rkey = 1;
        } else if (!strcmp(key, "va")) {
            uint64_t v; NUM_OR_FAIL(v, UINT64_MAX); mr.va = v; have_va = 1;
        } else if (!strcmp(key, "len")) {
            uint64_t v; NUM_OR_FAIL(v, UINT64_MAX); mr.len = v; have_len = 1;
        } else if (!strcmp(key, "pat") && kind == 2) {
            uint64_t v; NUM_OR_FAIL(v, UINT64_MAX); mr.pat = v; have_pat = 1;
        } else if (!strcmp(key, "acc") && kind == 2) {
            if (parse_acc(val, &mr.acc)) {
                snprintf(err, errlen, "%s: bad acc '%s' (rw, r, w or 0..3)", tag, val);
                return -1;
            }
        }
    }

    if (kind == 1 || kind == 3) {
        if (!have_qpn || !have_psn || !have_ip) {
            snprintf(err, errlen, "%s needs at least qpn=, psn= and ip=", tag);
            return -1;
        }
        if (kind == 1) {
            fc.have_conn = 1;
            fc.have_mac = have_mac;
            *f = fc;
        } else {
            if (!have_mac) {
                snprintf(err, errlen, "RLH needs mac=");
                return -1;
            }
            hc.have_conn = 1;
            *h = hc;
        }
        return kind;
    }
    if (!have_rkey || !have_va || !have_len) {
        snprintf(err, errlen, "%s needs rkey=, va= and len=", tag);
        return -1;
    }
    if (kind == 2) {
        if (!have_pat)
            mr.pat = mr.va;          /* identity window */
        if (mr.idx < 0)
            mr.idx = fc.nmr;
        int slot = -1;
        for (int i = 0; i < fc.nmr; i++)
            if (fc.mr[i].idx == mr.idx)
                slot = i;
        if (slot < 0) {
            if (fc.nmr >= RL_MAX_MR) {
                snprintf(err, errlen, "too many RLFM windows (max %d)", RL_MAX_MR);
                return -1;
            }
            slot = fc.nmr++;
        }
        fc.mr[slot] = mr;
        *f = fc;
    } else {
        hc.have_mr = 1;
        hc.rkey = mr.rkey;
        hc.va = mr.va;
        hc.len = mr.len;
        *h = hc;
    }
    return kind;
}

void rl_format_host(const struct rl_host_rec *h, char *l1, size_t n1, char *l2, size_t n2)
{
    char ips[20];
    snprintf(l1, n1, "RLH qpn=0x%x psn=0x%x ip=%s mac=%02x%02x%02x%02x%02x%02x mtu=%u ord=%u",
             h->qpn, h->psn, ip4_str(h->ip, ips, sizeof(ips)), h->mac[0], h->mac[1], h->mac[2],
             h->mac[3], h->mac[4], h->mac[5], h->mtu, h->ord);
    if (h->have_mr)
        snprintf(l2, n2, "RLHM rkey=0x%x va=0x%" PRIx64 " len=0x%" PRIx64, h->rkey, h->va, h->len);
    else if (n2)
        l2[0] = 0;
}

void rl_format_fpga(const struct rl_fpga_rec *f, char *l1, size_t n1, char *l2, size_t n2, int mr)
{
    char ips[20];
    snprintf(l1, n1,
             "RLF qp=%d qpn=0x%x psn=0x%x ip=%s mac=%02x%02x%02x%02x%02x%02x mtu=%u rd=%u seed=0x%x",
             f->qp, f->qpn, f->psn, ip4_str(f->ip, ips, sizeof(ips)), f->mac[0], f->mac[1],
             f->mac[2], f->mac[3], f->mac[4], f->mac[5], f->mtu, f->rd, f->seed);
    if (mr >= 0 && mr < f->nmr) {
        const struct rl_mr_rec *m = &f->mr[mr];
        snprintf(l2, n2,
                 "RLFM mr=%d rkey=0x%x va=0x%" PRIx64 " len=0x%" PRIx64 " pat=0x%" PRIx64 " acc=%s",
                 m->idx, m->rkey, m->va, m->len, m->pat,
                 m->acc == 3 ? "rw" : m->acc == 2 ? "r" : m->acc == 1 ? "w" : "-");
    } else if (n2) {
        l2[0] = 0;
    }
}
