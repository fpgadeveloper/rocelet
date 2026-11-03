/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gpu_selftest.c - `rocelet_host selftest-gpu`: the GPU ring path without NIC traffic.
 * Structure after the GPU self-test of an earlier Opsero host receiver (same copyright
 * holder, MIT).
 *
 *   1. device: name, PCI id, dma-buf / GPUDirect attributes, BAR1 total / free, ring cap
 *   2. verify kernel = CPU reference: a CPU-generated pattern with planted faults (one wrong
 *      byte, an unwritten message, a misplaced beat, an unwritten tail, garbage, a wrong
 *      address word, partial and unaligned regions) uploaded to GPU memory and checked
 *      through rl_gpuv with several batch sizes, for pattern base 0 (IOVA 0) and for a base
 *      like a device address; every result must equal rl_gpu_ref_job() and rl_pat_check()
 *   3. scrub: checked messages are overwritten with the fill byte; a second check finds fill
 *   4. scan kernel (plain WRITE target) = CPU reference
 *   5. a ring above the BAR1 cap is refused before anything is allocated
 *   6. (CUDA) the run-size ring: cudaMalloc + dma-buf export + ibv_reg_dmabuf_mr against the
 *      RDMA device (no QP, no traffic) at IOVA 0 and at the device address; BAR1 use
 *   7. throughput of the verify kernel over that ring (64 KiB messages, batches of 64) and of
 *      the scan kernel
 * With --mock everything except 6 runs on the mock back end (host memory).
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rl_common.h"
#include "rl_gpu.h"
#include "rl_gpuv.h"
#include "rl_gring.h"

#define ST_NB   16
#define ST_BMAX 64
#define SLOT    65536u
#define NSLOT   120u
#define TEST_SZ (8u << 20)
#define FILL    0x5A

static int fails;
#define EXPECT(cond, ...)                                                                \
    do {                                                                                 \
        if (!(cond)) {                                                                   \
            printf("    FAIL: ");                                                        \
            printf(__VA_ARGS__);                                                         \
            printf("\n");                                                                \
            fails++;                                                                     \
        }                                                                                \
    } while (0)

struct st {
    const struct rl_gpu_backend *be;
    struct rl_gpu_ctx *g;
    struct rl_gpu_info info;
    struct rl_gparams p;
};

/* the jobs of the equivalence test */
struct job {
    uint64_t off;
    uint32_t len;
};

struct collect {
    struct rl_gres *res;
    int *status;
    uint64_t n, next_seq, order_err;
};

static void collect_cb(void *ctx, const struct rl_gdesc *d, const struct rl_gres *r, int status)
{
    struct collect *c = ctx;
    if (d->seq != c->next_seq)
        c->order_err++;
    c->next_seq = d->seq + 1;
    if (d->seq < c->n) {
        c->status[d->seq] = status;
        if (r)
            c->res[d->seq] = *r;
    }
}

static uint64_t xs(uint64_t *s)
{
    *s ^= *s << 13;
    *s ^= *s >> 7;
    *s ^= *s << 17;
    return *s;
}

static void print_bar1(struct st *t, const char *when)
{
    struct rl_gpu_info i = t->info;
    if (t->be->bar1(t->g, &i) == 0 && i.bar1_total)
        printf("  BAR1 %s: %" PRIu64 " MiB used of %" PRIu64 " MiB (%" PRIu64 " MiB free)\n", when,
               (i.bar1_total - i.bar1_free) >> 20, i.bar1_total >> 20, i.bar1_free >> 20);
    else
        printf("  BAR1 %s: unknown (no NVML)\n", when);
}

