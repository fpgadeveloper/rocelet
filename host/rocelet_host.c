/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rocelet_host - host-side helper for testing the rocelet FPGA engine against a
 * hardware RoCE v2 NIC (e.g. mlx5) with plain libibverbs (no rdma_cm).
 *
 * The QP parameters are exchanged out of band as one-line records (RLH/RLHM
 * host -> FPGA console, RLF/RLFM FPGA console -> host; rl_common.h). Roles:
 *   sink    the FPGA writes (WRITE, WRITE+imm) or sends (SEND, SEND+imm) to
 *           the host; the host verifies the payload pattern, sequence, rate
 *   source  the host WRITEs / SENDs the pattern into an FPGA window
 *   reader  the host RDMA READs an FPGA window and verifies it
 *   idle    the host QP is brought to RTS and only monitored
 * Every run snapshots hw_counters and netdev statistics before and after and
 * prints the QP state. With --mem gpu the sink's buffer is GPU memory registered
 * through a dma-buf and the payload is checked by a CUDA kernel (rl_gpu.h). See
 * README.md.
 */
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "rl_common.h"
#include "rl_gpu.h"
#include "rl_gpuv.h"
#include "rl_gring.h"
#include "rl_stats.h"
#include "rl_verbs.h"

#ifndef MAP_HUGE_2MB
#define MAP_HUGE_2MB (21 << 26)
#endif

/* ---------------- options ---------------- */
enum role { R_SINK, R_SOURCE, R_READER, R_IDLE };
enum op { OP_WRITE, OP_WRITE_IMM, OP_SEND, OP_SEND_IMM, OP_READ };
static const char *const op_names[] = { "write", "write_imm", "send", "send_imm", "read" };
static const char *const role_names[] = { "sink", "source", "reader", "idle" };

struct opts {
    const char *dev;
    int         port;
    int         gid_index;
    int         have_local_ip;
    uint8_t     local_ip[4];
    enum role   role;
    enum op     op;
    uint64_t    len;
    uint64_t    count;
    double      duration;
    double      rate_bps;          /* 0 = unlimited */
    uint32_t    depth;
    uint32_t    signal;
    uint64_t    buf_size;
    int         nbuf;
    uint64_t    window;            /* 0 = default */
    uint32_t    rq_depth;
    uint32_t    pmtu;
    int         psn_set;
    uint32_t    psn;
    uint8_t     tclass, hop_limit, timeout, retry, rnr_retry, min_rnr;
    int         max_rd, max_dest_rd;
    int         migreq;
    enum ibv_qp_type qp_type;
    const char *peer[RL_MAX_MR + 2];
    int         npeer;
    const char *ctl;
    const char *record_out;
    int         seed_set;
    uint32_t    seed;
    int         verify;            /* 0 none, 1 full, 2 sample */
    uint32_t    sample;
    int         fill;
    double      silence_s;
    double      start_timeout_s;
    double      interval;
    int         json;
    int         wait_go;
    int         fpga_mr;           /* RLFM mr= index, -1 = first */
    uint64_t    fpga_off;
    int         imm0_set;
    uint32_t    imm0;
    int         hugepages;         /* 0 off, 1 try, 2 require */
    int         send_base_set;
    uint64_t    send_base;
    uint32_t    repost_delay_us;   /* sink: slow receiver (RNR tests) */
    /* GPU ring (--mem gpu) */
    int         mem_gpu;
    int         gpu;               /* CUDA device index */
    int         gpu_iova;          /* RL_GRING_IOVA_ZERO (default) or _DEV */
    int         gpu_iova_set;
    uint32_t    gpu_batch;         /* messages per kernel launch */
    uint32_t    gpu_wait_us;       /* launch a partial batch after this long */
    int         gpu_scrub;         /* -1 auto, 0 off, 1 on */
    int         mock;              /* selftest-gpu: mock back end */
    int         dev_set;
    int         buf_max;           /* --buf-size max */
    /* counters / pattern / info commands */
    const char *save, *diff;
    int         all;
    uint64_t    pat_addr;
    uint64_t    pat_len;
    int         have_fpga_ip;
    uint8_t     fpga_ip[4];
};

static void opts_default(struct opts *o)
{
    memset(o, 0, sizeof(*o));
    o->dev = NULL;                 /* resolved to the first RDMA device present */
    o->port = 1;
    o->gid_index = -1;
    o->role = R_SINK;
    o->op = OP_WRITE_IMM;
    o->len = 65536;
    o->rate_bps = 1e9;             /* safe default: 1 Gb/s; --rate max to lift */
    o->depth = 16;
    o->buf_size = 64ull << 20;
    o->nbuf = 1;
    o->rq_depth = 256;
    o->pmtu = 4096;
    o->hop_limit = 64;
    o->timeout = 14;
    o->retry = 7;
    o->rnr_retry = 7;
    o->min_rnr = 12;
    o->max_rd = 16;
    o->max_dest_rd = 1;
    o->migreq = -1;
    o->qp_type = IBV_QPT_RC;
    o->ctl = "-";
    o->verify = 1;
    o->fill = 0x5A;
    o->silence_s = 10;
    o->start_timeout_s = 120;
    o->interval = 1;
    o->wait_go = 1;
    o->fpga_mr = -1;
    o->imm0 = 0x10000;             /* the FPGA WR generator's first immediate */
    o->hugepages = 1;
    o->pat_len = 64;
    o->gpu_iova = RL_GRING_IOVA_ZERO;
    o->gpu_batch = 64;
    o->gpu_wait_us = 200;
    o->gpu_scrub = -1;
}

/* ---------------- global stop flag ---------------- */
static volatile sig_atomic_t g_stop;
static void on_sigint(int s)
{
    (void)s;
    g_stop = 1;
}

/* ---------------- control input (stdin, FIFO or a file being appended) ---------------- */
struct ctl {
    int    fd;
    int    regular;
    int    eof;
    size_t n;
    char   buf[8192];
};

static int ctl_open(struct ctl *c, const char *path)
{
    memset(c, 0, sizeof(*c));
    if (!strcmp(path, "-")) {
        c->fd = STDIN_FILENO;
    } else {
        c->fd = open(path, O_RDONLY | O_NONBLOCK);
        if (c->fd < 0) {
            /* a file the agent will create later: create it empty */
            int fd = open(path, O_RDWR | O_CREAT, 0644);
            if (fd >= 0)
                close(fd);
            c->fd = open(path, O_RDONLY | O_NONBLOCK);
        }
        if (c->fd < 0) {
            logerr("cannot open control input %s: %s", path, strerror(errno));
            return -1;
        }
    }
    struct stat st;
    c->regular = !fstat(c->fd, &st) && S_ISREG(st.st_mode);
    return 0;
}

/* Returns 1 with a line, 0 on timeout, -1 if the input is closed for good. */
static int ctl_getline(struct ctl *c, char *line, size_t max, double timeout_s)
{
    double t_end = now_s() + timeout_s;
    for (;;) {
        char *nl = memchr(c->buf, '\n', c->n);
        if (nl) {
            size_t l = (size_t)(nl - c->buf);
            size_t k = l < max - 1 ? l : max - 1;
            memcpy(line, c->buf, k);
            line[k] = 0;
            if (k && line[k - 1] == '\r')
                line[k - 1] = 0;
            memmove(c->buf, nl + 1, c->n - l - 1);
            c->n -= l + 1;
            return 1;
        }
        if (c->eof && !c->regular)
            return -1;
        double left = t_end - now_s();
        if (left < 0)
            left = 0;
        if (!c->regular) {
            struct pollfd p = { .fd = c->fd, .events = POLLIN };
            int pr = poll(&p, 1, (int)(left * 1000));
            if (pr <= 0)
                return 0;
        }
        if (c->n >= sizeof(c->buf) - 1)
            c->n = 0;                        /* overlong line: drop */
        ssize_t r = read(c->fd, c->buf + c->n, sizeof(c->buf) - 1 - c->n);
        if (r > 0) {
            c->n += (size_t)r;
            continue;
        }
        if (r == 0 && !c->regular) {
            c->eof = 1;
            continue;
        }
        if (left <= 0)
            return 0;
        struct timespec ts = { 0, 20 * 1000 * 1000 };   /* regular file: tail -f */
        nanosleep(&ts, NULL);
    }
}

/* ---------------- memory ---------------- */
struct hbuf {
    uint8_t       *p;
    size_t         size;
    int            huge;
    struct ibv_mr *mr[4];
    int            nmr;
};

static int hbuf_alloc(struct hbuf *b, size_t size, int hugepages)
{
    memset(b, 0, sizeof(*b));
    size_t huge_sz = 2u << 20;
    size_t sz = (size + huge_sz - 1) & ~(huge_sz - 1);
    if (hugepages) {
        b->p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_HUGE_2MB, -1, 0);
        if (b->p != MAP_FAILED) {
            b->huge = 1;
            b->size = sz;
            return 0;
        }
        if (hugepages == 2) {
            logerr("no 2 MiB hugepages for %zu bytes (reserve them: echo N | sudo tee "
                   "/proc/sys/vm/nr_hugepages)", sz);
            return -1;
        }
    }
    b->p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (b->p == MAP_FAILED) {
        logerr("mmap %zu bytes: %s", sz, strerror(errno));
        b->p = NULL;
        return -1;
    }
    b->size = sz;
    return 0;
}

static void hbuf_free(struct hbuf *b)
{
    for (int i = 0; i < b->nmr; i++)
        if (b->mr[i])
            ibv_dereg_mr(b->mr[i]);
    if (b->p)
        munmap(b->p, b->size);
    memset(b, 0, sizeof(*b));
}

static int hbuf_reg(struct hbuf *b, struct ibv_pd *pd, size_t len, int parts, int access)
{
    size_t part = len / (size_t)parts;
    if (parts > 1)
        part &= ~(size_t)4095;          /* separate windows start on page boundaries */
    if (!part) {
        logerr("buffer too small for %d parts", parts);
        return -1;
    }
    for (int i = 0; i < parts; i++) {
        b->mr[i] = ibv_reg_mr(pd, b->p + (size_t)i * part, part, access);
        if (!b->mr[i]) {
            logerr("ibv_reg_mr(%zu bytes): %s%s", part, strerror(errno),
                   errno == ENOMEM ? " (raise the memlock limit: ulimit -l unlimited)" : "");
            return -1;
        }
        b->nmr++;
    }
    return 0;
}

/* ---------------- verification helpers ---------------- */
struct vstat {
    uint64_t checked_bytes;
    uint64_t bad_bytes;
    uint64_t bad_msgs;
    uint64_t unwritten_bytes;
    int      reported;
};

static int verify_this(const struct opts *o, uint64_t n)
{
    if (o->verify == 0)
        return 0;
    if (o->verify == 2)
        return o->sample ? (n % o->sample) == 0 : 1;
    return 1;
}

/* got = the 64-byte beat that holds byte `first` of the region (fewer bytes at its end) */
static void report_beat(struct vstat *v, const char *what, uint64_t n, const uint8_t *got,
                        uint64_t pat, size_t len, uint32_t seed, size_t first)
{
    if (v->reported >= 5)
        return;
    v->reported++;
    uint8_t e[64];
    size_t beat = first & ~(size_t)63;
    rl_pat_beat(pat + beat, seed, e);
    printf("DATA MISMATCH %s #%" PRIu64 ": first bad byte at offset %zu of %zu (pattern addr 0x%" PRIx64
           ", seed 0x%08x)\n  expected:", what, n, first, len, pat + beat, seed);
    for (size_t j = 0; j < 64 && beat + j < len; j++)
        printf("%s%02x", (j % 16) ? "" : "\n   ", e[j]);
    printf("\n  got:");
    for (size_t j = 0; j < 64 && beat + j < len; j++)
        printf("%s%02x", (j % 16) ? "" : "\n   ", got[j]);
    printf("\n");
}

static void report_mismatch(struct vstat *v, const char *what, uint64_t n, const uint8_t *buf,
                            uint64_t pat, size_t len, uint32_t seed, size_t first)
{
    report_beat(v, what, n, buf + (first & ~(size_t)63), pat, len, seed, first);
}

