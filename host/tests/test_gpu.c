/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * tests/test_gpu.c - Unit tests of the GPU ring logic without a GPU (`make test`): the
 * batching / in-order retire of rl_gpuv on the mock back end (partial batches, the wait
 * timer, back pressure, a full job queue, skipped jobs, launch failures), the CPU reference
 * of the verify job against rl_pat_check() (random faults), the scan reference against a
 * plain model of rocelet_host's scan_write_target(), the scrub, the BAR1 cap and the refusal
 * of an oversized ring, and the registration stub of a build without CUDA.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rl_common.h"
#include "rl_gpu.h"
#include "rl_gpuv.h"
#include "rl_gring.h"

static int fails, checks;
#define CHECK(cond, ...)                                                                 \
    do {                                                                                 \
        checks++;                                                                        \
        if (!(cond)) {                                                                   \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);                                  \
            printf(__VA_ARGS__);                                                         \
            printf("\n");                                                                \
            fails++;                                                                     \
        }                                                                                \
    } while (0)

#define FILL 0x5A
#define SEED 0x5EED1234u

static uint64_t rs = 0x123456789ABCDEFull;
static uint64_t rnd(void)
{
    rs ^= rs << 13;
    rs ^= rs >> 7;
    rs ^= rs << 17;
    return rs;
}

struct rec {
    uint64_t n, next, order_err, checked, skipped, unchecked, bad;
};

static void rec_cb(void *ctx, const struct rl_gdesc *d, const struct rl_gres *r, int status)
{
    struct rec *c = ctx;
    if (d->seq != c->next)
        c->order_err++;
    c->next = d->seq + 1;
    c->n++;
    if (status == RL_GV_CHECKED) {
        c->checked++;
        c->bad += r->bad_bytes;
    } else if (status == RL_GV_SKIPPED) {
        c->skipped++;
    } else {
        c->unchecked++;
    }
}

struct env {
    const struct rl_gpu_backend *be;
    struct rl_gpu_ctx *g;
    struct rl_gpu_info info;
    uint64_t dptr;
    size_t as;
    struct rl_gparams p;
};

static void env_open(struct env *e, unsigned nb, unsigned bmax, size_t ring)
{
    memset(e, 0, sizeof(*e));
    e->be = rl_gpu_backend_mock();
    e->p.seed = SEED;
    e->p.fill = FILL;
    if (e->be->open(&e->g, 0, nb, bmax, &e->info) || e->be->ring_alloc(e->g, ring, FILL, &e->dptr, &e->as)) {
        printf("FATAL: mock back end\n");
        exit(1);
    }
    rl_pat_fill((uint8_t *)(uintptr_t)e->dptr, 0, e->as, SEED);   /* pattern base 0 = IOVA 0 */
}

static void env_close(struct env *e)
{
    e->be->ring_free(e->g, e->dptr);
    e->be->close(e->g);
}

static struct rl_gdesc job(uint64_t i, uint32_t len, uint32_t flags)
{
    struct rl_gdesc d = { i * len, i * len, i, len, flags };
    return d;
}

/* 1. order, partial batches by the wait timer, force, stats */
static void t_order_and_timer(void)
{
    struct env e;
    struct rec c = { 0 };
    env_open(&e, 4, 8, 4u << 20);
    rl_gpu_mock_set_delay(e.g, 3);
    struct rl_gpuv_cfg cfg = { 8, 4, 8, 1000, 64 };
    struct rl_gpuv *v = rl_gpuv_create(e.be, e.g, e.dptr, &e.p, &cfg, rec_cb, &c);
    CHECK(v != NULL, "create");
    uint64_t t0 = 1000000;
    for (int i = 0; i < 3; i++) {
        struct rl_gdesc d = job((uint64_t)i, 4096, RL_GD_VERIFY);
        rl_gpuv_submit(v, &d, t0);
    }
    rl_gpuv_poll(v, t0 + 999, 0);
    CHECK(rl_gpu_mock_launches(e.g) == 0, "partial batch launched before the wait time");
    rl_gpuv_poll(v, t0 + 1000, 0);
    CHECK(rl_gpu_mock_launches(e.g) == 1, "partial batch not launched at the wait time");
    CHECK(c.n == 0, "retired before the results were there");
    for (int k = 0; k < 3; k++)
        rl_gpuv_poll(v, t0 + 2000, 0);
    CHECK(c.n == 3 && c.checked == 3 && c.bad == 0, "3 jobs retired clean (n %" PRIu64 ")", c.n);
    /* a full batch launches at once */
    for (int i = 3; i < 11; i++) {
        struct rl_gdesc d = job((uint64_t)i, 4096, RL_GD_VERIFY);
        rl_gpuv_submit(v, &d, t0 + 3000);
    }
    CHECK(rl_gpu_mock_launches(e.g) == 2, "full batch not launched (%lu)", rl_gpu_mock_launches(e.g));
    /* force launches the partial rest */
    struct rl_gdesc d = job(11, 4096, RL_GD_VERIFY);
    rl_gpuv_submit(v, &d, t0 + 3000);
    rl_gpuv_poll(v, t0 + 3001, 1);
    CHECK(rl_gpu_mock_launches(e.g) == 3, "force did not launch");
    rl_gpuv_flush(v);
    CHECK(c.n == 12 && c.order_err == 0 && rl_gpuv_pending(v) == 0, "flush: n %" PRIu64 " order %" PRIu64,
          c.n, c.order_err);
    struct rl_gpuv_stats st;
    rl_gpuv_stats(v, &st);
    CHECK(st.launches == 3 && st.gpu_jobs == 12 && st.max_batch == 8, "stats launches %" PRIu64
          " jobs %" PRIu64 " max %u", st.launches, st.gpu_jobs, st.max_batch);
    rl_gpuv_destroy(v);
    env_close(&e);
}