/* Build the shadow (host copy) of the test region: pattern base P, planted faults. */
static unsigned build_shadow(uint8_t *h, uint64_t P, uint32_t seed, struct job *jobs)
{
    unsigned n = 0;
    uint64_t rs = 0x9E3779B97F4A7C15ull;
    memset(h, FILL, TEST_SZ);
    for (unsigned s = 0; s < NSLOT; s++) {
        jobs[n].off = (uint64_t)s * SLOT;
        jobs[n].len = SLOT;
        n++;
    }
    /* odd regions after the slots: partial last beat, unaligned start, 8- not 16-aligned */
    uint64_t tail = (uint64_t)NSLOT * SLOT;
    jobs[n].off = tail;              jobs[n].len = 4100; n++;
    jobs[n].off = tail + 8192 + 3;   jobs[n].len = 1000; n++;
    jobs[n].off = tail + 16384 + 8;  jobs[n].len = 4096; n++;
    jobs[n].off = tail + 32768;      jobs[n].len = 64;   n++;
    for (unsigned i = 0; i < n; i++)
        rl_pat_fill(h + jobs[i].off, P + jobs[i].off, jobs[i].len, seed);

    h[3 * SLOT + 1000] ^= 0x40;                                   /* one wrong byte */
    memset(h + 5 * SLOT, FILL, SLOT);                             /* never written */
    memcpy(h + 7 * SLOT + 2 * 64, h + 9 * SLOT + 4 * 64, 64);     /* misplaced beat */
    memset(h + 11 * SLOT + SLOT - 4096, FILL, 4096);              /* tail not written */
    for (unsigned j = 0; j < 100; j++)                            /* garbage */
        h[13 * SLOT + 30000 + j] = (uint8_t)xs(&rs);
    h[17 * SLOT + 0] ^= 0x01;                                     /* wrong address word */
    h[tail + 4099] ^= 0xFF;                                       /* partial beat */
    memset(h + tail + 8192 + 3 + 500, FILL, 64);                  /* unaligned, fill */
    h[tail + 16384 + 8 + 4095] ^= 0x10;                           /* 8-aligned region */
    return n;
}

static int same_res(const struct rl_gres *a, const struct rl_gres *b, uint32_t len)
{
    if (a->bad_bytes != b->bad_bytes || a->first != b->first || a->beats != b->beats ||
        a->fill_beats != b->fill_beats || a->misplaced_beats != b->misplaced_beats ||
        a->corrupt_beats != b->corrupt_beats || a->checked != b->checked)
        return 0;
    if (a->bad_bytes) {
        uint64_t beat = a->first & ~(uint64_t)63;
        size_t n = len - beat < 64 ? (size_t)(len - beat) : 64;
        if (memcmp(a->got, b->got, n))
            return 0;
    }
    return 1;
}

/* Check the jobs through rl_gpuv and compare with the CPU reference on the shadow. */
static void equiv(struct st *t, uint64_t dptr, const uint8_t *h, uint64_t P, const struct job *jobs,
                  unsigned nj, unsigned batch, unsigned nb, uint32_t extra_flags, int skip_some,
                  struct rl_gres *out)
{
    struct collect c;
    struct rl_gpuv_cfg cfg = { batch, nb, ST_BMAX, 200000, 4096 };
    struct rl_gres *res = calloc(nj, sizeof(*res));
    int *status = calloc(nj, sizeof(*status));
    unsigned mism = 0, skipped = 0;
    memset(&c, 0, sizeof(c));
    c.res = res;
    c.status = status;
    c.n = nj;
    struct rl_gpuv *v = rl_gpuv_create(t->be, t->g, dptr, &t->p, &cfg, collect_cb, &c);
    EXPECT(v != NULL, "rl_gpuv_create(batch %u, nb %u)", batch, nb);
    if (!v || !res || !status) {
        free(res);
        free(status);
        rl_gpuv_destroy(v);
        return;
    }
    for (unsigned i = 0; i < nj; i++) {
        struct rl_gdesc d = { jobs[i].off, P + jobs[i].off, i, jobs[i].len, RL_GD_VERIFY | extra_flags };
        if (skip_some && i % 10 == 9)
            d.flags = 0;
        rl_gpuv_submit(v, &d, rl_gpuv_now_ns());
        if (i % 5 == 4)
            rl_gpuv_poll(v, rl_gpuv_now_ns(), 0);
    }
    rl_gpuv_flush(v);
    EXPECT(!rl_gpuv_failed(v), "GPU verifier reported an error");
    EXPECT(c.order_err == 0 && c.next_seq == nj, "results out of order (%" PRIu64 " order errors, %"
           PRIu64 " of %u retired)", c.order_err, c.next_seq, nj);
    for (unsigned i = 0; i < nj; i++) {
        struct rl_gdesc d = { jobs[i].off, P + jobs[i].off, i, jobs[i].len, RL_GD_VERIFY };
        struct rl_gres ref;
        size_t first;
        if (skip_some && i % 10 == 9) {
            skipped++;
            EXPECT(status[i] == RL_GV_SKIPPED, "job %u: status %d, expected skipped", i, status[i]);
            continue;
        }
        EXPECT(status[i] == RL_GV_CHECKED, "job %u: status %d, expected checked", i, status[i]);
        rl_gpu_ref_job(h, &d, &t->p, &ref);
        size_t bad = rl_pat_check(h + jobs[i].off, P + jobs[i].off, jobs[i].len, t->p.seed, &first);
        if (!same_res(&res[i], &ref, jobs[i].len) || res[i].bad_bytes != bad ||
            (bad && res[i].first != first) || (!bad && res[i].first != jobs[i].len)) {
            if (mism++ < 5)
                printf("    job %u (off 0x%" PRIx64 " len %u): GPU bad %" PRIu64 " first %" PRIu64
                       " fill %u mis %u cor %u | ref bad %" PRIu64 " first %" PRIu64
                       " fill %u mis %u cor %u | rl_pat_check %zu first %zu\n",
                       i, jobs[i].off, jobs[i].len, res[i].bad_bytes, res[i].first,
                       res[i].fill_beats, res[i].misplaced_beats, res[i].corrupt_beats,
                       ref.bad_bytes, ref.first, ref.fill_beats, ref.misplaced_beats,
                       ref.corrupt_beats, bad, first);
        }
    }
    EXPECT(mism == 0, "%u of %u results differ from the CPU reference (batch %u, nb %u)", mism,
           nj - skipped, batch, nb);
    if (out)
        memcpy(out, res, nj * sizeof(*res));
    rl_gpuv_destroy(v);
    free(res);
    free(status);
}