static int region_check(struct vstat *v, const char *what, uint64_t n, const uint8_t *buf,
                        uint64_t pat, size_t len, uint32_t seed)
{
    size_t first;
    size_t bad = rl_pat_check(buf, pat, len, seed, &first);
    v->checked_bytes += len;
    if (!bad)
        return 0;
    v->bad_bytes += bad;
    v->bad_msgs++;
    report_mismatch(v, what, n, buf, pat, len, seed, first);
    return -1;
}

/* Address-based scan of a WRITE target: each 64-byte beat at host VA A is
 * pattern(A) (written), all fill bytes (never written) or corrupt. */
struct scan_res {
    uint64_t ok_beats, unwritten_beats, bad_beats;
    uint64_t first_bad_va;
};

static void scan_write_target(const uint8_t *p, uint64_t va, size_t len, uint32_t seed, int fill,
                              struct scan_res *r, struct vstat *v)
{
    uint8_t e[64], f[64];
    memset(f, fill, sizeof(f));
    for (size_t off = 0; off + 64 <= len; off += 64) {
        rl_pat_beat(va + off, seed, e);
        if (!memcmp(p + off, e, 64)) {
            r->ok_beats++;
        } else if (!memcmp(p + off, f, 64)) {
            r->unwritten_beats++;
        } else {
            if (!r->bad_beats)
                r->first_bad_va = va + off;
            r->bad_beats++;
            if (v->reported < 5) {
                size_t first = 0;
                while (first < 64 && p[off + first] == e[first])
                    first++;
                report_mismatch(v, "beat at VA", va + off, p + off, va + off, 64, seed, first);
            }
        }
    }
}

/* ---------------- async events ---------------- */
/* Link state seen through the port events. A port error (link down) is not a QP error: the RC
 * QP survives an outage as long as the requester's retry budget lasts (the FPGA's ACK timeout x
 * retry count when the FPGA sends). So a link drop does not end the run; the sink's silence
 * timer stops while the port is down and for --link-grace s after it is ACTIVE again, and the
 * run fails only if the port stays down longer than --link-down-max s. */
static struct {
    int    down;          /* port currently down (PORT_ERR seen, no PORT_ACTIVE since) */
    int    events;        /* PORT_ERR events */
    double t_down, t_up;  /* time of the last PORT_ERR / PORT_ACTIVE */
    double longest;       /* longest outage, s */
    double grace_s, max_down_s;
} g_link = { 0, 0, 0, -1e9, 0, 10, 60 };


static int poll_async(struct ibv_context *ctx, int *fatal)
{
    struct ibv_async_event ev;
    int n = 0;
    while (ibv_get_async_event(ctx, &ev) == 0) {
        n++;
        logmsg("ASYNC EVENT: %s", ibv_event_type_str(ev.event_type));
        switch (ev.event_type) {
        case IBV_EVENT_QP_FATAL:
        case IBV_EVENT_QP_REQ_ERR:
        case IBV_EVENT_QP_ACCESS_ERR:
        case IBV_EVENT_PATH_MIG_ERR:
        case IBV_EVENT_DEVICE_FATAL:
        case IBV_EVENT_CQ_ERR:
            *fatal = 1;
            break;
        case IBV_EVENT_PORT_ERR:
            if (!g_link.down) {
                g_link.down = 1;
                g_link.events++;
                g_link.t_down = now_s();
                logmsg("link down: run continues (silence timer held; fails after %.0f s down)",
                       g_link.max_down_s);
            }
            break;
        case IBV_EVENT_PORT_ACTIVE:
            if (g_link.down) {
                double d = now_s() - g_link.t_down;
                g_link.down = 0;
                g_link.t_up = now_s();
                if (d > g_link.longest)
                    g_link.longest = d;
                logmsg("link up again after %.2f s (silence timer resumes in %.0f s)", d, g_link.grace_s);
            }
            break;
        default:
            break;
        }
        ibv_ack_async_event(&ev);
    }
    if (g_link.down && now_s() - g_link.t_down > g_link.max_down_s) {
        logmsg("link down for more than %.0f s (--link-down-max)", g_link.max_down_s);
        *fatal = 1;
    }
    return n;
}

/* 1 while the sink's silence timer must not run (port down, or within the grace after it came up) */
static int link_hold(double t)
{
    return g_link.down || t - g_link.t_up < g_link.grace_s;
}

/* ---------------- run state ---------------- */
struct run {
    struct opts       *o;
    struct vdev        d;
    struct vqp         q;
    struct hbuf        buf;      /* main buffer: sink target / source mirror / reader ring */
    struct hbuf        rqb;      /* receive slots (sink send / write_imm) */
    struct ctl         ctl;
    struct rl_fpga_rec f;
    struct rl_host_rec h;
    const struct rl_mr_rec *fmr; /* selected FPGA window */
    uint32_t           seed;
    uint32_t           mtu;
    size_t             rq_slot;
    struct snap        s0, s1, si;
    double             t0, t_first, t_last, t_end;
    uint64_t           msgs, bytes, wc_err, lost, dup, seq_err, len_err, len_note;
    int                fatal;
    int                opcode_note;
    int                stop_reason_set;
    char               stop_reason[96];
    struct vstat       v;
    int                quit;
    /* the sink / record buffer: host memory (buf.mr[0]) or the GPU ring */
    struct ibv_mr     *ring_mr;
    uint64_t           ring_va;  /* the address the FPGA writes to (host VA, or the GPU IOVA) */
    uint64_t           ring_len;
    /* GPU ring (--mem gpu) */
    const struct rl_gpu_backend *gbe;
    struct rl_gpu_ctx *gctx;
    struct rl_gpu_info ginfo;
    struct rl_gring    gr;
    struct rl_gpuv    *gv;
    int                scrub;
    uint64_t           g_fill, g_mis, g_cor, g_unchecked;
};

static void set_stop(struct run *r, const char *why)
{
    if (!r->stop_reason_set) {
        snprintf(r->stop_reason, sizeof(r->stop_reason), "%s", why);
        r->stop_reason_set = 1;
    }
}

static void handle_ctl_line(struct run *r, const char *line)
{
    char err[160];
    if (!strcmp(line, "quit") || !strcmp(line, "q")) {
        r->quit = 1;
        set_stop(r, "quit (control input)");
    } else if (!strcmp(line, "done")) {
        r->quit = 1;
        set_stop(r, "done (control input)");
    } else if (!strcmp(line, "stats")) {
        struct snap s;
        snap_take(&s, r->d.name, r->d.port, r->d.netdev);
        logmsg("counters since start:");
        snap_print_delta(&r->s0, &s, stdout, 0);
        vqp_print_state(&r->q, "now");
    } else if (rl_parse_record(line, &r->f, NULL, err, sizeof(err)) < 0) {
        logmsg("control: %s", err);
    }
}

static void poll_ctl(struct run *r)
{
    char line[512];
    while (ctl_getline(&r->ctl, line, sizeof(line), 0) == 1)
        handle_ctl_line(r, line);
}

/* hw counter helpers: RoCE payload rate proxies */
static uint64_t snapv(const struct snap *s, const char *n)
{
    uint64_t v = 0;
    snap_get(s, n, &v);
    return v;
}

static void status_line(struct run *r, double t, uint64_t msgs_prev, uint64_t bytes_prev,
                        double dt)
{
    struct snap s;
    snap_take(&s, r->d.name, r->d.port, r->d.netdev);
    double rx = 0, tx = 0;
    if (dt > 0) {
        rx = (double)(snapv(&s, "hw.ip4InOctets") - snapv(&r->si, "hw.ip4InOctets")) * 8 / dt / 1e9;
        tx = (double)(snapv(&s, "hw.ip4OutOctets") - snapv(&r->si, "hw.ip4OutOctets")) * 8 / dt / 1e9;
    }
    double rate = dt > 0 ? (double)(r->bytes - bytes_prev) * 8 / dt / 1e9 : 0;
    printf("[%7.1fs] %s %s: %" PRIu64 " msgs (+%" PRIu64 "), %.3f GB, %.2f Gb/s | lost %" PRIu64
           " dup %" PRIu64 " seq %" PRIu64 " len %" PRIu64 " data %" PRIu64 " wc %" PRIu64
           " | hw ip4 rx %.2f tx %.2f Gb/s\n",
           t, role_names[r->o->role], r->o->role == R_IDLE ? "-" : op_names[r->o->op], r->msgs,
           r->msgs - msgs_prev, (double)r->bytes / 1e9, rate, r->lost, r->dup, r->seq_err,
           r->len_err, r->v.bad_msgs, r->wc_err, rx, tx);
    fflush(stdout);
    r->si = s;
}

/* ---------------- receive posting ---------------- */
static int post_recv(struct run *r, uint64_t slot)
{
    struct ibv_sge sge = {
        .addr = (uintptr_t)(r->rqb.p + slot * r->rq_slot),
        .length = (uint32_t)r->rq_slot,
        .lkey = r->rqb.mr[0]->lkey,
    };
    struct ibv_recv_wr wr = { .wr_id = slot, .sg_list = &sge, .num_sge = 1 }, *bad;
    int rc = ibv_post_recv(r->q.qp, &wr, &bad);
    if (rc)
        logerr("ibv_post_recv: %s", strerror(rc));
    return rc;
}

/* ---------------- GPU ring helpers ---------------- */
#define GPU_NB 16     /* verify batches in flight at most */

/* In-order result of one GPU-checked WRITE+imm message: the same accounting as region_check() */
static void gpu_job_done(void *ctx, const struct rl_gdesc *d, const struct rl_gres *res, int status)
{
    struct run *r = ctx;
    if (status == RL_GV_UNCHECKED) {
        r->g_unchecked++;
        return;
    }
    if (status != RL_GV_CHECKED)
        return;
    r->v.checked_bytes += d->len;
    r->g_fill += res->fill_beats;
    r->g_mis += res->misplaced_beats;
    r->g_cor += res->corrupt_beats;
    if (res->bad_bytes) {
        r->v.bad_bytes += res->bad_bytes;
        r->v.bad_msgs++;
        int before = r->v.reported;
        report_beat(&r->v, "WRITE+imm", d->seq, res->got, d->pat, d->len, r->seed, res->first);
        if (r->v.reported > before)
            printf("  (GPU: %u beat(s) unwritten/fill, %u misplaced, %u corrupt in this message)\n",
                   res->fill_beats, res->misplaced_beats, res->corrupt_beats);
    }
}

static int cmp_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

/* Address scan of a plain-WRITE GPU target: scan_write_target() on the GPU. */
static int gpu_scan_target(struct run *r, struct scan_res *sr)
{
    struct rl_gparams gp = { r->seed, (uint32_t)r->o->fill };
    struct rl_gscan gs;
    if (r->gbe->scan(r->gctx, r->gr.dptr, r->ring_va, r->ring_len, &gp, &gs)) {
        logerr("GPU scan of the WRITE target failed");
        return -1;
    }
    sr->ok_beats += gs.ok_beats;
    sr->unwritten_beats += gs.fill_beats;
    sr->bad_beats += gs.bad_beats;
    r->g_mis += gs.misplaced_beats;
    r->g_cor += gs.bad_beats - gs.misplaced_beats;
    if (gs.bad_beats) {
        sr->first_bad_va = r->ring_va + 64 * gs.first_bad;
        qsort(gs.bad_idx, gs.nbad_idx, sizeof(gs.bad_idx[0]), cmp_u64);
        for (uint64_t i = 0; i < gs.nbad_idx && r->v.reported < 5; i++) {
            uint8_t got[64], e[64];
            uint64_t k = gs.bad_idx[i], va = r->ring_va + 64 * k;
            if (r->gbe->download(r->gctx, got, r->gr.dptr + 64 * k, 64))
                break;
            rl_pat_beat(va, r->seed, e);
            size_t first = 0;
            while (first < 63 && got[first] == e[first])
                first++;
            report_beat(&r->v, "beat at VA", va, got, va, 64, r->seed, first);
        }
        if (gs.misplaced_beats)
            logmsg("GPU scan: %" PRIu64 " of the %" PRIu64 " bad beats are the pattern of another "
                   "address (misplaced)", gs.misplaced_beats, gs.bad_beats);
    }
    return 0;
}

