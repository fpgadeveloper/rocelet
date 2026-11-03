/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gpuv.c - Batched, in-order verification of a GPU ring (rl_gpuv.h). Adapted from an
 * earlier Opsero host receiver (same copyright holder, MIT).
 *
 * Two in-order structures, both owned by the receive loop:
 *   jobs:    a power-of-two array indexed by job number (head = next to submit, tail = next
 *            to retire), one per submitted region;
 *   batches: nb descriptor/result sets used round robin by batch number (open = the batch
 *            being filled). A batch is FREE, OPEN (filling), INFLIGHT (launched) or DONE
 *            (results there, jobs being retired); it is FREE again once its last job retired.
 * A job without GPU work (no RL_GD_VERIFY) retires as soon as it reaches the tail; a GPU job
 * when its batch is DONE.
 */
#include "rl_gpuv.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rl_common.h"

enum { B_FREE, B_OPEN, B_INFLIGHT, B_DONE };

struct gjob {
    struct rl_gdesc d;
    int32_t  batch;   /* batch slot, -1 = no GPU work */
    uint32_t idx;     /* index in the batch */
};

struct gbatch {
    int      state;
    int      bad;      /* the launch or the kernel failed: no results */
    unsigned n;        /* jobs in the batch */
    unsigned retired;  /* of which retired */
    uint64_t first_ns;
};

struct rl_gpuv {
    const struct rl_gpu_backend *be;
    struct rl_gpu_ctx *g;
    uint64_t dptr;
    struct rl_gparams p;
    struct rl_gpuv_cfg cfg;
    rl_gpuv_cb cb;
    void *cb_ctx;
    struct gjob *q;
    uint64_t mask, head, tail;
    struct gbatch *b;
    uint64_t open;     /* batch number being filled (slot open % nb) */
    int failed;
    uint64_t t0;
    struct rl_gpuv_stats st;
};

uint64_t rl_gpuv_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static inline void cpu_relax(void)
{
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    __asm__ __volatile__("yield");
#endif
}

struct rl_gpuv *rl_gpuv_create(const struct rl_gpu_backend *be, struct rl_gpu_ctx *g,
                               uint64_t dptr, const struct rl_gparams *p,
                               const struct rl_gpuv_cfg *cfg, rl_gpuv_cb cb, void *ctx)
{
    struct rl_gpuv *v;
    uint64_t qn = 64;

    if (cfg->nb < 2 || cfg->bmax < 1 || cfg->batch < 1 || cfg->batch > cfg->bmax) {
        logerr("GPU verifier: bad batch configuration (batch %u, bmax %u, batches %u)",
               cfg->batch, cfg->bmax, cfg->nb);
        return NULL;
    }
    while (qn < cfg->depth || qn < (uint64_t)cfg->nb * cfg->bmax)
        qn <<= 1;
    v = calloc(1, sizeof(*v));
    if (!v)
        return NULL;
    v->q = calloc(qn, sizeof(*v->q));
    v->b = calloc(cfg->nb, sizeof(*v->b));
    if (!v->q || !v->b) {
        logerr("GPU verifier: cannot allocate %llu jobs", (unsigned long long)qn);
        free(v->q);
        free(v->b);
        free(v);
        return NULL;
    }
    v->be = be;
    v->g = g;
    v->dptr = dptr;
    v->p = *p;
    v->cfg = *cfg;
    v->cb = cb;
    v->cb_ctx = ctx;
    v->mask = qn - 1;
    v->t0 = rl_gpuv_now_ns();
    return v;
}

static int launch_open(struct rl_gpuv *v)
{
    unsigned bi = (unsigned)(v->open % v->cfg.nb);
    struct gbatch *b = &v->b[bi];
    if (b->state != B_OPEN || b->n == 0)
        return 0;
    if (v->be->launch(v->g, bi, b->n, v->dptr, &v->p)) {
        v->failed = 1;   /* the run ends; these jobs stay unchecked */
        b->bad = 1;
        b->state = B_DONE;
        v->open++;
        return -1;
    }
    b->state = B_INFLIGHT;
    v->st.launches++;
    v->st.gpu_jobs += b->n;
    if (b->n > v->st.max_batch)
        v->st.max_batch = b->n;
    v->open++;
    return 1;
}