/* 2. back pressure (every batch in flight), a full job queue, skipped jobs in between */
static void t_backpressure(void)
{
    struct env e;
    struct rec c = { 0 };
    env_open(&e, 2, 1, 8u << 20);
    rl_gpu_mock_set_delay(e.g, 5);
    struct rl_gpuv_cfg cfg = { 1, 2, 1, 1000000, 1 };
    struct rl_gpuv *v = rl_gpuv_create(e.be, e.g, e.dptr, &e.p, &cfg, rec_cb, &c);
    const unsigned N = 1000;
    for (unsigned i = 0; i < N; i++) {
        struct rl_gdesc d = job(i % 128, 65536, (i % 7 == 3) ? 0 : RL_GD_VERIFY);
        d.seq = i;
        rl_gpuv_submit(v, &d, 0);
    }
    rl_gpuv_flush(v);
    struct rl_gpuv_stats st;
    rl_gpuv_stats(v, &st);
    CHECK(c.n == N && c.order_err == 0, "retired %" PRIu64 " of %u, order errors %" PRIu64, c.n, N,
          c.order_err);
    CHECK(c.skipped == (N + 3) / 7, "skipped %" PRIu64, c.skipped);
    CHECK(c.checked == N - c.skipped && c.bad == 0, "checked %" PRIu64, c.checked);
    CHECK(st.full_waits > 0, "no back-pressure wait with 2 batches of 1 and a slow GPU");
    rl_gpuv_destroy(v);
    env_close(&e);
}

/* 3. launch failure: no verdict, failed flag, the run can still flush */
static void t_failure(void)
{
    struct env e;
    struct rec c = { 0 };
    env_open(&e, 4, 4, 4u << 20);
    struct rl_gpuv_cfg cfg = { 4, 4, 4, 1000, 64 };
    struct rl_gpuv *v = rl_gpuv_create(e.be, e.g, e.dptr, &e.p, &cfg, rec_cb, &c);
    for (unsigned i = 0; i < 8; i++) {
        struct rl_gdesc d = job(i, 4096, RL_GD_VERIFY);
        rl_gpuv_submit(v, &d, 0);
    }
    rl_gpu_mock_set_fail(e.g, 1);
    for (unsigned i = 8; i < 14; i++) {
        struct rl_gdesc d = job(i, 4096, RL_GD_VERIFY);
        rl_gpuv_submit(v, &d, 0);
    }
    rl_gpuv_flush(v);
    struct rl_gpuv_stats st;
    rl_gpuv_stats(v, &st);
    CHECK(rl_gpuv_failed(v), "failure not reported");
    CHECK(c.n == 14 && c.order_err == 0, "retired %" PRIu64, c.n);
    CHECK(c.checked == 8 && c.unchecked == 6 && st.unchecked == 6, "checked %" PRIu64
          " unchecked %" PRIu64, c.checked, c.unchecked);
    rl_gpuv_destroy(v);
    env_close(&e);
}