/* ---------------- role: sink ---------------- */
static int run_sink(struct run *r)
{
    struct opts *o = r->o;
    int completion_based = o->op != OP_WRITE;
    uint64_t part = r->ring_len;
    uint64_t base0 = r->ring_va;
    uint64_t window = o->window ? o->window : part;
    uint64_t nslots = rl_wg_nslots(window, o->len);
    uint64_t next_n = 0, have_first = 0;
    uint32_t imm_base = o->imm0;
    uint64_t send_next = 0;
    int send_base_known = o->send_base_set;
    uint64_t send_base = o->send_base;
    double t_status = now_s(), t_progress = now_s();
    uint64_t msgs_prev = 0, bytes_prev = 0, hw_prev = snapv(&r->s0, "hw.ip4InOctets");
    int any = 0;

    if (o->op == OP_WRITE && o->len % 64)
        logmsg("note: --len %" PRIu64 " is not a multiple of 64: the address-based scan assumes "
               "64-byte aligned WRs and will report misaligned data as corrupt", o->len);
    if (r->gbe && o->op == OP_WRITE_IMM && o->verify) {
        struct rl_gparams gp = { r->seed, (uint32_t)o->fill };
        struct rl_gpuv_cfg gc = { o->gpu_batch, GPU_NB, o->gpu_batch,
                                  (uint64_t)o->gpu_wait_us * 1000, (uint32_t)(nslots * 2) };
        /* auto: scrub when the slots in use span >= 16 MiB (a lap takes >= 1.3 ms at 100 Gb/s,
         * far longer than a check waits); a small window could be rewritten before its check */
        r->scrub = o->gpu_scrub >= 0 ? o->gpu_scrub : nslots * o->len >= (16u << 20);
        r->gv = rl_gpuv_create(r->gbe, r->gctx, r->gr.dptr, &gp, &gc, gpu_job_done, r);
        if (!r->gv) {
            r->fatal = 1;
            set_stop(r, "GPU verifier setup failed");
            return 0;
        }
        logmsg("GPU verify: batches of %u messages (or after %u us), %u batches in flight, scrub %s "
               "(window %" PRIu64 " B = %" PRIu64 " slots; a slot is re-checked only after the "
               "ring lapped: %.1f ms at 100 Gb/s)", o->gpu_batch, o->gpu_wait_us, GPU_NB,
               r->scrub ? "on: each checked message is refilled, so a later lap that did not "
               "land shows as fill" : "off", window, nslots,
               (double)(nslots * o->len) * 8 / 100e9 * 1e3);
    }

    while (!g_stop && !r->quit && !r->fatal) {
        struct ibv_wc wc[32];
        int n = completion_based ? ibv_poll_cq(r->q.rcq, 32, wc) : 0;
        if (n < 0) {
            logerr("ibv_poll_cq failed");
            r->fatal = 1;
            break;
        }
        for (int i = 0; i < n; i++) {
            struct ibv_wc *w = &wc[i];
            double t = now_s();
            if (w->status != IBV_WC_SUCCESS) {
                r->wc_err++;
                logmsg("WC ERROR: %s (status %d, vendor_err 0x%x, opcode %d, wr_id %" PRIu64 ")",
                       ibv_wc_status_str(w->status), w->status, w->vendor_err, w->opcode, w->wr_id);
                r->fatal = 1;
                set_stop(r, "work completion error");
                break;
            }
            if (!any) {
                r->t_first = t;
                any = 1;
            }
            r->t_last = t;
            t_progress = t;
            uint8_t *slotp = r->rqb.p + w->wr_id * r->rq_slot;
            uint64_t seq;
            int has_imm = (w->wc_flags & IBV_WC_WITH_IMM) != 0;
            uint32_t imm = has_imm ? ntohl(w->imm_data) : 0;

            if (has_imm) {
                if (!have_first && !o->imm0_set && imm != imm_base) {
                    logmsg("note: first immediate 0x%08x (expected 0x%08x); following it", imm,
                           imm_base);
                    imm_base = imm;
                }
                seq = (uint64_t)(uint32_t)(imm - imm_base);
                if (seq > next_n) {
                    r->lost += seq - next_n;
                    logmsg("SEQ GAP: immediate 0x%08x, expected 0x%08x (%" PRIu64 " message(s) "
                           "missing)", imm, (uint32_t)(imm_base + next_n), seq - next_n);
                    next_n = seq + 1;
                } else if (seq < next_n) {
                    r->dup++;
                    logmsg("SEQ DUP/BACKWARDS: immediate 0x%08x after 0x%08x", imm,
                           (uint32_t)(imm_base + next_n - 1));
                } else {
                    next_n++;
                }
            } else {
                seq = next_n++;
            }
            have_first = 1;

            /* some providers report a WRITE+imm receive completion as
             * IBV_WC_RECV with IBV_WC_WITH_IMM, not IBV_WC_RECV_RDMA_WITH_IMM:
             * classify by the configured operation */
            int wimm = w->opcode == IBV_WC_RECV_RDMA_WITH_IMM ||
                       (o->op == OP_WRITE_IMM && w->opcode == IBV_WC_RECV && has_imm);
            if (wimm && w->opcode != IBV_WC_RECV_RDMA_WITH_IMM && !r->opcode_note) {
                r->opcode_note = 1;
                logmsg("note: WRITE+imm completion reported with opcode IBV_WC_RECV (%d) + "
                       "IBV_WC_WITH_IMM (provider quirk); treated as WRITE+imm", w->opcode);
            }
            if (wimm) {
                /* byte_len of a WRITE+imm completion is provider specific (total
                 * length, last packet, or 0): informational only */
                uint64_t len = o->len;
                if (w->byte_len != o->len) {
                    r->len_note++;
                    if (r->len_note <= 3)
                        logmsg("note: WRITE+imm completion byte_len %u (WR length %" PRIu64
                               "); provider-specific, not counted as an error", w->byte_len, o->len);
                }
                uint64_t va = base0 + (seq % nslots) * o->len;
                if (verify_this(o, seq) && va + len <= base0 + part) {
                    if (r->gv) {
                        /* GPU ring: checked by the kernel, results in order (gpu_job_done) */
                        struct rl_gdesc d = { va - base0, va, seq, (uint32_t)len,
                                              RL_GD_VERIFY | (r->scrub ? RL_GD_SCRUB : 0) };
                        rl_gpuv_submit(r->gv, &d, rl_gpuv_now_ns());
                    } else {
                        region_check(&r->v, "WRITE+imm", seq, (const uint8_t *)(uintptr_t)va, va,
                                     len, r->seed);
                    }
                }
                r->bytes += len;
            } else if (w->opcode == IBV_WC_RECV) {
                uint64_t len = w->byte_len;
                if (len != o->len) {
                    r->len_err++;
                    if (r->len_err <= 5)
                        logmsg("LENGTH: SEND of %u bytes, expected %" PRIu64, w->byte_len, o->len);
                }
                if (len >= 8) {
                    uint64_t a0;
                    memcpy(&a0, slotp, 8);
                    if (!send_base_known) {
                        send_base = a0;
                        send_base_known = 1;
                        logmsg("SEND pattern base 0x%" PRIx64 " (from the first message)", a0);
                    }
                    uint64_t exp = send_base + ((send_next) % nslots) * o->len;
                    if (a0 != exp && a0 != send_base) {
                        r->seq_err++;
                        if (r->seq_err <= 5)
                            logmsg("SEND ADDR: message starts at pattern address 0x%" PRIx64
                                   ", expected 0x%" PRIx64 " (or the base)", a0, exp);
                    }
                    send_next = (a0 - send_base) / (o->len ? o->len : 1) + 1;
                    if (verify_this(o, seq))
                        region_check(&r->v, "SEND", seq, slotp, a0, len, r->seed);
                }
                r->bytes += len;
            } else {
                logmsg("unexpected receive completion opcode %d", w->opcode);
            }
            r->msgs++;
            if (o->repost_delay_us) {
                struct timespec ts = { o->repost_delay_us / 1000000,
                                       (long)(o->repost_delay_us % 1000000) * 1000 };
                nanosleep(&ts, NULL);
            }
            if (post_recv(r, w->wr_id)) {
                r->fatal = 1;
                break;
            }
            if (o->count && r->msgs >= o->count) {
                r->quit = 1;
                set_stop(r, "count reached");
            }
        }
        if (r->gv) {
            rl_gpuv_poll(r->gv, rl_gpuv_now_ns(), 0);
            if (rl_gpuv_failed(r->gv)) {
                r->fatal = 1;
                set_stop(r, "GPU verify error");
            }
        }
        double t = now_s();
        if (t - t_status >= o->interval) {
            poll_ctl(r);
            poll_async(r->d.ctx, &r->fatal);
            if (!completion_based) {
                /* no completions for plain WRITE: progress = RoCE RX octets */
                struct snap s;
                snap_take(&s, r->d.name, r->d.port, r->d.netdev);
                uint64_t hw = snapv(&s, "hw.ip4InOctets");
                if (hw != hw_prev) {
                    if (!any) {
                        r->t_first = t;
                        any = 1;
                    }
                    r->t_last = t;
                    t_progress = t;
                    hw_prev = hw;
                }
            }
            status_line(r, t - r->t0, msgs_prev, bytes_prev, t - t_status);
            msgs_prev = r->msgs;
            bytes_prev = r->bytes;
            t_status = t;
            if (o->duration > 0 && t - r->t0 >= o->duration)
                set_stop(r, "duration reached"), r->quit = 1;
            if (link_hold(t))
                t_progress = t;
            if (any && t - t_progress >= o->silence_s)
                set_stop(r, "silence (no new data)"), r->quit = 1;
            if (!any && t - r->t0 >= o->start_timeout_s)
                set_stop(r, "nothing arrived (start timeout)"), r->quit = 1;
        }
        if (!n) {
            if (completion_based) {
                /* light spin; the CQ is polled, not event driven */
                struct timespec ts = { 0, 20000 };
                nanosleep(&ts, NULL);
            } else {
                struct timespec ts = { 0, 50 * 1000 * 1000 };
                nanosleep(&ts, NULL);
            }
        }
    }
    r->t_end = now_s();
    if (r->gv) {
        rl_gpuv_flush(r->gv);
        if (rl_gpuv_failed(r->gv)) {
            r->fatal = 1;
            set_stop(r, "GPU verify error");
        }
    }

    if (o->op == OP_WRITE && o->verify) {
        struct scan_res sr = { 0 };
        if (r->gbe) {
            if (gpu_scan_target(r, &sr))
                r->fatal = 1;
        } else {
            for (int i = 0; i < r->buf.nmr; i++)
                scan_write_target(r->buf.mr[i]->addr, (uintptr_t)r->buf.mr[i]->addr,
                                  r->buf.mr[i]->length, r->seed, o->fill, &sr, &r->v);
        }
        r->v.checked_bytes = (sr.ok_beats + sr.bad_beats) * 64;
        r->v.unwritten_bytes = sr.unwritten_beats * 64;
        r->v.bad_bytes = sr.bad_beats * 64;
        r->v.bad_msgs = sr.bad_beats;
        r->bytes = sr.ok_beats * 64;
        logmsg("WRITE target scan: %" PRIu64 " beats written correctly (%.3f MB), %" PRIu64
               " never written, %" PRIu64 " corrupt%s",
               sr.ok_beats, (double)sr.ok_beats * 64 / 1e6, sr.unwritten_beats, sr.bad_beats,
               sr.bad_beats ? " <-- ERROR" : "");
        if (o->count && (r->gbe || r->buf.nmr == 1)) {
            uint64_t exp = (o->count < nslots ? o->count : nslots) * o->len / 64;
            if (sr.ok_beats < exp) {
                r->lost += (exp - sr.ok_beats) * 64 / (o->len ? o->len : 1);
                logmsg("WRITE target: expected >= %" PRIu64 " written beats for --count %" PRIu64
                       " (window %" PRIu64 ", %" PRIu64 " slots), found %" PRIu64,
                       exp, o->count, window, nslots, sr.ok_beats);
            }
        }
    }
    return 0;
}