static unsigned retire(struct rl_gpuv *v)
{
    unsigned n = 0;
    while (v->tail != v->head) {
        struct gjob *job = &v->q[v->tail & v->mask];
        if (job->batch >= 0) {
            struct gbatch *b = &v->b[job->batch];
            if (b->state == B_OPEN)
                break;
            if (b->state == B_INFLIGHT) {
                int r = v->be->query(v->g, (unsigned)job->batch);
                if (r == 0)
                    break;
                if (r < 0) {
                    v->failed = 1;
                    b->bad = 1;
                } else {
                    double ms = v->be->elapsed_ms(v->g, (unsigned)job->batch);
                    if (ms > 0)
                        v->st.gpu_ms += ms;
                }
                b->state = B_DONE;
            }
            if (b->bad) {
                v->st.unchecked++;
                if (v->cb)
                    v->cb(v->cb_ctx, &job->d, NULL, RL_GV_UNCHECKED);
            } else if (v->cb) {
                v->cb(v->cb_ctx, &job->d, &v->be->results(v->g, (unsigned)job->batch)[job->idx],
                      RL_GV_CHECKED);
            }
            if (++b->retired == b->n) {
                b->state = B_FREE;
                b->bad = 0;
                b->n = 0;
                b->retired = 0;
            }
        } else if (v->cb) {
            v->cb(v->cb_ctx, &job->d, NULL, RL_GV_SKIPPED);
        }
        v->tail++;
        n++;
    }
    return n;
}

void rl_gpuv_submit(struct rl_gpuv *v, const struct rl_gdesc *d, uint64_t now_ns)
{
    struct gjob *job;
    while (v->head - v->tail > v->mask) {    /* job queue full */
        launch_open(v);
        if (!retire(v))
            cpu_relax();
    }
    job = &v->q[v->head & v->mask];
    job->d = *d;
    job->batch = -1;
    if (d->flags & RL_GD_VERIFY) {
        unsigned bi = (unsigned)(v->open % v->cfg.nb);
        struct gbatch *b = &v->b[bi];
        if (b->state == B_INFLIGHT || b->state == B_DONE) {
            /* every batch is in flight: wait for the oldest (back pressure) */
            v->st.full_waits++;
            while (b->state != B_FREE) {
                if (!retire(v))
                    cpu_relax();
            }
        }
        if (b->state == B_FREE) {
            b->state = B_OPEN;
            b->n = 0;
            b->retired = 0;
            b->first_ns = now_ns;
        }
        v->be->descs(v->g, bi)[b->n] = *d;
        job->batch = (int32_t)bi;
        job->idx = b->n;
        b->n++;
        v->head++;
        if (b->n >= v->cfg.batch)
            launch_open(v);
        return;
    }
    v->head++;
}

unsigned rl_gpuv_poll(struct rl_gpuv *v, uint64_t now_ns, int force)
{
    struct gbatch *b = &v->b[v->open % v->cfg.nb];
    if (b->state == B_OPEN && b->n && (force || now_ns - b->first_ns >= v->cfg.wait_ns))
        launch_open(v);
    return retire(v);
}

void rl_gpuv_flush(struct rl_gpuv *v)
{
    launch_open(v);
    while (v->tail != v->head) {
        launch_open(v);
        if (!retire(v))
            cpu_relax();
    }
}

uint64_t rl_gpuv_pending(const struct rl_gpuv *v)
{
    return v->head - v->tail;
}

int rl_gpuv_failed(const struct rl_gpuv *v)
{
    return v->failed;
}

void rl_gpuv_stats(const struct rl_gpuv *v, struct rl_gpuv_stats *st)
{
    double wall = (double)(rl_gpuv_now_ns() - v->t0) / 1e6;
    *st = v->st;
    st->avg_batch = st->launches ? (double)st->gpu_jobs / (double)st->launches : 0.0;
    st->gpu_busy = wall > 0 ? st->gpu_ms / wall : 0.0;
}

void rl_gpuv_destroy(struct rl_gpuv *v)
{
    if (!v)
        return;
    if (v->head != v->tail)
        rl_gpuv_flush(v);
    free(v->q);
    free(v->b);
    free(v);
}