static void test_equiv(struct st *t, uint64_t dptr, uint8_t *h, uint64_t P, const char *pname)
{
    static const unsigned cfgs[][2] = { { 1, 2 }, { 7, 3 }, { 64, 16 } };
    struct job jobs[NSLOT + 8];
    struct rl_gres res[NSLOT + 8];
    unsigned nj = build_shadow(h, P, t->p.seed, jobs);
    printf("  verify kernel = CPU reference, pattern base %s (0x%" PRIx64 "), %u regions, "
           "planted faults\n", pname, P, nj);
    if (t->be->upload(t->g, dptr, h, TEST_SZ)) {
        EXPECT(0, "upload");
        return;
    }
    for (unsigned k = 0; k < sizeof(cfgs) / sizeof(cfgs[0]); k++)
        equiv(t, dptr, h, P, jobs, nj, cfgs[k][0], cfgs[k][1], 0, k == 1, k == 2 ? res : NULL);
    /* the planted faults, as classified */
    EXPECT(res[0].bad_bytes == 0 && res[1].bad_bytes == 0 && res[119].bad_bytes == 0,
           "clean messages reported bad");
    EXPECT(res[3].bad_bytes == 1 && res[3].first == 1000 && res[3].corrupt_beats == 1,
           "one wrong byte: bad %" PRIu64 " first %" PRIu64 " corrupt %u", res[3].bad_bytes,
           res[3].first, res[3].corrupt_beats);
    EXPECT(res[5].fill_beats == SLOT / 64 && res[5].corrupt_beats == 0,
           "unwritten message: fill beats %u of %u", res[5].fill_beats, SLOT / 64);
    EXPECT(res[7].misplaced_beats == 1 && res[7].corrupt_beats == 0 && res[7].first == 128,
           "misplaced beat: misplaced %u corrupt %u first %" PRIu64, res[7].misplaced_beats,
           res[7].corrupt_beats, res[7].first);
    EXPECT(res[11].fill_beats == 64 && res[11].first >= SLOT - 4096,
           "unwritten tail: fill beats %u first %" PRIu64, res[11].fill_beats, res[11].first);
    EXPECT(res[13].corrupt_beats >= 2 && res[13].first >= 30000,
           "garbage: corrupt %u first %" PRIu64, res[13].corrupt_beats, res[13].first);
    EXPECT(res[17].bad_bytes == 1 && res[17].first == 0 && res[17].corrupt_beats == 1,
           "wrong address word: bad %" PRIu64 " corrupt %u", res[17].bad_bytes,
           res[17].corrupt_beats);
    EXPECT(res[NSLOT].bad_bytes == 1 && res[NSLOT].first == 4099, "partial beat: bad %" PRIu64
           " first %" PRIu64, res[NSLOT].bad_bytes, res[NSLOT].first);
    EXPECT(res[NSLOT + 1].bad_bytes > 0 && res[NSLOT + 1].first == 500, "unaligned region: first %"
           PRIu64, res[NSLOT + 1].first);
    EXPECT(res[NSLOT + 2].bad_bytes == 1 && res[NSLOT + 2].first == 4095, "8-aligned region");
    EXPECT(res[NSLOT + 3].bad_bytes == 0, "single beat");
}