/* ---------------- roles: source and reader ---------------- */
static int run_active(struct run *r)
{
    struct opts *o = r->o;
    const struct rl_mr_rec *m = r->fmr;
    uint64_t win_avail = m->len > o->fpga_off ? m->len - o->fpga_off : 0;
    uint64_t window = o->window ? o->window : win_avail;
    int reader = o->role == R_READER;
    if (window > win_avail)
        window = win_avail;
    if (!reader && window > r->buf.mr[0]->length)
        window = r->buf.mr[0]->length;      /* the local mirror holds the window */
    if (window < o->len) {
        logerr("FPGA window %" PRIu64 " bytes (mr %d len 0x%" PRIx64 " - offset 0x%" PRIx64
               ", host buffer %zu) is smaller than --len %" PRIu64,
               window, m->idx, m->len, o->fpga_off, r->buf.mr[0]->length, o->len);
        return EX_USAGE;
    }
    if (o->len % 64 || (m->va + o->fpga_off) % 64)
        logmsg("note: FPGA-side buffers must be 64-byte aligned (rocelet v1 rule); len %" PRIu64
               ", VA 0x%" PRIx64, o->len, m->va + o->fpga_off);
    uint64_t nslots = rl_wg_nslots(window, o->len);
    uint64_t rva0 = m->va + o->fpga_off, pat0 = m->pat + o->fpga_off;
    uint32_t depth = o->depth;
    if (reader && (uint64_t)depth * o->len > r->buf.mr[0]->length) {
        depth = (uint32_t)(r->buf.mr[0]->length / o->len);
        if (!depth) {
            logerr("--buf-size too small for one --len READ");
            return EX_USAGE;
        }
        logmsg("note: depth limited to %u by --buf-size", depth);
    }
    uint32_t signal = reader ? 1 : (o->signal ? o->signal : (depth / 4 ? depth / 4 : 1));
    if (signal > depth)
        signal = depth;

    if (!reader)
        rl_pat_fill(r->buf.p, pat0, window, r->seed);    /* mirror of the FPGA window */
    logmsg("%s: %s %" PRIu64 " B per WR into FPGA VA 0x%" PRIx64 " (mr %d rkey 0x%x, window %" PRIu64
           " B = %" PRIu64 " slots, pattern addr 0x%" PRIx64 "), depth %u, signal 1/%u, rate %s",
           role_names[o->role], reader ? "READ" : op_names[o->op], o->len, rva0, m->idx, m->rkey,
           window, nslots, pat0, depth, signal, o->rate_bps > 0 ? "limited" : "unlimited");

    uint64_t posted = 0, completed = 0;
    double t_status = now_s(), t_last_cpl = now_s();
    uint64_t msgs_prev = 0, bytes_prev = 0;
    r->t_first = now_s();
    int posting = 1;

    while (!r->fatal) {
        double t = now_s();
        if (g_stop || r->quit)
            posting = 0;
        if (o->count && posted >= o->count)
            posting = 0;
        if (o->duration > 0 && t - r->t0 >= o->duration) {
            if (posting)
                set_stop(r, "duration reached");
            posting = 0;
        }
        /* post; when stopping, finish the current signaling batch so that the
         * last WR posted is signaled and every WR is accounted for */
        int finish = !posting && !r->fatal && (posted % signal) != 0 &&
                     !(o->count && posted >= o->count);
        while ((posting || finish) && posted - completed < depth) {
            if (o->count && posted >= o->count)
                break;                          /* never post beyond --count */
            if (o->rate_bps > 0) {
                double due = r->t_first + (double)(posted * o->len * 8) / o->rate_bps;
                if (now_s() < due)
                    break;
            }
            uint64_t s = posted % nslots;
            struct ibv_sge sge;
            struct ibv_send_wr wr, *bad;
            memset(&wr, 0, sizeof(wr));
            sge.length = (uint32_t)o->len;
            sge.lkey = r->buf.mr[0]->lkey;
            if (reader)
                sge.addr = (uintptr_t)(r->buf.p + (posted % depth) * o->len);
            else
                sge.addr = (uintptr_t)(r->buf.p + s * o->len);
            wr.wr_id = posted;
            wr.sg_list = &sge;
            wr.num_sge = o->len ? 1 : 0;
            int last = (o->count && posted + 1 == o->count) || (finish && (posted + 1) % signal == 0);
            wr.send_flags = (reader || (posted % signal) == signal - 1 || last) ? IBV_SEND_SIGNALED : 0;
            switch (reader ? OP_READ : o->op) {
            case OP_WRITE:     wr.opcode = IBV_WR_RDMA_WRITE; break;
            case OP_WRITE_IMM: wr.opcode = IBV_WR_RDMA_WRITE_WITH_IMM; break;
            case OP_SEND:      wr.opcode = IBV_WR_SEND; break;
            case OP_SEND_IMM:  wr.opcode = IBV_WR_SEND_WITH_IMM; break;
            case OP_READ:      wr.opcode = IBV_WR_RDMA_READ; break;
            }
            if (wr.opcode == IBV_WR_RDMA_WRITE_WITH_IMM || wr.opcode == IBV_WR_SEND_WITH_IMM)
                wr.imm_data = htonl(o->imm0 + (uint32_t)posted);
            if (wr.opcode != IBV_WR_SEND && wr.opcode != IBV_WR_SEND_WITH_IMM) {
                wr.wr.rdma.remote_addr = rva0 + s * o->len;
                wr.wr.rdma.rkey = m->rkey;
            }
            int rc = ibv_post_send(r->q.qp, &wr, &bad);
            if (rc) {
                logerr("ibv_post_send (WR %" PRIu64 "): %s", posted, strerror(rc));
                r->fatal = 1;
                set_stop(r, "post_send failed");
                break;
            }
            posted++;
            if (finish && posted % signal == 0)
                finish = 0;
        }
        /* complete */
        struct ibv_wc wc[32];
        int n = ibv_poll_cq(r->q.scq, 32, wc);
        if (n < 0) {
            logerr("ibv_poll_cq failed");
            r->fatal = 1;
            break;
        }
        for (int i = 0; i < n; i++) {
            struct ibv_wc *w = &wc[i];
            if (w->status != IBV_WC_SUCCESS) {
                r->wc_err++;
                logmsg("WC ERROR: %s (status %d, vendor_err 0x%x, opcode %d, WR %" PRIu64 ")",
                       ibv_wc_status_str(w->status), w->status, w->vendor_err, w->opcode,
                       w->wr_id);
                r->fatal = 1;
                set_stop(r, "work completion error");
                break;
            }
            uint64_t upto = w->wr_id + 1;
            if (reader) {
                uint64_t k = w->wr_id;
                if (verify_this(o, k))
                    region_check(&r->v, "READ", k, r->buf.p + (k % depth) * o->len,
                                 pat0 + (k % nslots) * o->len, o->len, r->seed);
            }
            if (upto > completed) {
                r->msgs += upto - completed;
                r->bytes += (upto - completed) * o->len;
                completed = upto;
            }
            t_last_cpl = now_s();
            r->t_last = t_last_cpl;
        }
        if (!posting && completed >= posted && (posted % signal == 0 || reader ||
                                                 (o->count && posted >= o->count) || r->fatal))
            break;
        if (!posting && now_s() - t_last_cpl > 30) {
            logmsg("timeout: %" PRIu64 " WRs still outstanding 30 s after the last completion",
                   posted - completed);
            set_stop(r, "completion timeout");
            r->fatal = 1;
            break;
        }
        t = now_s();
        if (t - t_status >= o->interval) {
            poll_ctl(r);
            poll_async(r->d.ctx, &r->fatal);
            status_line(r, t - r->t0, msgs_prev, bytes_prev, t - t_status);
            msgs_prev = r->msgs;
            bytes_prev = r->bytes;
            t_status = t;
        }
        if (!n && posting && o->rate_bps > 0) {
            struct timespec ts = { 0, 5000 };
            nanosleep(&ts, NULL);
        }
    }
    if (!r->stop_reason_set)
        set_stop(r, o->count && completed >= o->count ? "count reached" : "stopped");
    r->t_end = now_s();
    return 0;
}

/* ---------------- role: idle ---------------- */
static int run_idle(struct run *r)
{
    struct opts *o = r->o;
    double t_status = now_s();
    while (!g_stop && !r->quit && !r->fatal) {
        struct timespec ts = { 0, 50 * 1000 * 1000 };
        nanosleep(&ts, NULL);
        double t = now_s();
        if (t - t_status >= o->interval) {
            poll_ctl(r);
            poll_async(r->d.ctx, &r->fatal);
            status_line(r, t - r->t0, 0, 0, t - t_status);
            t_status = t;
        }
        if (o->duration > 0 && t - r->t0 >= o->duration) {
            set_stop(r, "duration reached");
            break;
        }
    }
    r->t_end = now_s();
    return 0;
}

/* ---------------- run command ---------------- */
static int wait_for_peer(struct run *r, int need_mr)
{
    char line[512], err[160];
    int have_conn = r->f.have_conn;
    double t_conn = 0;
    logmsg("waiting for the FPGA record (RLF%s) on %s ...", need_mr ? " + RLFM" : "",
           strcmp(r->o->ctl, "-") ? r->o->ctl : "stdin");
    for (;;) {
        if (g_stop)
            return -1;
        int rc = ctl_getline(&r->ctl, line, sizeof(line), 0.5);
        if (rc < 0) {
            logerr("control input closed before the FPGA record arrived");
            return -1;
        }
        if (rc == 1) {
            int k = rl_parse_record(line, &r->f, NULL, err, sizeof(err));
            if (k < 0)
                logmsg("ignored: %s", err);
            else if (k == 1 && !have_conn) {
                have_conn = 1;
                t_conn = now_s();
            } else if (!strcmp(line, "quit"))
                return -1;
        }
        if (have_conn && (!need_mr || r->f.nmr > 0)) {
            /* give trailing RLFM lines a moment to arrive */
            if (now_s() - t_conn > 0.3 || r->f.nmr > 0) {
                while (ctl_getline(&r->ctl, line, sizeof(line), 0.2) == 1) {
                    if (rl_parse_record(line, &r->f, NULL, err, sizeof(err)) < 0)
                        logmsg("ignored: %s", err);
                }
                return 0;
            }
        }
    }
}

static void print_host_record(struct run *r, const char *label)
{
    char l1[200], l2[200];
    rl_format_host(&r->h, l1, sizeof(l1), l2, sizeof(l2));
    logmsg("---- host record (%s): type these lines into the FPGA console ----", label);
    logmsg("%s", l1);
    if (l2[0])
        logmsg("%s", l2);
    logmsg("----");
    if (r->o->record_out) {
        FILE *f = fopen(r->o->record_out, "w");
        if (f) {
            fprintf(f, "%s\n", l1);
            if (l2[0])
                fprintf(f, "%s\n", l2);
            fclose(f);
        } else {
            logerr("cannot write %s: %s", r->o->record_out, strerror(errno));
        }
    }
}

static const struct rl_mr_rec *pick_mr(const struct rl_fpga_rec *f, int idx)
{
    if (!f->nmr)
        return NULL;
    if (idx < 0)
        return &f->mr[0];
    for (int i = 0; i < f->nmr; i++)
        if (f->mr[i].idx == idx)
            return &f->mr[i];
    return NULL;
}

/* GPU ring for --mem gpu: open the device, allocate (filled), export, register. */
static int gpu_ring_setup(struct run *r, uint64_t bsz, int acc)
{
    struct opts *o = r->o;
    if (r->gbe->open(&r->gctx, o->gpu, GPU_NB, o->gpu_batch, &r->ginfo))
        return -1;
    uint64_t cap = rl_gpu_ring_cap(&r->ginfo);
    if (o->buf_max && bsz < cap)
        bsz = cap;
    logmsg("GPU %d: %s (PCI %s, compute %d.%d), dma-buf %d, GPUDirect RDMA %d; BAR1 %" PRIu64
           " MiB (%" PRIu64 " MiB free) -> GPU ring cap %" PRIu64 " MiB", o->gpu, r->ginfo.name,
           r->ginfo.pci, r->ginfo.cc_major, r->ginfo.cc_minor, r->ginfo.dmabuf, r->ginfo.gdr,
           r->ginfo.bar1_total >> 20, r->ginfo.bar1_free >> 20, cap >> 20);
    if (!r->ginfo.dmabuf)
        logmsg("WARNING: the CUDA driver reports no dma-buf support (the NVIDIA open kernel "
               "module is needed): the registration will probably fail");
    if (rl_gring_alloc(&r->gr, r->gbe, r->gctx, &r->ginfo, bsz, (uint8_t)o->fill, 1))
        return -1;
    if (rl_gring_reg(&r->gr, r->d.pd, o->gpu_iova, acc))
        return -1;
    r->ring_mr = r->gr.mr;
    r->ring_va = r->gr.iova;
    r->ring_len = bsz;
    struct rl_gpu_info bi = r->ginfo;
    int b1 = r->gbe->bar1(r->gctx, &bi);
    logmsg("GPU ring: %" PRIu64 " bytes (%zu MiB allocated) at device address 0x%" PRIx64
           ", filled 0x%02x, dma-buf registered in %.1f ms at IOVA 0x%" PRIx64 " (%s), rkey 0x%x; "
           "BAR1 used %s%" PRIu64 " MiB", bsz, r->gr.alloc_size >> 20, r->gr.dptr, o->fill,
           r->gr.reg_ms, r->gr.iova,
           o->gpu_iova == RL_GRING_IOVA_DEV ? "the device address" :
           "IOVA 0: RLHM va= is the byte offset in the ring",
           r->ring_mr->rkey, b1 ? "unknown " : "", b1 ? 0 : (bi.bar1_total - bi.bar1_free) >> 20);
    return 0;
}

