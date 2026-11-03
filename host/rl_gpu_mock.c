/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gpu_mock.c - A GPU back end without a GPU: host memory and the CPU reference
 * (rl_gpu_ref.c). Same interface and completion model as rl_gpu_cuda.cu (results appear some
 * polls after the launch, batches in order), so the GPU ring plumbing (rl_gpuv.c) and its
 * accounting are tested on any host. Pattern taken from an earlier Opsero host receiver
 * (same copyright holder, MIT).
 */
#include "rl_gpu.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rl_common.h"

struct rl_gpu_ctx {
    unsigned nb, bmax;
    struct rl_gdesc *d;
    struct rl_gres  *r;
    unsigned *pending;   /* polls left before batch b is "done" */
    double   *ms;
    unsigned delay;
    int      fail;
    unsigned long launches;
};

static int m_open(struct rl_gpu_ctx **gp, int dev, unsigned nb, unsigned bmax,
                  struct rl_gpu_info *info)
{
    struct rl_gpu_ctx *g = calloc(1, sizeof(*g));
    if (!g)
        return -1;
    g->nb = nb;
    g->bmax = bmax;
    g->delay = 2;
    g->d = calloc((size_t)nb * bmax, sizeof(*g->d));
    g->r = calloc((size_t)nb * bmax, sizeof(*g->r));
    g->pending = calloc(nb, sizeof(*g->pending));
    g->ms = calloc(nb, sizeof(*g->ms));
    if (!g->d || !g->r || !g->pending || !g->ms) {
        free(g->d); free(g->r); free(g->pending); free(g->ms); free(g);
        return -1;
    }
    memset(info, 0, sizeof(*info));
    snprintf(info->name, sizeof(info->name), "mock GPU %d (host memory, CPU reference)", dev);
    snprintf(info->pci, sizeof(info->pci), "none");
    info->bar1_total = 256ull << 20;   /* behave like the P520's RTX PRO 4000 */
    info->bar1_free = 255ull << 20;
    *gp = g;
    return 0;
}

static void m_close(struct rl_gpu_ctx *g)
{
    if (!g)
        return;
    free(g->d); free(g->r); free(g->pending); free(g->ms); free(g);
}

static int m_ring_alloc(struct rl_gpu_ctx *g, size_t size, uint8_t fill, uint64_t *dptr,
                        size_t *alloc_size)
{
    size_t as = (size + (2u << 20) - 1) & ~(size_t)((2u << 20) - 1);
    void *p = NULL;
    (void)g;
    if (posix_memalign(&p, 2u << 20, as) != 0) {
        logerr("mock GPU: cannot allocate %zu bytes", as);
        return -1;
    }
    memset(p, fill, as);
    *dptr = (uint64_t)(uintptr_t)p;
    *alloc_size = as;
    return 0;
}

static void m_ring_free(struct rl_gpu_ctx *g, uint64_t dptr)
{
    (void)g;
    free((void *)(uintptr_t)dptr);
}

static int m_ring_export(struct rl_gpu_ctx *g, uint64_t dptr, size_t size, int *fd)
{
    (void)g; (void)dptr; (void)size;
    *fd = -1;
    logerr("mock GPU: no dma-buf export (unit tests only)");
    return -1;
}

static int m_upload(struct rl_gpu_ctx *g, uint64_t dst, const void *src, size_t n)
{
    (void)g;
    memcpy((void *)(uintptr_t)dst, src, n);
    return 0;
}

static int m_download(struct rl_gpu_ctx *g, void *dst, uint64_t src, size_t n)
{
    (void)g;
    memcpy(dst, (const void *)(uintptr_t)src, n);
    return 0;
}

static struct rl_gdesc *m_descs(struct rl_gpu_ctx *g, unsigned b)
{
    return g->d + (size_t)b * g->bmax;
}

static struct rl_gres *m_results(struct rl_gpu_ctx *g, unsigned b)
{
    return g->r + (size_t)b * g->bmax;
}

static int m_launch(struct rl_gpu_ctx *g, unsigned b, unsigned n, uint64_t dptr,
                    const struct rl_gparams *p)
{
    uint8_t *ring = (uint8_t *)(uintptr_t)dptr;
    double t = now_s();
    if (g->fail) {
        logerr("mock GPU: launch failed (test)");
        return -1;
    }
    if (n == 0 || n > g->bmax || b >= g->nb)
        return -1;
    for (unsigned i = 0; i < n; i++) {
        rl_gpu_ref_job(ring, &m_descs(g, b)[i], p, &m_results(g, b)[i]);
        rl_gpu_ref_scrub(ring, &m_descs(g, b)[i], p);
    }
    g->ms[b] = (now_s() - t) * 1e3;
    g->pending[b] = g->delay;
    g->launches++;
    return 0;
}

static int m_query(struct rl_gpu_ctx *g, unsigned b)
{
    if (g->pending[b]) {
        g->pending[b]--;
        return 0;
    }
    return 1;
}

static double m_elapsed(struct rl_gpu_ctx *g, unsigned b)
{
    return g->ms[b];
}

static int m_scan(struct rl_gpu_ctx *g, uint64_t dptr, uint64_t va, size_t len,
                  const struct rl_gparams *p, struct rl_gscan *out)
{
    (void)g;
    rl_gpu_ref_scan((const uint8_t *)(uintptr_t)dptr, va, len, p, out);
    return 0;
}

static int m_bar1(struct rl_gpu_ctx *g, struct rl_gpu_info *info)
{
    (void)g; (void)info;
    return 0;
}

void rl_gpu_mock_set_delay(struct rl_gpu_ctx *g, unsigned polls)
{
    g->delay = polls;
}

void rl_gpu_mock_set_fail(struct rl_gpu_ctx *g, int fail)
{
    g->fail = fail;
}

unsigned long rl_gpu_mock_launches(struct rl_gpu_ctx *g)
{
    return g->launches;
}

static const struct rl_gpu_backend mock_backend = {
    .name = "mock",
    .open = m_open,
    .close = m_close,
    .ring_alloc = m_ring_alloc,
    .ring_free = m_ring_free,
    .ring_export = m_ring_export,
    .upload = m_upload,
    .download = m_download,
    .descs = m_descs,
    .results = m_results,
    .launch = m_launch,
    .query = m_query,
    .elapsed_ms = m_elapsed,
    .scan = m_scan,
    .bar1 = m_bar1,
};

const struct rl_gpu_backend *rl_gpu_backend_mock(void)
{
    return &mock_backend;
}