static void test_scrub(struct st *t, uint64_t dptr, uint8_t *h, uint64_t P)
{
    struct job jobs[NSLOT + 8];
    struct rl_gres res[3];
    uint8_t *back = malloc(3 * SLOT);
    printf("  scrub: checked messages are refilled; a second check sees fill (stale detection)\n");
    build_shadow(h, P, t->p.seed, jobs);
    if (!back || t->be->upload(t->g, dptr, h, TEST_SZ)) {
        EXPECT(0, "upload");
        free(back);
        return;
    }
    equiv(t, dptr, h, P, jobs, 3, 2, 2, RL_GD_SCRUB, 0, res);
    EXPECT(res[0].bad_bytes == 0 && res[2].bad_bytes == 0, "scrubbed messages were not clean");
    t->be->download(t->g, back, dptr, 3 * SLOT);
    int allfill = 1;
    for (size_t j = 0; j < 3 * SLOT; j++)
        if (back[j] != FILL)
            allfill = 0;
    EXPECT(allfill, "messages not refilled after the check");
    memset(h, FILL, 3 * SLOT);    /* the shadow now matches the scrubbed ring */
    equiv(t, dptr, h, P, jobs, 3, 1, 2, 0, 0, res);
    EXPECT(res[1].fill_beats == SLOT / 64, "second check of a scrubbed message: fill beats %u",
           res[1].fill_beats);
    free(back);
}

static void test_scan(struct st *t, uint64_t dptr, uint8_t *h, uint64_t P)
{
    struct job jobs[NSLOT + 8];
    struct rl_gscan gs, rs;
    size_t len = (size_t)NSLOT * SLOT;
    build_shadow(h, P, t->p.seed, jobs);
    /* the scan model is address-based over the whole target: keep only the slots */
    if (t->be->upload(t->g, dptr, h, TEST_SZ) || t->be->scan(t->g, dptr, P, len, &t->p, &gs)) {
        EXPECT(0, "scan");
        return;
    }
    rl_gpu_ref_scan(h, P, len, &t->p, &rs);
    printf("  scan kernel = CPU reference (%zu MiB): ok %" PRIu64 " fill %" PRIu64 " bad %" PRIu64
           " (misplaced %" PRIu64 "), first bad beat %" PRIu64 "\n", len >> 20, gs.ok_beats,
           gs.fill_beats, gs.bad_beats, gs.misplaced_beats, gs.first_bad);
    EXPECT(gs.ok_beats == rs.ok_beats && gs.fill_beats == rs.fill_beats &&
           gs.bad_beats == rs.bad_beats && gs.misplaced_beats == rs.misplaced_beats &&
           gs.first_bad == rs.first_bad,
           "scan differs: ref ok %" PRIu64 " fill %" PRIu64 " bad %" PRIu64 " misplaced %" PRIu64
           " first %" PRIu64, rs.ok_beats, rs.fill_beats, rs.bad_beats, rs.misplaced_beats,
           rs.first_bad);
    EXPECT(gs.nbad_idx == (rs.bad_beats < RL_GSCAN_IDX ? rs.bad_beats : RL_GSCAN_IDX),
           "scan bad index list: %" PRIu64 " entries", gs.nbad_idx);
    for (uint64_t i = 0; i < gs.nbad_idx; i++) {
        uint8_t e[64];
        uint64_t k = gs.bad_idx[i];
        rl_pat_beat(P + 64 * k, t->p.seed, e);
        EXPECT(k < len / 64 && memcmp(h + 64 * k, e, 64) != 0, "scan bad index %" PRIu64
               " is not a bad beat", k);
    }
}