static void gpu_summary(struct run *r)
{
    struct rl_gpu_info bi = r->ginfo;
    int b1 = r->gbe->bar1(r->gctx, &bi);
    logmsg("GPU ring: %s, %" PRIu64 " MiB at IOVA 0x%" PRIx64 ", BAR1 used %" PRIu64 " of %" PRIu64
           " MiB%s", r->ginfo.name, r->ring_len >> 20, r->ring_va,
           b1 ? 0 : (bi.bar1_total - bi.bar1_free) >> 20, bi.bar1_total >> 20,
           b1 ? " (unknown, no NVML)" : "");
    if (r->gv) {
        struct rl_gpuv_stats st;
        rl_gpuv_stats(r->gv, &st);
        logmsg("GPU verify: %" PRIu64 " messages in %" PRIu64 " launches (avg batch %.1f, max %u), "
               "kernel %.1f ms = %.2f %% GPU busy, back-pressure waits %" PRIu64 ", unchecked %"
               PRIu64 ", scrub %s", st.gpu_jobs, st.launches, st.avg_batch, st.max_batch,
               st.gpu_ms, 100 * st.gpu_busy, st.full_waits, st.unchecked, r->scrub ? "on" : "off");
    }
    if (r->g_fill || r->g_mis || r->g_cor)
        logmsg("GPU bad beats: %" PRIu64 " fill (never written / not visible at the completion), %"
               PRIu64 " misplaced (pattern of another address), %" PRIu64 " corrupt", r->g_fill,
               r->g_mis, r->g_cor);
}

static int cmd_run(struct opts *o)
{
    struct run *r = calloc(1, sizeof(*r));
    int ex = EX_OK;
    char ips[20], macs[24], gs[64], err[160];
    if (!r)
        return EX_SETUP;
    r->o = o;
    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);

    int need_mr = o->role == R_SOURCE || o->role == R_READER;
    if (o->role == R_READER)
        o->op = OP_READ;
    if (o->role != R_READER && o->op == OP_READ) {
        logerr("--op read needs --role reader");
        free(r);
        return EX_USAGE;
    }
    if (o->qp_type == IBV_QPT_UC && o->role == R_READER) {
        logerr("UC has no RDMA READ");
        free(r);
        return EX_USAGE;
    }
    r->gr.fd = -1;
    if (o->mem_gpu) {
        if (o->role != R_SINK || (o->op != OP_WRITE && o->op != OP_WRITE_IMM)) {
            logerr("--mem gpu: only --role sink --op write|write_imm so far (a GPU ring for "
                   "send/send_imm and the reader role come later)");
            free(r);
            return EX_USAGE;
        }
        if (o->nbuf != 1) {
            logerr("--mem gpu: one ring only (--nbuf 1)");
            free(r);
            return EX_USAGE;
        }
        r->gbe = rl_gpu_backend_cuda();
        if (!r->gbe) {
            logerr("--mem gpu: this rocelet_host was built without CUDA. Rebuild it with "
                   "`make CUDA=1` (CUDA toolkit 11.7 or newer, rdma-core >= 34, NVIDIA open kernel "
                   "module; see docs/host-setup.md, \"GPU ring\")");
            free(r);
            return EX_SETUP;
        }
    } else if (o->buf_max) {
        logerr("--buf-size max is for --mem gpu (the largest ring BAR1 allows)");
        free(r);
        return EX_USAGE;
    }

    for (int i = 0; i < o->npeer; i++)
        if (rl_parse_record(o->peer[i], &r->f, NULL, err, sizeof(err)) <= 0) {
            logerr("--peer '%s': %s", o->peer[i], rl_parse_record(o->peer[i], &r->f, NULL, err,
                   sizeof(err)) == 0 ? "not an RLF/RLFM record" : err);
            free(r);
            return EX_USAGE;
        }

    ex = vdev_open(&r->d, o->dev, o->port, o->gid_index, o->have_local_ip ? o->local_ip : NULL, 1, 1);
    if (ex)
        goto out_free;
    logmsg("device %s port %u: netdev %s (MTU %d), MAC %s, GID[%d] %s, active_mtu %u, %s",
           r->d.name, r->d.port, r->d.netdev, r->d.netdev_mtu, mac_str(r->d.mac, macs, sizeof(macs)),
           r->d.gid_index, gid_str(r->d.gid, gs, sizeof(gs)), mtu_from_ibv(r->d.pattr.active_mtu),
           ibv_port_state_str(r->d.pattr.state));
    int fl = fcntl(r->d.ctx->async_fd, F_GETFL);
    fcntl(r->d.ctx->async_fd, F_SETFL, fl | O_NONBLOCK);

    uint32_t mtu_cap = o->pmtu;
    uint32_t active = mtu_from_ibv(r->d.pattr.active_mtu);
    if (mtu_cap > active) {
        logerr("path MTU %u requested but %s active_mtu is %u (netdev %s MTU %d): raise the "
               "netdev MTU (sudo ip link set dev %s mtu 4200) or use --pmtu %u",
               mtu_cap, r->d.name, active, r->d.netdev, r->d.netdev_mtu, r->d.netdev, active);
        ex = EX_SETUP;
        goto out_dev;
    }

    /* memory */
    size_t bsz = o->buf_size;
    if (o->role == R_SINK && o->op == OP_WRITE_IMM && o->window && o->window > bsz)
        bsz = o->window;
    int acc = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE;
    if (o->qp_type == IBV_QPT_RC)
        acc |= IBV_ACCESS_REMOTE_READ;
    if (r->gbe) {
        if (gpu_ring_setup(r, bsz, acc)) {
            ex = EX_SETUP;
            goto out_buf;
        }
    } else {
        if (hbuf_alloc(&r->buf, bsz, o->hugepages)) {
            ex = EX_SETUP;
            goto out_dev;
        }
        memset(r->buf.p, o->fill, r->buf.size);
        if (hbuf_reg(&r->buf, r->d.pd, bsz, o->role == R_SINK ? o->nbuf : 1, acc)) {
            ex = EX_SETUP;
            goto out_buf;
        }
        r->ring_mr = r->buf.mr[0];
        r->ring_va = (uintptr_t)r->buf.mr[0]->addr;
        r->ring_len = r->buf.mr[0]->length;
    }
    int recv_needed = o->role == R_SINK && o->op != OP_WRITE;
    if (recv_needed) {
        r->rq_slot = o->op == OP_WRITE_IMM ? 64 : (size_t)((o->len + 63) & ~63ull);
        if (!r->rq_slot)
            r->rq_slot = 64;
        if (hbuf_alloc(&r->rqb, r->rq_slot * o->rq_depth, o->hugepages) ||
            hbuf_reg(&r->rqb, r->d.pd, r->rq_slot * o->rq_depth, 1, IBV_ACCESS_LOCAL_WRITE)) {
            ex = EX_SETUP;
            goto out_buf;
        }
    }
    if (!r->gbe)
        logmsg("host buffer: %zu bytes at %p (%s pages)%s", r->buf.size, (void *)r->buf.p,
               r->buf.huge ? "2 MiB" : "4 KiB",
               r->buf.huge ? "" : " - reserve hugepages for line-rate tests (see README)");

    /* QP */
    uint32_t max_send = o->role == R_SINK || o->role == R_IDLE ? 4 : o->depth + 1;
    uint32_t max_recv = recv_needed ? o->rq_depth : 4;
    if (vqp_create(&r->d, &r->q, o->qp_type, max_send, max_recv)) {
        ex = EX_SETUP;
        goto out_buf;
    }
    if (vqp_to_init(&r->q, r->d.port, acc)) {
        ex = EX_SETUP;
        goto out_qp;
    }
    if (recv_needed)
        for (uint32_t i = 0; i < o->rq_depth; i++)
            if (post_recv(r, i)) {
                ex = EX_SETUP;
                goto out_qp;
            }

    /* host record (preliminary unless the FPGA record is already known) */
    if (!o->psn_set) {
        uint32_t rnd = 0;
        if (getrandom(&rnd, sizeof(rnd), 0) != sizeof(rnd))
            rnd = (uint32_t)time(NULL) * 2654435761u;
        o->psn = rnd & 0xFFFFFF;
    }
    r->h.have_conn = 1;
    r->h.qpn = r->q.qp->qp_num;
    r->h.psn = o->psn;
    memcpy(r->h.ip, r->d.ipv4, 4);
    memcpy(r->h.mac, r->d.mac, 6);
    r->h.mtu = mtu_cap;
    r->h.ord = (uint32_t)o->max_rd;
    r->h.have_mr = 1;
    r->h.rkey = r->ring_mr->rkey;
    r->h.va = r->ring_va;
    r->h.len = r->ring_len;
    if (r->buf.nmr > 1)
        for (int i = 1; i < r->buf.nmr; i++)
            logmsg("extra host window %d: rkey=0x%x va=0x%" PRIx64 " len=0x%zx", i,
                   r->buf.mr[i]->rkey, (uint64_t)(uintptr_t)r->buf.mr[i]->addr,
                   r->buf.mr[i]->length);

    if (ctl_open(&r->ctl, o->ctl)) {
        ex = EX_SETUP;
        goto out_qp;
    }
    if (!r->f.have_conn || (need_mr && !r->f.nmr)) {
        print_host_record(r, "preliminary: mtu/ord may still drop to the FPGA's values");
        if (wait_for_peer(r, need_mr)) {
            ex = EX_PEER;
            goto out_qp;
        }
    }

    /* negotiate */
    r->mtu = mtu_cap;
    if (r->f.mtu && r->f.mtu < r->mtu)
        r->mtu = r->f.mtu;
    int ord = o->max_rd;
    if (ord > r->d.dattr.max_qp_init_rd_atom)
        ord = r->d.dattr.max_qp_init_rd_atom;
    if (r->f.rd && (uint32_t)ord > r->f.rd)
        ord = (int)r->f.rd;
    if (ord < 1)
        ord = 1;
    if (o->role == R_READER && r->f.have_conn && !r->f.rd)
        logmsg("note: the FPGA record has no rd= (READ depth); using max_rd_atomic %d", ord);
    r->seed = o->seed_set ? o->seed : r->f.have_seed ? r->f.seed : 0;
    r->h.mtu = r->mtu;
    r->h.ord = (uint32_t)ord;
    if (need_mr) {
        r->fmr = pick_mr(&r->f, o->fpga_mr);
        if (!r->fmr) {
            logerr("no FPGA window (RLFM%s) for the %s role", o->fpga_mr >= 0 ? " with that mr=" : "",
                   role_names[o->role]);
            ex = EX_PEER;
            goto out_qp;
        }
        if (o->role == R_READER && !(r->fmr->acc & 2))
            logmsg("note: FPGA window mr=%d is not marked readable (acc)", r->fmr->idx);
        if (o->role == R_SOURCE && (o->op == OP_WRITE || o->op == OP_WRITE_IMM) && !(r->fmr->acc & 1))
            logmsg("note: FPGA window mr=%d is not marked writable (acc)", r->fmr->idx);
    }
    logmsg("FPGA: QP %d QPN 0x%06x first PSN 0x%06x, IP %s, MAC %s, mtu %u, READ depth %u, seed 0x%08x%s",
           r->f.qp, r->f.qpn, r->f.psn, ip4_str(r->f.ip, ips, sizeof(ips)),
           r->f.have_mac ? mac_str(r->f.mac, macs, sizeof(macs)) : "(not given)", r->f.mtu, r->f.rd,
           r->seed, o->seed_set ? " (--seed)" : "");
    print_host_record(r, "final");

    /* neighbour (the kernel resolves the FPGA MAC at RTR) */
    uint8_t nmac[6];
    char nfl[48] = "";
    int nb = neigh_lookup(r->d.netdev, r->f.ip, nmac, nfl, sizeof(nfl));
    if (nb == 1) {
        logmsg("neighbour %s on %s: %s (%s)%s", ips, r->d.netdev, mac_str(nmac, macs, sizeof(macs)),
               nfl, r->f.have_mac && memcmp(nmac, r->f.mac, 6) ? "  <-- DIFFERS from the FPGA record" : "");
    } else {
        logmsg("neighbour %s on %s: %s; the QP's RTR transition will ARP for it (the FPGA must "
               "answer within 1 s)", ips, r->d.netdev, nb < 0 ? "unknown" : "not resolved yet");
    }

    /* RTR / RTS */
    struct qp_params p;
    memset(&p, 0, sizeof(p));
    p.type = o->qp_type;
    p.mtu = r->mtu;
    p.dest_qpn = r->f.qpn;
    p.rq_psn = r->f.psn;
    p.sq_psn = r->h.psn;
    static const uint8_t v4pfx[12] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    memcpy(p.dgid, v4pfx, 12);
    memcpy(p.dgid + 12, r->f.ip, 4);
    p.traffic_class = o->tclass;
    p.hop_limit = o->hop_limit;
    p.timeout = o->timeout;
    p.retry_cnt = o->retry;
    p.rnr_retry = o->rnr_retry;
    p.min_rnr_timer = o->min_rnr;
    p.max_rd_atomic = (uint8_t)ord;
    p.max_dest_rd_atomic = (uint8_t)o->max_dest_rd;
    p.migreq = o->migreq;
    p.access = acc;
    if (vqp_to_rtr(&r->q, &r->d, &p) || vqp_to_rts(&r->q, &p)) {
        ex = EX_PEER;
        goto out_qp;
    }
    vqp_print_state(&r->q, "after RTS");
    nb = neigh_lookup(r->d.netdev, r->f.ip, nmac, nfl, sizeof(nfl));
    if (nb == 1)
        logmsg("neighbour %s resolved: %s (%s)", ips, mac_str(nmac, macs, sizeof(macs)), nfl);

    snap_take(&r->s0, r->d.name, r->d.port, r->d.netdev);
    r->si = r->s0;
    logmsg("RLH READY qpn=0x%x role=%s op=%s len=%" PRIu64 " count=%" PRIu64 " mtu=%u seed=0x%x",
           r->h.qpn, role_names[o->role], o->role == R_IDLE ? "-" : op_names[o->op], o->len,
           o->count, r->mtu, r->seed);

    if ((o->role == R_SOURCE || o->role == R_READER) && o->wait_go) {
        char line[512];
        logmsg("type 'go' (control input) once the FPGA has applied the RLH/RLHM lines");
        for (;;) {
            if (g_stop) {
                ex = EX_PEER;
                goto out_report;
            }
            int rc = ctl_getline(&r->ctl, line, sizeof(line), 0.5);
            if (rc < 0) {
                logerr("control input closed before 'go'");
                ex = EX_PEER;
                goto out_report;
            }
            if (rc == 1 && !strcmp(line, "go"))
                break;
            if (rc == 1 && !strcmp(line, "quit")) {
                ex = EX_PEER;
                goto out_report;
            }
        }
    } else if (o->role == R_SINK) {
        logmsg("start the FPGA sender now (e.g. its WR generator with len=%" PRIu64
               ", window=host len, rkey/va from RLHM)", o->len);
    }

    r->t0 = now_s();
    switch (o->role) {
    case R_SINK:   run_sink(r); break;
    case R_SOURCE:
    case R_READER: ex = run_active(r); break;
    case R_IDLE:   run_idle(r); break;
    }
    if (ex == EX_USAGE)
        goto out_report;

