/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gpuv.h - Batched, in-order verification of a GPU ring (rocelet_host `--mem gpu`).
 *
 * Adapted from an earlier Opsero host receiver (same copyright holder, MIT). The receive loop cannot read a GPU ring, so the split moves: the immediate
 * sequence (lost / duplicate) is still judged on the CPU at the completion; the payload is
 * checked on the GPU in batches, and the results come back in completion order:
 *
 *   receive loop:  rl_gpuv_submit() per completion -> job queue (+ descriptor of the open
 *                  batch) -> launch when the batch is full or its oldest job waited wait_ns
 *   GPU stream:    verify kernel per batch, results to host-visible memory
 *   receive loop:  rl_gpuv_poll(): batch done (event) -> the callback per job, in order
 *
 * The loop never waits for the GPU except when every batch is in flight (back pressure).
 * There is no application-level credit: rocelet's WR generator writes the ring
 * round robin, so the ring must be large enough that a slot is not rewritten while its
 * check is pending (a 64 MiB ring laps every 5.4 ms at 100 Gb/s; a batch waits <= 200 us).
 */
#ifndef RL_GPUV_H_
#define RL_GPUV_H_

#include <stdint.h>

#include "rl_gpu.h"

#ifdef __cplusplus
extern "C" {
#endif

struct rl_gpuv;

struct rl_gpuv_cfg {
    unsigned batch;    /* launch when this many checks are waiting (1..bmax) */
    unsigned nb;       /* batches in flight at most (>= 2; = the back end's nb) */
    unsigned bmax;     /* descriptor slots per batch (= the back end's bmax) */
    uint64_t wait_ns;  /* launch a partial batch once its oldest job waited this long */
    uint32_t depth;    /* jobs queued at most (rounded up to a power of two >= nb * bmax) */
};

enum { RL_GV_SKIPPED, RL_GV_CHECKED, RL_GV_UNCHECKED };

/* Per-job callback at retire time, in submission order. status RL_GV_CHECKED: r is the
 * result; RL_GV_SKIPPED: the job had no RL_GD_VERIFY; RL_GV_UNCHECKED: the GPU failed, no
 * verdict (r NULL in both). */
typedef void (*rl_gpuv_cb)(void *ctx, const struct rl_gdesc *d, const struct rl_gres *r,
                           int status);

struct rl_gpuv *rl_gpuv_create(const struct rl_gpu_backend *be, struct rl_gpu_ctx *g,
                               uint64_t dptr, const struct rl_gparams *p,
                               const struct rl_gpuv_cfg *cfg, rl_gpuv_cb cb, void *ctx);

/* Queue one job (copied). now_ns: CLOCK_MONOTONIC ns (rl_gpuv_now_ns()). */
void rl_gpuv_submit(struct rl_gpuv *v, const struct rl_gdesc *d, uint64_t now_ns);

/* Housekeeping from the receive loop: launch the open batch if its oldest job waited
 * wait_ns (or at once if force), retire what is done. Returns the jobs retired. */
unsigned rl_gpuv_poll(struct rl_gpuv *v, uint64_t now_ns, int force);

/* Launch whatever waits and retire everything. */
void rl_gpuv_flush(struct rl_gpuv *v);

uint64_t rl_gpuv_pending(const struct rl_gpuv *v);
int rl_gpuv_failed(const struct rl_gpuv *v);
uint64_t rl_gpuv_now_ns(void);

struct rl_gpuv_stats {
    uint64_t launches;    /* kernel launches */
    uint64_t gpu_jobs;    /* jobs checked on the GPU */
    double   avg_batch;   /* jobs per launch */
    unsigned max_batch;
    double   gpu_ms;      /* kernel time, sum over batches */
    double   gpu_busy;    /* gpu_ms over wall time since create, 0..1 */
    uint64_t full_waits;  /* times the loop waited for a free batch */
    uint64_t unchecked;   /* jobs left without a verdict by a GPU error */
};
void rl_gpuv_stats(const struct rl_gpuv *v, struct rl_gpuv_stats *st);

/* Flush and free. NULL is a no-op. */
void rl_gpuv_destroy(struct rl_gpuv *v);

#ifdef __cplusplus
}
#endif

#endif