/* 6: run-size ring, dma-buf, ibv_reg_dmabuf_mr (CUDA only) */
static void test_reg(struct st *t, struct rl_gring *ring, const struct rl_gst_cfg *c)
{
#ifdef RL_CUDA
    struct ibv_device **l;
    struct ibv_context *ctx = NULL;
    struct ibv_pd *pd = NULL;
    int n = 0;
    const char *name = NULL;
    l = ibv_get_device_list(&n);
    for (int i = 0; l && i < n && !ctx; i++)
        if (!c->rdma_dev || !strcmp(ibv_get_device_name(l[i]), c->rdma_dev)) {
            name = ibv_get_device_name(l[i]);
            ctx = ibv_open_device(l[i]);
        }
    if (!ctx) {
        printf("  registration: SKIPPED - %s\n", c->rdma_dev ? "RDMA device not found" :
               "no RDMA device");
        if (c->rdma_dev)
            EXPECT(0, "RDMA device %s not found", c->rdma_dev);
        if (l)
            ibv_free_device_list(l);
        return;
    }
    pd = ibv_alloc_pd(ctx);
    EXPECT(pd != NULL, "ibv_alloc_pd on %s", name);
    for (int mode = 0; pd && mode < 2; mode++) {
        if (c->iova_mode >= 0 && c->iova_mode != mode)
            continue;
        if (rl_gring_reg(ring, pd, mode, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
                         IBV_ACCESS_REMOTE_READ)) {
            EXPECT(0, "ibv_reg_dmabuf_mr of %zu MiB at iova %s on %s", ring->alloc_size >> 20,
                   mode ? "dev" : "0", name);
            continue;
        }
        printf("  registration on %s: %zu MiB at iova 0x%" PRIx64 " (%s): rkey 0x%x lkey 0x%x, "
               "mr length %zu, %.1f ms\n", name, ring->alloc_size >> 20, ring->iova,
               mode ? "device address" : "IOVA 0, HSB convention", ring->mr->rkey,
               ring->mr->lkey, ring->mr->length, ring->reg_ms);
        print_bar1(t, "while registered");
        rl_gring_dereg(ring);
    }
    if (pd)
        ibv_dealloc_pd(pd);
    ibv_close_device(ctx);
    ibv_free_device_list(l);
#else
    (void)t; (void)ring; (void)c;
#endif
}

/* 7: throughput over the whole ring */
static void bench(struct st *t, uint64_t dptr, size_t size)
{
    uint8_t *h = malloc(size);
    unsigned nj = (unsigned)(size / SLOT);
    struct collect c;
    struct rl_gpuv_cfg cfg = { 64, ST_NB, ST_BMAX, 200000, 4096 };
    struct rl_gpuv_stats st;
    struct rl_gres *res = calloc(nj ? nj : 1, sizeof(*res));
    int *status = calloc(nj ? nj : 1, sizeof(*status));
    if (!h || !res || !status || !nj) {
        EXPECT(0, "benchmark buffers");
        goto out;
    }
    rl_pat_fill(h, 0, size, t->p.seed);
    if (t->be->upload(t->g, dptr, h, size)) {
        EXPECT(0, "benchmark upload");
        goto out;
    }
    for (int pass = 0; pass < 2; pass++) {
        memset(&c, 0, sizeof(c));
        c.res = res;
        c.status = status;
        c.n = nj;
        struct rl_gpuv *v = rl_gpuv_create(t->be, t->g, dptr, &t->p, &cfg, collect_cb, &c);
        if (!v) {
            EXPECT(0, "rl_gpuv_create");
            goto out;
        }
        double t0 = now_s();
        for (unsigned i = 0; i < nj; i++) {
            struct rl_gdesc d = { (uint64_t)i * SLOT, (uint64_t)i * SLOT, i, SLOT, RL_GD_VERIFY };
            rl_gpuv_submit(v, &d, rl_gpuv_now_ns());
        }
        rl_gpuv_flush(v);
        double dt = now_s() - t0;
        rl_gpuv_stats(v, &st);
        uint64_t bad = 0;
        for (unsigned i = 0; i < nj; i++)
            bad += res[i].bad_bytes;
        EXPECT(bad == 0 && !rl_gpuv_failed(v), "benchmark ring reported %" PRIu64 " bad bytes", bad);
        if (pass == 1)
            printf("  verify throughput: %u x 64 KiB in %.2f ms = %.1f GB/s through rl_gpuv "
                   "(kernel %.1f GB/s, %" PRIu64 " launches, avg batch %.1f, back-pressure waits %"
                   PRIu64 ")\n", nj, dt * 1e3, (double)size / dt / 1e9,
                   st.gpu_ms > 0 ? (double)size / (st.gpu_ms / 1e3) / 1e9 : 0, st.launches,
                   st.avg_batch, st.full_waits);
        rl_gpuv_destroy(v);
    }
    {
        struct rl_gscan gs;
        double t0 = now_s();
        int rc = t->be->scan(t->g, dptr, 0, size, &t->p, &gs);
        double dt = now_s() - t0;
        EXPECT(rc == 0 && gs.ok_beats == size / 64 && gs.bad_beats == 0, "benchmark scan");
        printf("  scan throughput: %zu MiB in %.2f ms = %.1f GB/s\n", size >> 20, dt * 1e3,
               (double)size / dt / 1e9);
    }
out:
    free(h);
    free(res);
    free(status);
}