out_report:
    poll_async(r->d.ctx, &r->fatal);
    snap_take(&r->s1, r->d.name, r->d.port, r->d.netdev);
    {
        double dt = (r->t_last > r->t_first) ? r->t_last - r->t_first : 0;
        double gbps = dt > 0 ? (double)r->bytes * 8 / dt / 1e9 : 0;
        logmsg("==== summary: role %s op %s, stopped by: %s", role_names[o->role],
               o->role == R_IDLE ? "-" : op_names[o->op],
               r->stop_reason_set ? r->stop_reason : (g_stop ? "Ctrl-C" : "end"));
        logmsg("messages %" PRIu64 ", bytes %" PRIu64 " (%.3f GB), first..last %.3f s, %.2f Gb/s payload%s",
               r->msgs, r->bytes, (double)r->bytes / 1e9, dt, gbps,
               o->role == R_SINK && o->op == OP_WRITE ? " (plain WRITE: bytes = distinct beats "
               "verified in the buffer, not bytes transferred)" : "");
        uint64_t hw_in = snapv(&r->s1, "hw.ip4InOctets") - snapv(&r->s0, "hw.ip4InOctets");
        uint64_t hw_out = snapv(&r->s1, "hw.ip4OutOctets") - snapv(&r->s0, "hw.ip4OutOctets");
        double hdt = r->s1.t - r->s0.t;
        logmsg("RDMA-engine IPv4 octets: in %" PRIu64 " (%.2f Gb/s), out %" PRIu64
               " (%.2f Gb/s) over %.1f s (IP+UDP+BTH+payload+ICRC, whole run incl. idle time)",
               hw_in, hdt > 0 ? (double)hw_in * 8 / hdt / 1e9 : 0, hw_out,
               hdt > 0 ? (double)hw_out * 8 / hdt / 1e9 : 0, hdt);
        if (r->len_note)
            logmsg("WRITE+imm completions with byte_len != --len: %" PRIu64 " (informational)",
                   r->len_note);
        logmsg("errors: wc %" PRIu64 ", lost %" PRIu64 ", dup %" PRIu64 ", seq %" PRIu64
               ", length %" PRIu64 ", data %" PRIu64 " msgs / %" PRIu64 " bytes (checked %" PRIu64
               " bytes), qp/async fatal %d",
               r->wc_err, r->lost, r->dup, r->seq_err, r->len_err, r->v.bad_msgs, r->v.bad_bytes,
               r->v.checked_bytes, r->fatal);
        if (r->gbe)
            gpu_summary(r);
        if (g_link.events)
            logmsg("link: %d port-down event(s), longest outage %.2f s%s", g_link.events,
                   g_link.down ? now_s() - g_link.t_down : g_link.longest, g_link.down ? " (still down)" : "");
        logmsg("counter deltas (%s, netdev %s):", r->d.name, r->d.netdev);
        snap_print_delta(&r->s0, &r->s1, stdout, 0);
        snap_print_problems(&r->s0, &r->s1, stdout);
        vqp_print_state(&r->q, "at end");
        /* completion-based sinks (WRITE+imm, SEND): every one of --count messages must arrive;
         * a stream that stops early (silence) or delivers nothing (frames the NIC rejected, e.g.
         * rxVlanErrors, still count in ip4InOctets) is not a PASS */
        int cpl_sink = o->role == R_SINK && o->op != OP_WRITE;
        uint64_t missing = (cpl_sink && o->count && r->msgs < o->count) ? o->count - r->msgs : 0;
        if (missing)
            logmsg("missing: %" PRIu64 " of --count %" PRIu64 " messages never arrived", missing, o->count);
        int errors = r->wc_err || r->lost || r->dup || r->seq_err || r->len_err || r->v.bad_msgs ||
                     r->fatal || (missing && r->msgs) || r->g_unchecked;
        if (ex == EX_OK) {
            if (errors)
                ex = EX_ERRORS;
            else if (o->role == R_SINK && r->msgs == 0 && r->bytes == 0 && (cpl_sink || hw_in == 0))
                ex = EX_NODATA;
        }
        logmsg("result: %s (exit %d)", ex == EX_OK ? "PASS" : "FAIL", ex);
        if (o->json)
            printf("{\"type\":\"summary\",\"role\":\"%s\",\"op\":\"%s\",\"mem\":\"%s\",\"msgs\":%" PRIu64
                   ",\"bytes\":%" PRIu64 ",\"seconds\":%.6f,\"gbps\":%.3f,\"wc_err\":%" PRIu64
                   ",\"lost\":%" PRIu64 ",\"dup\":%" PRIu64 ",\"seq_err\":%" PRIu64
                   ",\"len_err\":%" PRIu64 ",\"bad_msgs\":%" PRIu64 ",\"bad_bytes\":%" PRIu64
                   ",\"checked_bytes\":%" PRIu64 ",\"fatal\":%d,\"exit\":%d}\n",
                   role_names[o->role], op_names[o->op], r->gbe ? "gpu" : "host", r->msgs, r->bytes,
                   dt, gbps, r->wc_err,
                   r->lost, r->dup, r->seq_err, r->len_err, r->v.bad_msgs, r->v.bad_bytes,
                   r->v.checked_bytes, r->fatal, ex);
    }
out_qp:
    vqp_destroy(&r->q);
out_buf:
    hbuf_free(&r->rqb);
    hbuf_free(&r->buf);
    rl_gpuv_destroy(r->gv);         /* before the ring it reads goes away */
    rl_gring_free(&r->gr);          /* dereg (after the QP), dma-buf, cudaFree */
    if (r->gctx)
        r->gbe->close(r->gctx);
out_dev:
    vdev_close(&r->d);
out_free:
    free(r);
    return ex;
}

/* ---------------- other commands ---------------- */
static int cmd_info(struct opts *o)
{
    int ex = vdev_print_info(o->dev, o->port);
    if (ex)
        return ex;
    struct vdev d;
    if (vdev_open(&d, o->dev, o->port, o->gid_index, o->have_local_ip ? o->local_ip : NULL, 0, 0) ==
        EX_OK) {
        char macs[24], ips[20];
        printf("netdev %s: MTU %d, MAC %s, IPv4 %s (GID index %d)\n", d.netdev, d.netdev_mtu,
               mac_str(d.mac, macs, sizeof(macs)), ip4_str(d.ipv4, ips, sizeof(ips)), d.gid_index);
        if (o->have_fpga_ip) {
            uint8_t m[6];
            char fl[48] = "";
            int nb = neigh_lookup(d.netdev, o->fpga_ip, m, fl, sizeof(fl));
            printf("neighbour %s: %s%s%s\n", ip4_str(o->fpga_ip, ips, sizeof(ips)),
                   nb == 1 ? mac_str(m, macs, sizeof(macs)) : nb < 0 ? "unknown" : "not resolved",
                   nb == 1 ? " " : "", fl);
        }
        vdev_close(&d);
    }
    return EX_OK;
}

/* netdev of an RDMA device from sysfs (no GID / IP address needed) */
static const char *dev_netdev(const char *dev, char *buf, size_t n)
{
    char path[256];
    snprintf(path, sizeof(path), "/sys/class/infiniband/%s/device/net", dev);
    DIR *d = opendir(path);
    struct dirent *de;
    buf[0] = 0;
    if (!d)
        return NULL;
    while ((de = readdir(d)))
        if (de->d_name[0] != '.' && strlen(de->d_name) < n) {
            memcpy(buf, de->d_name, strlen(de->d_name) + 1);
            break;
        }
    closedir(d);
    return buf[0] ? buf : NULL;
}

static int cmd_counters(struct opts *o)
{
    char ndbuf[IF_NAMESIZE + 1];
    const char *nd = dev_netdev(o->dev, ndbuf, sizeof(ndbuf));
    struct snap s;
    snap_take(&s, o->dev, o->port, nd);
    if (o->diff) {
        struct snap a;
        if (snap_load(&a, o->diff))
            return EX_USAGE;
        printf("counter deltas since %s (%.1f s):\n", o->diff, s.t - a.t);
        snap_print_delta(&a, &s, stdout, o->all);
        snap_print_problems(&a, &s, stdout);
    } else {
        snap_print(&s, stdout);
    }
    if (o->save)
        snap_save(&s, o->save);
    return EX_OK;
}

