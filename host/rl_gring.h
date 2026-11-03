/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gring.h - A receive ring in GPU memory, registered for RDMA through a dma-buf
 * (cudaMalloc -> cuMemGetHandleForAddressRange -> ibv_reg_dmabuf_mr). No nvidia-peermem:
 * it needs the NVIDIA open kernel module, Linux >= 5.12 and rdma-core >= 34 (inbox mlx5 is
 * enough). Adapted from an earlier Opsero host receiver (same copyright holder,
 * MIT).
 *
 * IOVA: the address the FPGA writes to. rocelet_host registers the ring at IOVA 0 by default
 * (the Holoscan Sensor Bridge host convention: the RLHM va= is then the byte offset in the
 * ring); RL_GRING_IOVA_DEV registers it at the GPU device address instead (the va=
 * then looks like any host VA).
 */
#ifndef RL_GRING_H_
#define RL_GRING_H_

#include <stddef.h>
#include <stdint.h>

#include <infiniband/verbs.h>

#include "rl_gpu.h"

enum { RL_GRING_IOVA_ZERO = 0, RL_GRING_IOVA_DEV = 1 };

struct rl_gring {
    const struct rl_gpu_backend *be;
    struct rl_gpu_ctx *g;
    uint64_t dptr;          /* GPU device address */
    size_t   size;          /* bytes requested */
    size_t   alloc_size;    /* bytes allocated (2 MiB rounding) */
    int      fd;            /* the exported dma-buf, -1 if none */
    uint64_t iova;          /* the address the peer writes to (valid after rl_gring_reg) */
    struct ibv_mr *mr;
    double   reg_ms;        /* time ibv_reg_dmabuf_mr took */
};

/* Allocate size bytes (every byte = fill) on an opened back end and, if want_export, export
 * them as a dma-buf. Refuses (message, nothing allocated) above rl_gpu_ring_cap(info) and
 * warns if BAR1's free space looks too small. 0 / -1. */
int rl_gring_alloc(struct rl_gring *r, const struct rl_gpu_backend *be, struct rl_gpu_ctx *g,
                   const struct rl_gpu_info *info, size_t size, uint8_t fill, int want_export);
/* Register the exported ring with pd (iova_mode RL_GRING_IOVA_*). Needs a CUDA=1 build. */
int rl_gring_reg(struct rl_gring *r, struct ibv_pd *pd, int iova_mode, int access);
void rl_gring_dereg(struct rl_gring *r);
/* Deregister, close the dma-buf and free the GPU memory. */
void rl_gring_free(struct rl_gring *r);

/* `rocelet_host selftest-gpu` (rl_gpu_selftest.c). Returns an EX_* code. */
struct rl_gst_cfg {
    int         mock;        /* 1 = mock back end (no GPU; no dma-buf, no registration) */
    int         gpu;         /* CUDA device index */
    const char *rdma_dev;    /* RDMA device for the registration test; NULL = the first one */
    uint64_t    ring_size;   /* registration / benchmark ring; 0 = the BAR1 cap */
    int         iova_mode;   /* RL_GRING_IOVA_*, or -1 = both */
    uint32_t    seed;
};
int rl_selftest_gpu(const struct rl_gst_cfg *c);

#endif