/* 4. reference job = rl_pat_check on random faults, lengths and offsets */
static void t_ref_vs_patcheck(void)
{
    const size_t SZ = 1u << 20;
    uint8_t *b = malloc(SZ);
    struct rl_gparams p = { SEED, FILL };
    unsigned mism = 0, n_fill = 0, n_mis = 0, n_cor = 0;
    for (int it = 0; it < 400; it++) {
        uint64_t off = rnd() % 4096;
        uint32_t len = (uint32_t)(1 + rnd() % 65536);
        uint64_t pat = (rnd() & 1) ? 0 : (rnd() & 0x0000FFFFFFFFFFC0ull);
        memset(b, FILL, SZ);
        rl_pat_fill(b + off, pat, len, SEED);
        switch (it % 5) {
        case 0: break;
        case 1: b[off + rnd() % len] ^= (uint8_t)(1 + rnd() % 255); break;
        case 2: memset(b + off + (len / 2), FILL, len - len / 2); break;
        case 3:
            if (len >= 256) {   /* a misplaced beat: beat 1 <- the pattern of another address */
                rl_pat_beat(pat + 64 * 1000, SEED, b + off + 64);
            }
            break;
        case 4:
            for (int k = 0; k < 20; k++)
                b[off + rnd() % len] = (uint8_t)rnd();
            break;
        }
        struct rl_gdesc d = { off, pat, (uint64_t)it, len, RL_GD_VERIFY };
        struct rl_gres r;
        size_t first;
        rl_gpu_ref_job(b, &d, &p, &r);
        size_t bad = rl_pat_check(b + off, pat, len, SEED, &first);
        if (r.bad_bytes != bad || r.first != first || r.beats != (len + 63) / 64 ||
            r.fill_beats + r.misplaced_beats + r.corrupt_beats > r.beats)
            mism++;
        if (bad && memcmp(r.got, b + off + (first & ~(size_t)63),
                          len - (first & ~(size_t)63) < 64 ? len - (first & ~(size_t)63) : 64))
            mism++;
        n_fill += r.fill_beats;
        n_mis += r.misplaced_beats;
        n_cor += r.corrupt_beats;
    }
    CHECK(mism == 0, "%u reference results differ from rl_pat_check", mism);
    CHECK(n_fill > 0 && n_mis > 0 && n_cor > 0, "classes seen: fill %u misplaced %u corrupt %u",
          n_fill, n_mis, n_cor);
    /* no-verify job: nothing checked */
    struct rl_gdesc d = { 0, 0, 0, 4096, 0 };
    struct rl_gres r;
    rl_gpu_ref_job(b, &d, &p, &r);
    CHECK(!r.checked && r.bad_bytes == 0 && r.first == 4096, "unverified job");
    free(b);
}

/* 5. scan reference = a plain model of scan_write_target() */
static void t_scan(void)
{
    const size_t SZ = 2u << 20;
    uint8_t *b = malloc(SZ);
    struct rl_gparams p = { SEED, FILL };
    uint64_t va = 0x10000;
    memset(b, FILL, SZ);
    rl_pat_fill(b, va, SZ / 2, SEED);                /* first half written */
    b[100] ^= 1;                                     /* beat 1 bad */
    rl_pat_beat(va + 64 * 9999, SEED, b + 64 * 5);   /* beat 5 misplaced */
    b[SZ - 1] = 0;                                   /* last beat: not fill, not pattern */
    struct rl_gscan s;
    rl_gpu_ref_scan(b, va, SZ, &p, &s);
    uint64_t ok = 0, fill = 0, bad = 0;
    for (size_t off = 0; off + 64 <= SZ; off += 64) {
        uint8_t e[64], f[64];
        rl_pat_beat(va + off, SEED, e);
        memset(f, FILL, 64);
        if (!memcmp(b + off, e, 64)) ok++;
        else if (!memcmp(b + off, f, 64)) fill++;
        else bad++;
    }
    CHECK(s.ok_beats == ok && s.fill_beats == fill && s.bad_beats == bad && bad == 3,
          "scan ok %" PRIu64 "/%" PRIu64 " fill %" PRIu64 "/%" PRIu64 " bad %" PRIu64 "/%" PRIu64,
          s.ok_beats, ok, s.fill_beats, fill, s.bad_beats, bad);
    CHECK(s.misplaced_beats == 1 && s.first_bad == 1 && s.nbad_idx == 3 &&
          s.bad_idx[2] == SZ / 64 - 1, "scan details");
    /* a partial last beat is not looked at */
    rl_gpu_ref_scan(b, va, 64 * 3 + 10, &p, &s);
    CHECK(s.ok_beats + s.fill_beats + s.bad_beats == 3, "partial beat counted");
    free(b);
}