static int cmd_pattern(struct opts *o)
{
    uint8_t b[64];
    uint32_t seed = o->seed_set ? o->seed : 0;
    for (uint64_t off = 0; off < o->pat_len; off += 64) {
        rl_pat_beat(o->pat_addr + off, seed, b);
        for (int j = 0; j < 64 && off + (uint64_t)j < o->pat_len; j += 16) {
            printf("%016" PRIx64 ":", o->pat_addr + off + (uint64_t)j);
            for (int k = 0; k < 16 && off + (uint64_t)(j + k) < o->pat_len; k++)
                printf(" %02x", b[j + k]);
            printf("\n");
        }
    }
    return EX_OK;
}

static int cmd_selftest(void)
{
    int fails = 0;
    uint8_t b[64], buf[256];
    /* 1. pattern: reference vector (tests/pattern_ref.py, transcribed from rl_sys_pkg.sv) */
    static const uint8_t ref0[16] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
                                      0xe0, 0x69, 0x5d, 0x20, 0xee, 0x8c, 0x24, 0xfd };
    rl_pat_beat(0x0000010000000000ull, 0x5EED1234u, b);
    if (memcmp(b, ref0, 16)) {
        printf("selftest FAIL: pattern vector\n  got:");
        for (int i = 0; i < 16; i++)
            printf(" %02x", b[i]);
        printf("\n");
        fails++;
    }
    /* 2. fill/check round trip at an unaligned pattern address */
    rl_pat_fill(buf, 0x1234567, sizeof(buf), 7);
    size_t first;
    if (rl_pat_check(buf, 0x1234567, sizeof(buf), 7, &first) != 0) {
        printf("selftest FAIL: fill/check\n");
        fails++;
    }
    buf[100] ^= 1;
    if (rl_pat_check(buf, 0x1234567, sizeof(buf), 7, &first) != 1 || first != 100) {
        printf("selftest FAIL: mismatch detection\n");
        fails++;
    }
    /* 3. records */
    struct rl_fpga_rec f;
    struct rl_host_rec h, h2;
    char err[160], l1[200], l2[200];
    memset(&f, 0, sizeof(f));
    const char *rlf = "rl> RLF qp=0 qpn=0x100 psn=0x10123 ip=192.168.20.2 mac=020a35726c01 mtu=4096 "
                      "rd=16 seed=0x5eed1234";
    const char *rlfm = "RLFM mr=1 rkey=0x2001 va=0x0 len=0x40000 acc=rw";
    if (rl_parse_record(rlf, &f, NULL, err, sizeof(err)) != 1 || f.qpn != 0x100 || f.psn != 0x10123 ||
        f.ip[3] != 2 || f.mac[0] != 0x02 || f.mac[5] != 0x01 || f.mtu != 4096 || f.rd != 16 ||
        f.seed != 0x5eed1234) {
        printf("selftest FAIL: RLF parse (%s)\n", err);
        fails++;
    }
    if (rl_parse_record(rlfm, &f, NULL, err, sizeof(err)) != 2 || f.nmr != 1 || f.mr[0].idx != 1 ||
        f.mr[0].rkey != 0x2001 || f.mr[0].len != 0x40000 || f.mr[0].pat != 0 || f.mr[0].acc != 3) {
        printf("selftest FAIL: RLFM parse (%s)\n", err);
        fails++;
    }
    if (rl_parse_record("RLF qpn=0x1000000 psn=0 ip=1.2.3.4", &f, NULL, err, sizeof(err)) != -1) {
        printf("selftest FAIL: out-of-range QPN accepted\n");
        fails++;
    }
    if (rl_parse_record("hello RLFX", &f, NULL, err, sizeof(err)) != 0) {
        printf("selftest FAIL: non-record parsed\n");
        fails++;
    }
    memset(&h, 0, sizeof(h));
    h.qpn = 0x1b; h.psn = 0x3c2b1a; h.mtu = 4096; h.ord = 16; h.have_mr = 1;
    h.ip[0] = 192; h.ip[1] = 168; h.ip[2] = 20; h.ip[3] = 1;
    uint8_t mac[6] = { 0x6c, 0xfe, 0x54, 0x91, 0x77, 0xf0 };
    memcpy(h.mac, mac, 6);
    h.rkey = 0x12ab; h.va = 0x7f3e40000000ull; h.len = 0x4000000;
    rl_format_host(&h, l1, sizeof(l1), l2, sizeof(l2));
    memset(&h2, 0, sizeof(h2));
    if (rl_parse_record(l1, NULL, &h2, err, sizeof(err)) != 3 ||
        rl_parse_record(l2, NULL, &h2, err, sizeof(err)) != 4 || h2.qpn != h.qpn || h2.psn != h.psn ||
        memcmp(h2.mac, h.mac, 6) || memcmp(h2.ip, h.ip, 4) || h2.mtu != 4096 || h2.ord != 16 ||
        h2.rkey != h.rkey || h2.va != h.va || h2.len != h.len) {
        printf("selftest FAIL: RLH/RLHM round trip (%s)\n  %s\n  %s\n", err, l1, l2);
        fails++;
    }
    if (strlen(l1) > 100 || strlen(l2) > 100) {
        printf("selftest FAIL: host record lines longer than 100 chars (FPGA console limit)\n");
        fails++;
    }
    /* 4. slot model */
    if (rl_wg_nslots(1 << 20, 65536) != 16 || rl_wg_nslots(100000, 65536) != 1 ||
        rl_wg_nslots(1000, 4096) != 1) {
        printf("selftest FAIL: slot model\n");
        fails++;
    }
    printf("selftest: %s\n  example host record:\n  %s\n  %s\n", fails ? "FAIL" : "PASS", l1, l2);
    return fails ? EX_ERRORS : EX_OK;
}

/* ---------------- command line ---------------- */
static void usage(void)
{
    printf(
        "rocelet_host %s - host helper for rocelet FPGA RoCE v2 interop tests (libibverbs, no rdma_cm)\n"
        "\n"
        "usage: rocelet_host <command> [options]\n"
        "  run        create an RC QP, exchange records with the FPGA console, run a role\n"
        "  info       device / port / GID table / netdev summary (--fpga-ip: neighbour entry)\n"
        "  counters   hw_counters + netdev statistics [--save FILE] [--diff FILE] [--all]\n"
        "  pattern    print the payload pattern: --addr A [--seed S] [--len N]\n"
        "  selftest   pattern, record and slot-model checks (no RDMA device needed)\n"
        "  selftest-gpu  GPU ring without NIC traffic: verify kernel = CPU reference, scrub,\n"
        "             scan, BAR1 cap, dma-buf registration on --dev (no QP), throughput\n"
        "             [--mock] [--gpu N] [--dev D] [--buf-size BYTES|max] [--gpu-iova 0|dev]\n"
        "\n"
        "device:   --dev D (default: the first RDMA device present)  --port 1\n"
        "          --gid-index N (default: the RoCE v2 IPv4 GID)\n"
        "          --local-ip A.B.C.D (choose among several IPv4 GIDs)\n"
        "role:     --role sink|source|reader|idle   --op write|write_imm|send|send_imm\n"
        "          (sink: what the FPGA sends; source: what the host sends; reader: RDMA READ)\n"
        "sizes:    --len BYTES (64K)  --count N (0 = until stopped)  --duration S\n"
        "          --buf-size BYTES (64M)  --nbuf N (sink: N separately registered windows)\n"
        "          --window BYTES (WR window; default host buffer / FPGA window)\n"
        "          --rq-depth N (256)  --depth N (16 outstanding)  --signal N\n"
        "rate:     --rate 1G|10G|max (source/reader, payload bits/s; default 1G)\n"
        "QP:       --pmtu 256..4096 (4096; capped by active_mtu and the FPGA's mtu=)\n"
        "          --psn 0xNNNNNN (random)  --qp-type rc|uc  --tclass N (0)  --hop-limit N (64)\n"
        "          --timeout N (14)  --retry N (7)  --rnr-retry N (7)  --min-rnr-timer N (12)\n"
        "          --max-rd N (16, host READs in flight, capped by the FPGA's rd=)\n"
        "          --max-dest-rd N (1)  --migreq migrated|rearm|armed (default: not set)\n"
        "exchange: --peer 'RLF ...' --peer 'RLFM ...' (else read from --ctl)\n"
        "          --ctl -|FILE|FIFO (stdin; lines: RLF/RLFM records, go, done, stats, quit)\n"
        "          --record-out FILE (write the RLH/RLHM lines)  --no-wait (source/reader: no 'go')\n"
        "          --fpga-mr N (RLFM mr= to use)  --fpga-off BYTES (offset in that window)\n"
        "data:     --seed 0xS (default: the FPGA's seed=)  --verify full|none|sample:N\n"
        "          --imm0 0xN (first immediate; 0x10000 = the FPGA WR generator)\n"
        "          --send-base A (SEND pattern base; default: learned)  --fill 0xNN (0x5a)\n"
        "          --hugepages off|try|on (try)\n"
        "GPU:      --mem host|gpu (host; gpu = sink --op write|write_imm into GPU memory via\n"
        "          dma-buf, checked on the GPU; needs a `make CUDA=1` build)  --gpu N (0)\n"
        "          --buf-size BYTES|max (GPU ring; max = BAR1 - 16 MiB, 240 MiB on a 256 MiB BAR1)\n"
        "          --gpu-iova 0|dev (0: RLHM va= is the ring offset)  --gpu-batch N (64)\n"
        "          --gpu-wait-us N (200)  --gpu-scrub auto|on|off (auto: on if the slots >= 16 MiB)\n"
        "run:      --interval S (1)  --silence S (10)  --start-timeout S (120)  --json\n"
        "          --link-grace S (10, silence held after the port is ACTIVE again)\n"
        "          --link-down-max S (60, port-down time that fails the run)\n"
        "          --repost-delay-us N (sink: re-post each receive N us late: RNR tests)\n"
        "\n"
        "exit: 0 PASS, 1 usage, 2 local setup, 3 FPGA record / QP bring-up, 4 errors found,\n"
        "      5 sink received nothing. See README.md.\n",
        RL_HOST_VERSION);
}

enum {
    O_DEV = 256, O_PORT, O_GID, O_LOCALIP, O_ROLE, O_OP, O_LEN, O_COUNT, O_DUR, O_RATE, O_DEPTH,
    O_SIGNAL, O_BUFSZ, O_NBUF, O_WINDOW, O_RQ, O_PMTU, O_PSN, O_QPTYPE, O_TCLASS, O_HOP, O_TIMEOUT,
    O_RETRY, O_RNR, O_MINRNR, O_MAXRD, O_MAXDRD, O_MIG, O_PEER, O_CTL, O_RECOUT, O_NOWAIT, O_FMR,
    O_FOFF, O_SEED, O_VERIFY, O_IMM0, O_SBASE, O_FILL, O_HUGE, O_INTERVAL, O_SILENCE, O_STARTTO, O_LGRACE, O_LDOWNMAX,
    O_JSON, O_SAVE, O_DIFF, O_ALL, O_ADDR, O_FPGAIP, O_HELP, O_REPOST, O_MEM, O_GPU, O_GIOVA,
    O_GBATCH, O_GWAIT, O_GSCRUB, O_MOCK
};

static int parse_ip_opt(const char *s, uint8_t ip[4])
{
    struct in_addr a;
    if (inet_pton(AF_INET, s, &a) != 1)
        return -1;
    memcpy(ip, &a, 4);
    return 0;
}