int rl_selftest_gpu(const struct rl_gst_cfg *c)
{
    struct st t;
    uint64_t tdptr = 0;
    size_t tas = 0;
    uint8_t *h = NULL;
    struct rl_gring ring;
    memset(&t, 0, sizeof(t));
    memset(&ring, 0, sizeof(ring));
    ring.fd = -1;
    fails = 0;
    t.be = c->mock ? rl_gpu_backend_mock() : rl_gpu_backend_cuda();
    if (!t.be) {
        logerr("selftest-gpu: rocelet_host was built without CUDA. Rebuild with `make CUDA=1` "
               "(CUDA toolkit, rdma-core >= 34), or run `selftest-gpu --mock` to test the GPU "
               "ring logic on the mock back end");
        return EX_SETUP;
    }
    t.p.seed = c->seed;
    t.p.fill = FILL;
    if (t.be->open(&t.g, c->gpu, ST_NB, ST_BMAX, &t.info))
        return EX_SETUP;
    uint64_t cap = rl_gpu_ring_cap(&t.info);
    uint64_t rsize = c->ring_size ? c->ring_size : (c->mock ? (32ull << 20) : cap);
    printf("selftest-gpu (%s back end)\n", t.be->name);
    printf("  device: %s, PCI %s, compute %d.%d; dma-buf %d, GPUDirect RDMA %d, RDMA write "
           "ordering %d, flush options 0x%x%s\n", t.info.name, t.info.pci, t.info.cc_major,
           t.info.cc_minor, t.info.dmabuf, t.info.gdr, t.info.rdma_ordering,
           t.info.flush_options, t.info.flush_each ? " (flush before each launch)" : "");
    printf("  BAR1 %" PRIu64 " MiB (%" PRIu64 " MiB free): GPU ring cap %" PRIu64 " MiB; "
           "test ring %" PRIu64 " MiB\n", t.info.bar1_total >> 20, t.info.bar1_free >> 20,
           cap >> 20, rsize >> 20);
    if (!c->mock) {
        EXPECT(t.info.dmabuf == 1, "the device has no dma-buf support (NVIDIA open kernel "
               "module needed)");
    }
    print_bar1(&t, "at start");

    h = malloc(TEST_SZ);
    if (!h || t.be->ring_alloc(t.g, TEST_SZ, FILL, &tdptr, &tas)) {
        EXPECT(0, "cannot allocate the %u MiB test region", TEST_SZ >> 20);
        goto out;
    }
    test_equiv(&t, tdptr, h, 0, "0 = IOVA 0");
    test_equiv(&t, tdptr, h, 0x7f3e40000000ull, "a device-like address");
    test_scrub(&t, tdptr, h, 0);
    test_scan(&t, tdptr, h, 0);
    test_scan(&t, tdptr, h, 0x7f3e40000000ull);
    t.be->ring_free(t.g, tdptr);
    tdptr = 0;

    printf("  BAR1 cap: a ring of cap + 2 MiB must be refused before any allocation:\n");
    EXPECT(rl_gring_alloc(&ring, t.be, t.g, &t.info, cap + (2u << 20), FILL, 0) != 0,
           "a %" PRIu64 " MiB ring above the cap was accepted", (cap >> 20) + 2);
    rl_gring_free(&ring);

    if (rl_gring_alloc(&ring, t.be, t.g, &t.info, rsize, FILL, !c->mock)) {
        EXPECT(0, "cannot allocate%s the %" PRIu64 " MiB ring", c->mock ? "" : " / export",
               rsize >> 20);
        goto out;
    }
    if (!c->mock) {
        printf("  ring: %zu MiB at device address 0x%" PRIx64 ", dma-buf fd %d\n",
               ring.alloc_size >> 20, ring.dptr, ring.fd);
        print_bar1(&t, "after cudaMalloc + export");
        test_reg(&t, &ring, c);
    } else {
        printf("  registration: not run on the mock back end\n");
    }
    bench(&t, ring.dptr, ring.alloc_size);
    rl_gring_free(&ring);
    print_bar1(&t, "at end");
out:
    if (tdptr)
        t.be->ring_free(t.g, tdptr);
    rl_gring_free(&ring);
    free(h);
    t.be->close(t.g);
    printf("selftest-gpu: %s (%d failure%s)\n", fails ? "FAIL" : "PASS", fails, fails == 1 ? "" : "s");
    return fails ? EX_ERRORS : EX_OK;
}
