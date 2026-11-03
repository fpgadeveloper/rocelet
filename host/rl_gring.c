/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gring.c - GPU ring allocation, dma-buf export and RDMA registration (rl_gring.h).
 * Adapted from an earlier Opsero host receiver (same copyright holder, MIT), including the
 * BAR1 refusal and its messages.
 */
#include "rl_gring.h"

#include <errno.h>
#include <string.h>
#include <unistd.h>

#include "rl_common.h"

int rl_gring_alloc(struct rl_gring *r, const struct rl_gpu_backend *be, struct rl_gpu_ctx *g,
                   const struct rl_gpu_info *info, size_t size, uint8_t fill, int want_export)
{
    uint64_t cap = rl_gpu_ring_cap(info);
    memset(r, 0, sizeof(*r));
    r->fd = -1;
    r->size = size;
    /* the back ends allocate (and register) whole 2 MiB pages */
    size_t as = (size + (2u << 20) - 1) & ~(size_t)((2u << 20) - 1);
    if (size == 0 || as > cap) {
        logerr("a %zu MiB GPU ring (rounded up to 2 MiB pages) does not fit: the NIC reaches GPU "
               "memory through the GPU's "
               "BAR1 aperture (%llu MiB on %s%s), which caps a GPU ring at %llu MiB (BAR1 - %llu "
               "MiB the driver keeps). Use --buf-size %lluM or less (or --buf-size max), or a "
               "host / BIOS with Resizable BAR for a larger BAR1",
               as >> 20, (unsigned long long)((info->bar1_total ? info->bar1_total : 256ull << 20) >> 20),
               info->name, info->bar1_total ? "" : ": unknown (no NVML), assuming 256",
               (unsigned long long)(cap >> 20), (unsigned long long)(RL_GPU_BAR1_RESERVE >> 20),
               (unsigned long long)(cap >> 20));
        return -1;
    }
    if (info->bar1_free && size + (5ull << 20) > info->bar1_free)
        logmsg("WARNING: BAR1 has %llu MiB free on %s; a %zu MiB ring may not register (another "
               "process holding a GPUDirect buffer? `nvidia-smi -q -d MEMORY | grep -A3 BAR1`)",
               (unsigned long long)(info->bar1_free >> 20), info->name, size >> 20);
    if (be->ring_alloc(g, size, fill, &r->dptr, &r->alloc_size))
        return -1;
    r->be = be;
    r->g = g;
    if (want_export && be->ring_export(g, r->dptr, r->alloc_size, &r->fd)) {
        be->ring_free(g, r->dptr);
        r->be = NULL;
        r->dptr = 0;
        return -1;
    }
    return 0;
}

int rl_gring_reg(struct rl_gring *r, struct ibv_pd *pd, int iova_mode, int access)
{
#ifdef RL_CUDA
    double t0 = now_s();
    uint64_t iova = iova_mode == RL_GRING_IOVA_DEV ? r->dptr : 0;
    if (r->fd < 0) {
        logerr("GPU ring: no dma-buf to register");
        return -1;
    }
    r->mr = ibv_reg_dmabuf_mr(pd, 0, r->alloc_size, iova, r->fd, access);
    r->reg_ms = (now_s() - t0) * 1e3;
    if (!r->mr) {
        int e = errno;
        logerr("cannot register the %zu MiB GPU ring for RDMA (ibv_reg_dmabuf_mr, iova 0x%llx): "
               "%s%s", r->alloc_size >> 20, (unsigned long long)iova, strerror(e),
               e == EOPNOTSUPP || e == ENOSYS || e == EPROTONOSUPPORT ?
               " (kernel / rdma-core / NIC without dma-buf MR support: needs Linux >= 5.12, "
               "rdma-core >= 34, an mlx5 NIC, and the NVIDIA open kernel module)" :
               " (BAR1 exhausted? `nvidia-smi -q -d MEMORY | grep -A3 BAR1`; NVRM \"can not "
               "alloc VA space\" in dmesg means the ring is larger than BAR1 allows)");
        return -1;
    }
    r->iova = iova;
    return 0;
#else
    (void)r; (void)pd; (void)iova_mode; (void)access;
    logerr("GPU ring: rocelet_host was built without CUDA (rebuild with `make CUDA=1`)");
    return -1;
#endif
}

void rl_gring_dereg(struct rl_gring *r)
{
    if (r->mr)
        ibv_dereg_mr(r->mr);
    r->mr = NULL;
}

void rl_gring_free(struct rl_gring *r)
{
    rl_gring_dereg(r);
    if (r->fd >= 0)
        close(r->fd);
    r->fd = -1;
    if (r->be && r->dptr)
        r->be->ring_free(r->g, r->dptr);
    r->be = NULL;
    r->dptr = 0;
}