int main(int argc, char **argv)
{
    static const struct option lo[] = {
        { "dev", 1, 0, O_DEV }, { "port", 1, 0, O_PORT }, { "gid-index", 1, 0, O_GID },
        { "local-ip", 1, 0, O_LOCALIP }, { "role", 1, 0, O_ROLE }, { "op", 1, 0, O_OP },
        { "len", 1, 0, O_LEN }, { "count", 1, 0, O_COUNT }, { "duration", 1, 0, O_DUR },
        { "rate", 1, 0, O_RATE }, { "depth", 1, 0, O_DEPTH }, { "signal", 1, 0, O_SIGNAL },
        { "buf-size", 1, 0, O_BUFSZ }, { "nbuf", 1, 0, O_NBUF }, { "window", 1, 0, O_WINDOW },
        { "rq-depth", 1, 0, O_RQ }, { "pmtu", 1, 0, O_PMTU }, { "psn", 1, 0, O_PSN },
        { "qp-type", 1, 0, O_QPTYPE }, { "tclass", 1, 0, O_TCLASS }, { "hop-limit", 1, 0, O_HOP },
        { "timeout", 1, 0, O_TIMEOUT }, { "retry", 1, 0, O_RETRY }, { "rnr-retry", 1, 0, O_RNR },
        { "min-rnr-timer", 1, 0, O_MINRNR }, { "max-rd", 1, 0, O_MAXRD },
        { "max-dest-rd", 1, 0, O_MAXDRD }, { "migreq", 1, 0, O_MIG }, { "peer", 1, 0, O_PEER },
        { "ctl", 1, 0, O_CTL }, { "record-out", 1, 0, O_RECOUT }, { "no-wait", 0, 0, O_NOWAIT },
        { "fpga-mr", 1, 0, O_FMR }, { "fpga-off", 1, 0, O_FOFF }, { "seed", 1, 0, O_SEED },
        { "verify", 1, 0, O_VERIFY }, { "imm0", 1, 0, O_IMM0 }, { "send-base", 1, 0, O_SBASE },
        { "fill", 1, 0, O_FILL }, { "hugepages", 1, 0, O_HUGE }, { "interval", 1, 0, O_INTERVAL },
        { "silence", 1, 0, O_SILENCE }, { "start-timeout", 1, 0, O_STARTTO },
        { "link-grace", 1, 0, O_LGRACE }, { "link-down-max", 1, 0, O_LDOWNMAX },
        { "json", 0, 0, O_JSON }, { "save", 1, 0, O_SAVE }, { "diff", 1, 0, O_DIFF },
        { "all", 0, 0, O_ALL }, { "addr", 1, 0, O_ADDR }, { "fpga-ip", 1, 0, O_FPGAIP },
        { "help", 0, 0, O_HELP }, { "repost-delay-us", 1, 0, O_REPOST }, { "mem", 1, 0, O_MEM },
        { "gpu", 1, 0, O_GPU }, { "gpu-iova", 1, 0, O_GIOVA }, { "gpu-batch", 1, 0, O_GBATCH },
        { "gpu-wait-us", 1, 0, O_GWAIT }, { "gpu-scrub", 1, 0, O_GSCRUB }, { "mock", 0, 0, O_MOCK },
        { 0, 0, 0, 0 }
    };
    struct opts o;
    opts_default(&o);
    if (argc < 2 || !strcmp(argv[1], "-h") || !strcmp(argv[1], "--help") || !strcmp(argv[1], "help")) {
        usage();
        return argc < 2 ? EX_USAGE : EX_OK;
    }
    const char *cmd = argv[1];
    int len_set = 0, bufsz_set = 0;
    optind = 2;
    int c;
    uint64_t v;
    while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1) {
#define NUM(dst, max)                                                                   \
    do {                                                                                \
        if (parse_size(optarg, &v) || v > (uint64_t)(max)) {                           \
            logerr("bad value '%s' for --%s", optarg, lo[c - O_DEV].name);             \
            return EX_USAGE;                                                            \
        }                                                                               \
        (dst) = v;                                                                      \
    } while (0)
        switch (c) {
        case O_DEV: o.dev = optarg; o.dev_set = 1; break;
        case O_PORT: NUM(o.port, 255); break;
        case O_GID: NUM(o.gid_index, 255); break;
        case O_LOCALIP:
            if (parse_ip_opt(optarg, o.local_ip)) { logerr("bad --local-ip"); return EX_USAGE; }
            o.have_local_ip = 1;
            break;
        case O_FPGAIP:
            if (parse_ip_opt(optarg, o.fpga_ip)) { logerr("bad --fpga-ip"); return EX_USAGE; }
            o.have_fpga_ip = 1;
            break;
        case O_ROLE:
            if (!strcmp(optarg, "sink")) o.role = R_SINK;
            else if (!strcmp(optarg, "source")) o.role = R_SOURCE;
            else if (!strcmp(optarg, "reader")) o.role = R_READER;
            else if (!strcmp(optarg, "idle")) o.role = R_IDLE;
            else { logerr("--role sink|source|reader|idle"); return EX_USAGE; }
            break;
        case O_OP: {
            int k;
            for (k = 0; k < 5; k++)
                if (!strcmp(optarg, op_names[k]))
                    break;
            if (k == 5) { logerr("--op write|write_imm|send|send_imm|read"); return EX_USAGE; }
            o.op = (enum op)k;
            break;
        }
        case O_LEN: NUM(o.len, 0x7FFFFFFF); len_set = 1; break;
        case O_COUNT: NUM(o.count, UINT64_MAX); break;
        case O_DUR: o.duration = atof(optarg); break;
        case O_RATE:
            if (parse_rate(optarg, &o.rate_bps)) { logerr("bad --rate (e.g. 1G, 500M, max)"); return EX_USAGE; }
            break;
        case O_DEPTH: NUM(o.depth, 65536); if (!o.depth) o.depth = 1; break;
        case O_SIGNAL: NUM(o.signal, 65536); break;
        case O_BUFSZ:
            if (!strcmp(optarg, "max")) {
                o.buf_max = 1;
                o.buf_size = 0;
            } else {
                NUM(o.buf_size, 1ull << 40);
                o.buf_max = 0;
            }
            bufsz_set = 1;
            break;
        case O_NBUF: NUM(o.nbuf, 4); if (o.nbuf < 1) o.nbuf = 1; break;
        case O_WINDOW: NUM(o.window, UINT64_MAX); break;
        case O_RQ: NUM(o.rq_depth, 65536); if (!o.rq_depth) o.rq_depth = 1; break;
        case O_PMTU:
            NUM(o.pmtu, 4096);
            if (!mtu_to_ibv(o.pmtu)) { logerr("--pmtu 256|512|1024|2048|4096"); return EX_USAGE; }
            break;
        case O_PSN: NUM(o.psn, 0xFFFFFF); o.psn_set = 1; break;
        case O_QPTYPE:
            if (!strcmp(optarg, "rc")) o.qp_type = IBV_QPT_RC;
            else if (!strcmp(optarg, "uc")) o.qp_type = IBV_QPT_UC;
            else { logerr("--qp-type rc|uc"); return EX_USAGE; }
            break;
        case O_TCLASS: NUM(o.tclass, 255); break;
        case O_HOP: NUM(o.hop_limit, 255); break;
        case O_TIMEOUT: NUM(o.timeout, 31); break;
        case O_RETRY: NUM(o.retry, 7); break;
        case O_RNR: NUM(o.rnr_retry, 7); break;
        case O_MINRNR: NUM(o.min_rnr, 31); break;
        case O_MAXRD: NUM(o.max_rd, 255); break;
        case O_MAXDRD: NUM(o.max_dest_rd, 255); break;
        case O_MIG:
            if (!strcmp(optarg, "migrated")) o.migreq = IBV_MIG_MIGRATED;
            else if (!strcmp(optarg, "rearm")) o.migreq = IBV_MIG_REARM;
            else if (!strcmp(optarg, "armed")) o.migreq = IBV_MIG_ARMED;
            else { logerr("--migreq migrated|rearm|armed"); return EX_USAGE; }
            break;
        case O_PEER:
            if (o.npeer >= (int)(sizeof(o.peer) / sizeof(o.peer[0]))) { logerr("too many --peer"); return EX_USAGE; }
            o.peer[o.npeer++] = optarg;
            break;
        case O_CTL: o.ctl = optarg; break;
        case O_RECOUT: o.record_out = optarg; break;
        case O_NOWAIT: o.wait_go = 0; break;
        case O_FMR: NUM(o.fpga_mr, 255); break;
        case O_FOFF: NUM(o.fpga_off, UINT64_MAX); break;
        case O_SEED: NUM(o.seed, 0xFFFFFFFFu); o.seed_set = 1; break;
        case O_VERIFY:
            if (!strcmp(optarg, "full")) o.verify = 1;
            else if (!strcmp(optarg, "none")) o.verify = 0;
            else if (!strncmp(optarg, "sample:", 7) && !parse_u64(optarg + 7, &v) && v > 0) {
                o.verify = 2;
                o.sample = (uint32_t)v;
            } else { logerr("--verify full|none|sample:N"); return EX_USAGE; }
            break;
        case O_IMM0: NUM(o.imm0, 0xFFFFFFFFu); o.imm0_set = 1; break;
        case O_SBASE: NUM(o.send_base, UINT64_MAX); o.send_base_set = 1; break;
        case O_FILL: NUM(o.fill, 255); break;
        case O_HUGE:
            if (!strcmp(optarg, "off")) o.hugepages = 0;
            else if (!strcmp(optarg, "try")) o.hugepages = 1;
            else if (!strcmp(optarg, "on")) o.hugepages = 2;
            else { logerr("--hugepages off|try|on"); return EX_USAGE; }
            break;
        case O_INTERVAL: o.interval = atof(optarg); if (o.interval <= 0) o.interval = 1; break;
        case O_SILENCE: o.silence_s = atof(optarg); break;
        case O_STARTTO: o.start_timeout_s = atof(optarg); break;
        case O_LGRACE: g_link.grace_s = atof(optarg); break;
        case O_LDOWNMAX: g_link.max_down_s = atof(optarg); break;
        case O_JSON: o.json = 1; break;
        case O_SAVE: o.save = optarg; break;
        case O_DIFF: o.diff = optarg; break;
        case O_ALL: o.all = 1; break;
        case O_ADDR: NUM(o.pat_addr, UINT64_MAX); break;
        case O_HELP: usage(); return EX_OK;
        case O_REPOST: NUM(o.repost_delay_us, 10000000); break;
        case O_MEM:
            if (!strcmp(optarg, "host")) o.mem_gpu = 0;
            else if (!strcmp(optarg, "gpu")) o.mem_gpu = 1;
            else { logerr("--mem host|gpu"); return EX_USAGE; }
            break;
        case O_GPU: NUM(o.gpu, 63); break;
        case O_GIOVA:
            if (!strcmp(optarg, "0")) o.gpu_iova = RL_GRING_IOVA_ZERO;
            else if (!strcmp(optarg, "dev")) o.gpu_iova = RL_GRING_IOVA_DEV;
            else { logerr("--gpu-iova 0|dev"); return EX_USAGE; }
            o.gpu_iova_set = 1;
            break;
        case O_GBATCH: NUM(o.gpu_batch, 1024); if (!o.gpu_batch) o.gpu_batch = 1; break;
        case O_GWAIT: NUM(o.gpu_wait_us, 1000000); break;
        case O_GSCRUB:
            if (!strcmp(optarg, "auto")) o.gpu_scrub = -1;
            else if (!strcmp(optarg, "on")) o.gpu_scrub = 1;
            else if (!strcmp(optarg, "off")) o.gpu_scrub = 0;
            else { logerr("--gpu-scrub auto|on|off"); return EX_USAGE; }
            break;
        case O_MOCK: o.mock = 1; break;
        default: usage(); return EX_USAGE;
        }
#undef NUM
    }
    if (optind < argc) {
        logerr("unexpected argument '%s'", argv[optind]);
        return EX_USAGE;
    }
    if (!strcmp(cmd, "pattern")) {
        if (len_set)
            o.pat_len = o.len;
        return cmd_pattern(&o);
    }
    if (!strcmp(cmd, "selftest"))
        return cmd_selftest();
    if (!strcmp(cmd, "selftest-gpu")) {
        struct rl_gst_cfg gc = { o.mock, o.gpu, o.dev_set ? o.dev : NULL,
                                 (bufsz_set && !o.buf_max) ? o.buf_size : 0,
                                 o.gpu_iova_set ? o.gpu_iova : -1, o.seed_set ? o.seed : 0x5EED1234u };
        return rl_selftest_gpu(&gc);
    }
    int needs_dev = !strcmp(cmd, "info") || !strcmp(cmd, "counters") || !strcmp(cmd, "run");
    char devbuf[64];
    if (needs_dev && !o.dev_set) {
        if (vdev_first(devbuf, sizeof(devbuf)))
            return EX_SETUP;
        o.dev = devbuf;
    }
    if (!strcmp(cmd, "info"))
        return cmd_info(&o);
    if (!strcmp(cmd, "counters"))
        return cmd_counters(&o);
    if (!strcmp(cmd, "run"))
        return cmd_run(&o);
    logerr("unknown command '%s' (run, info, counters, pattern, selftest, selftest-gpu)", cmd);
    return EX_USAGE;
}