/* 6. scrub through rl_gpuv on the mock */
static void t_scrub(void)
{
    struct env e;
    struct rec c = { 0 };
    env_open(&e, 2, 4, 2u << 20);
    struct rl_gpuv_cfg cfg = { 4, 2, 4, 1000, 64 };
    struct rl_gpuv *v = rl_gpuv_create(e.be, e.g, e.dptr, &e.p, &cfg, rec_cb, &c);
    for (unsigned i = 0; i < 4; i++) {
        struct rl_gdesc d = job(i, 8192, RL_GD_VERIFY | RL_GD_SCRUB);
        rl_gpuv_submit(v, &d, 0);
    }
    rl_gpuv_flush(v);
    CHECK(c.checked == 4 && c.bad == 0, "scrubbed jobs not clean before the scrub");
    const uint8_t *ring = (const uint8_t *)(uintptr_t)e.dptr;
    int allfill = 1;
    for (size_t j = 0; j < 4 * 8192; j++)
        allfill &= ring[j] == FILL;
    CHECK(allfill, "not refilled");
    CHECK(ring[4 * 8192] != FILL || ring[4 * 8192 + 8] != FILL, "scrub went past the regions");
    /* checking again: every beat is fill, every byte that differs from the pattern is bad */
    struct rec c2 = { 0 };
    struct rl_gpuv *v2 = rl_gpuv_create(e.be, e.g, e.dptr, &e.p, &cfg, rec_cb, &c2);
    struct rl_gdesc d = job(1, 8192, RL_GD_VERIFY);
    d.seq = 0;
    rl_gpuv_submit(v2, &d, 0);
    rl_gpuv_flush(v2);
    size_t first;
    CHECK(c2.bad == rl_pat_check(ring + 8192, 8192, 8192, SEED, &first) && c2.bad > 8000,
          "stale check: bad %" PRIu64, c2.bad);
    rl_gpuv_destroy(v);
    rl_gpuv_destroy(v2);
    env_close(&e);
}

/* 7. BAR1 cap, refusal before allocation, registration without CUDA */
static void t_cap(void)
{
    struct rl_gpu_info i;
    memset(&i, 0, sizeof(i));
    CHECK(rl_gpu_ring_cap(&i) == (240ull << 20), "unknown BAR1 -> 240 MiB");
    i.bar1_total = 256ull << 20;
    CHECK(rl_gpu_ring_cap(&i) == (240ull << 20), "256 MiB BAR1 -> 240 MiB");
    i.bar1_total = 16ull << 20;
    CHECK(rl_gpu_ring_cap(&i) == 0, "16 MiB BAR1 -> 0");
    CHECK(rl_gpu_ring_cap(NULL) == (240ull << 20), "NULL -> default");

    struct env e;
    env_open(&e, 2, 1, 2u << 20);
    struct rl_gring r;
    struct rl_gpu_info small = e.info;
    small.bar1_total = 32ull << 20;       /* cap 16 MiB */
    small.bar1_free = 31ull << 20;
    printf("(expected error message follows)\n");
    CHECK(rl_gring_alloc(&r, e.be, e.g, &small, (16u << 20) + 1, FILL, 0) != 0 && r.dptr == 0,
          "a ring 1 byte above the cap (rounded up to 18 MiB) was accepted");
    CHECK(rl_gring_alloc(&r, e.be, e.g, &small, 16u << 20, FILL, 0) == 0 && r.dptr != 0 &&
          r.alloc_size == (16u << 20), "a ring at the cap was refused");
    const uint8_t *m = (const uint8_t *)(uintptr_t)r.dptr;
    CHECK(m[0] == FILL && m[(16u << 20) - 1] == FILL, "ring not filled");
#ifndef RL_CUDA
    printf("(expected error message follows)\n");
    CHECK(rl_gring_reg(&r, NULL, RL_GRING_IOVA_ZERO, 0) != 0, "registration without CUDA succeeded");
#endif
    rl_gring_free(&r);
    CHECK(r.dptr == 0 && r.fd == -1, "free");
    printf("(expected error message follows)\n");
    CHECK(rl_gring_alloc(&r, e.be, e.g, &small, 4u << 20, FILL, 1) != 0,
          "mock export should fail (no dma-buf)");
    CHECK(rl_gpu_backend_cuda() == NULL, "the test links the no-CUDA stub");
    env_close(&e);
}

int main(void)
{
    t_order_and_timer();
    t_backpressure();
    t_failure();
    t_ref_vs_patcheck();
    t_scan();
    t_scrub();
    t_cap();
    printf("test_gpu: %s (%d checks, %d failed)\n", fails ? "FAIL" : "PASS", checks, fails);
    return fails ? 1 : 0;
}
