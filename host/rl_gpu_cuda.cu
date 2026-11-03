/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gpu_cuda.cu - The CUDA back end of rl_gpu.h: GPU ring, verify kernel, scan kernel.
 *
 * Built only with `make CUDA=1` (nvcc; CUDA 11.7 or newer for the dma-buf export). The
 * device setup, the dma-buf export (cuMemGetHandleForAddressRange, so the NIC writes into
 * GPU memory through BAR1 with no nvidia-peermem), the GPUDirect write flush before each
 * launch, the NVML BAR1 query and the batch / event structure come from an earlier Opsero
 * host receiver (same copyright holder, MIT). The kernels are
 * rocelet's: the payload pattern of rl_common.h is a pure function of the address, so every
 * 64-byte beat is checked independently.
 *
 * verify_kernel: one 256-thread block per descriptor (one WRITE-with-immediate message).
 * Each thread takes beats tid, tid + 256, ...: loads the beat (4 x 16-byte loads), compares
 * its 8 words with the pattern of its address, counts the differing bytes and classifies a
 * bad beat as fill (never written / not yet visible), misplaced (the pattern beat of another
 * address) or corrupt. The block reduces in shared memory; thread 0 writes one result to
 * mapped pinned host memory (no copies; 128 B per message back over PCIe). With RL_GD_SCRUB
 * the block then overwrites the message with the fill byte, so a later lap of the ring that
 * did not land (or was not visible yet at its completion) shows up as fill instead of
 * passing on the old data. The CPU reference is rl_gpu_ref.c; `selftest-gpu` compares them.
 *
 * scan_kernel: the address scan of a plain-WRITE target at the end of a run (grid-stride
 * over all beats, counters reduced per block then with global atomics).
 */
#include <cuda.h>
#include <cuda_runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rl_common.h"
#include "rl_gpu.h"

static_assert(sizeof(struct rl_gdesc) == 32, "rl_gdesc size");
static_assert(sizeof(struct rl_gres) == 128, "rl_gres size");

#define VK_THREADS 256
#define SK_THREADS 256

__constant__ uint64_t c_K[8] = RL_PAT_K_INIT;

#define CKR(call, what)                                                                  \
    do {                                                                                 \
        cudaError_t e_ = (call);                                                         \
        if (e_ != cudaSuccess) {                                                         \
            logerr("CUDA: %s: %s", what, cudaGetErrorString(e_));                        \
            return -1;                                                                   \
        }                                                                                \
    } while (0)

#define CKD(call, what)                                                                  \
    do {                                                                                 \
        CUresult r_ = (call);                                                            \
        if (r_ != CUDA_SUCCESS) {                                                        \
            const char *s_ = NULL;                                                       \
            cuGetErrorString(r_, &s_);                                                   \
            logerr("CUDA: %s: %s", what, s_ ? s_ : "?");                                 \
            return -1;                                                                   \
        }                                                                                \
    } while (0)

/* ------------------------------------------------------------------------ */
/* Kernels                                                                  */
/* ------------------------------------------------------------------------ */

/* word i of the pattern beat at address a (sx = {seed, ~seed}) */
__device__ __forceinline__ uint64_t pat_w(uint64_t a, uint64_t sx, int i)
{
    return i ? (a ^ sx) + c_K[i] : a;
}

/* bytes != 0 in x */
__device__ __forceinline__ unsigned diff_bytes(uint64_t x)
{
    x |= x >> 4;
    x |= x >> 2;
    x |= x >> 1;
    return (unsigned)__popcll(x & 0x0101010101010101ull);
}

/* index of the lowest non-zero byte of x (x != 0; little endian = first in memory) */
__device__ __forceinline__ unsigned first_byte(uint64_t x)
{
    return (unsigned)(__ffsll((long long)x) - 1) >> 3;
}

/* one full, 8-byte aligned beat: bad bytes; *fi = first bad byte; *cls 0 fill 1 misplaced
 * 2 corrupt (only when bad) */
__device__ __forceinline__ unsigned beat_words(const uint8_t *p, uint64_t a, uint64_t sx,
                                               uint64_t fw, unsigned *fi, int *cls)
{
    uint64_t w[8];
    if (((uintptr_t)p & 15) == 0) {
        const ulonglong2 *q = (const ulonglong2 *)p;
#pragma unroll
        for (int i = 0; i < 4; i++) {
            ulonglong2 t = q[i];
            w[2 * i] = t.x;
            w[2 * i + 1] = t.y;
        }
    } else {
        const uint64_t *q = (const uint64_t *)p;
#pragma unroll
        for (int i = 0; i < 8; i++)
            w[i] = q[i];
    }
    unsigned bad = 0, f = 64;
    bool allfill = true, own = true;
#pragma unroll
    for (int i = 0; i < 8; i++) {
        uint64_t x = w[i] ^ pat_w(a, sx, i);
        if (x) {
            bad += diff_bytes(x);
            if (f == 64)
                f = 8 * i + first_byte(x);
        }
        allfill = allfill && w[i] == fw;
        if (i)
            own = own && w[i] == pat_w(w[0], sx, i);
    }
    *fi = f;
    *cls = allfill ? 0 : own ? 1 : 2;
    return bad;
}

/* a partial or unaligned beat of n bytes, byte by byte */
__device__ unsigned beat_bytes(const uint8_t *p, unsigned n, uint64_t a, uint64_t sx,
                               uint32_t fill, unsigned *fi, int *cls)
{
    unsigned bad = 0, f = 64;
    bool allfill = true, own = n == 64;
    uint64_t w0 = 0;
    for (unsigned j = 0; j < 8 && j < n; j++)
        w0 |= (uint64_t)p[j] << (8 * j);
    for (unsigned j = 0; j < n; j++) {
        uint8_t got = p[j];
        uint8_t exp = (uint8_t)(pat_w(a, sx, (int)(j >> 3)) >> (8 * (j & 7)));
        if (got != exp) {
            bad++;
            if (f == 64)
                f = j;
        }
        allfill = allfill && got == (uint8_t)fill;
        if (j >= 8)
            own = own && got == (uint8_t)(pat_w(w0, sx, (int)(j >> 3)) >> (8 * (j & 7)));
    }
    *fi = f;
    *cls = allfill ? 0 : own ? 1 : 2;
    return bad;
}

__global__ void __launch_bounds__(VK_THREADS)
verify_kernel(uint8_t *ring, const struct rl_gdesc *__restrict__ descs, struct rl_gres *res,
              uint64_t sx, uint32_t fill)
{
    __shared__ struct rl_gdesc s_d;
    __shared__ unsigned long long s_bad, s_first;
    __shared__ unsigned s_fill, s_mis, s_cor;

    if (threadIdx.x == 0) {
        s_d = descs[blockIdx.x];
        s_bad = 0;
        s_first = ~0ull;
        s_fill = s_mis = s_cor = 0;
    }
    __syncthreads();
    const uint64_t len = s_d.len;
    const uint32_t flags = s_d.flags;
    uint8_t *base = ring + s_d.off;
    const uint64_t fw = 0x0101010101010101ull * (fill & 0xFFu);

    if (flags & RL_GD_VERIFY) {
        const uint64_t nbeats = (len + 63) / 64;
        const bool al8 = ((uintptr_t)base & 7) == 0;
        unsigned long long bad = 0, first = ~0ull;
        unsigned nf = 0, nm = 0, nc = 0;
        for (uint64_t k = threadIdx.x; k < nbeats; k += blockDim.x) {
            const uint64_t bo = k * 64;
            const unsigned n = len - bo < 64 ? (unsigned)(len - bo) : 64u;
            unsigned fi, b;
            int cls;
            if (n == 64 && al8)
                b = beat_words(base + bo, s_d.pat + bo, sx, fw, &fi, &cls);
            else
                b = beat_bytes(base + bo, n, s_d.pat + bo, sx, fill, &fi, &cls);
            if (b) {
                bad += b;
                if (bo + fi < first)
                    first = bo + fi;
                if (cls == 0)
                    nf++;
                else if (cls == 1)
                    nm++;
                else
                    nc++;
            }
        }
        if (bad) {
            atomicAdd(&s_bad, bad);
            atomicMin(&s_first, first);
        }
        if (nf)
            atomicAdd(&s_fill, nf);
        if (nm)
            atomicAdd(&s_mis, nm);
        if (nc)
            atomicAdd(&s_cor, nc);
    }
    __syncthreads();
    if (threadIdx.x == 0) {
        struct rl_gres o;
        memset(&o, 0, sizeof(o));
        o.first = len;
        if (flags & RL_GD_VERIFY) {
            o.checked = 1;
            o.beats = (uint32_t)((len + 63) / 64);
            o.bad_bytes = s_bad;
            o.fill_beats = s_fill;
            o.misplaced_beats = s_mis;
            o.corrupt_beats = s_cor;
            if (s_bad) {
                uint64_t beat = s_first & ~63ull;
                unsigned n = len - beat < 64 ? (unsigned)(len - beat) : 64u;
                o.first = s_first;
                for (unsigned j = 0; j < n; j++)
                    o.got[j] = base[beat + j];
            }
        }
        const uint64_t *src = (const uint64_t *)&o;
        uint64_t *dst = (uint64_t *)&res[blockIdx.x];
        for (int i = 0; i < (int)(sizeof(o) / 8); i++)
            dst[i] = src[i];
    }
    __syncthreads();   /* every read of the message is done: the scrub may overwrite it */
    if (flags & RL_GD_SCRUB) {
        if (((uintptr_t)base & 7) == 0 && (len & 7) == 0) {
            uint64_t *p = (uint64_t *)base;
            for (uint64_t k = threadIdx.x; k < len / 8; k += blockDim.x)
                p[k] = fw;
        } else {
            for (uint64_t j = threadIdx.x; j < len; j += blockDim.x)
                base[j] = (uint8_t)fill;
        }
    }
    if (threadIdx.x == 0)
        __threadfence_system();
}

__global__ void __launch_bounds__(SK_THREADS)
scan_kernel(const uint8_t *ring, uint64_t va, uint64_t nbeats, uint64_t sx, uint32_t fill,
            struct rl_gscan *out)
{
    __shared__ unsigned long long s_ok, s_fill, s_bad, s_mis;
    if (threadIdx.x == 0)
        s_ok = s_fill = s_bad = s_mis = 0;
    __syncthreads();
    const uint64_t fw = 0x0101010101010101ull * (fill & 0xFFu);
    unsigned long long ok = 0, nf = 0, nb = 0, nm = 0;
    for (uint64_t k = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x; k < nbeats;
         k += (uint64_t)gridDim.x * blockDim.x) {
        const uint64_t *p = (const uint64_t *)(ring + 64 * k);
        const uint64_t a = va + 64 * k;
        uint64_t w[8];
        bool good = true, allfill = true, own = true;
#pragma unroll
        for (int i = 0; i < 8; i++) {
            w[i] = p[i];
            good = good && w[i] == pat_w(a, sx, i);
            allfill = allfill && w[i] == fw;
        }
        if (good) {
            ok++;
        } else if (allfill) {
            nf++;
        } else {
#pragma unroll
            for (int i = 1; i < 8; i++)
                own = own && w[i] == pat_w(w[0], sx, i);
            nb++;
            if (own)
                nm++;
            atomicMin((unsigned long long *)&out->first_bad, (unsigned long long)k);
            unsigned long long s = atomicAdd((unsigned long long *)&out->nbad_idx, 1ull);
            if (s < RL_GSCAN_IDX)
                out->bad_idx[s] = k;
        }
    }
    if (ok)
        atomicAdd(&s_ok, ok);
    if (nf)
        atomicAdd(&s_fill, nf);
    if (nb)
        atomicAdd(&s_bad, nb);
    if (nm)
        atomicAdd(&s_mis, nm);
    __syncthreads();
    if (threadIdx.x == 0) {
        atomicAdd((unsigned long long *)&out->ok_beats, s_ok);
        atomicAdd((unsigned long long *)&out->fill_beats, s_fill);
        atomicAdd((unsigned long long *)&out->bad_beats, s_bad);
        atomicAdd((unsigned long long *)&out->misplaced_beats, s_mis);
    }
}

/* ------------------------------------------------------------------------ */
/* Back end                                                                 */
/* ------------------------------------------------------------------------ */

struct rl_gpu_ctx {
    int              dev;
    unsigned         nb, bmax;
    cudaStream_t     stream;
    cudaEvent_t     *ev0, *ev1;   /* per batch: before / after the kernel */
    struct rl_gdesc *d;           /* mapped pinned host memory, nb * bmax */
    struct rl_gres  *r;
    struct rl_gdesc *d_dev;       /* their device views */
    struct rl_gres  *r_dev;
    struct rl_gscan *scan_dev;    /* scan result in device memory */
    int              flush_each;
    char             pci[32];
};

static uint64_t seed_sx(uint32_t seed)
{
    return ((uint64_t)seed << 32) | (uint64_t)(uint32_t)~seed;
}

/* NVML through dlopen (no build dependency): BAR1 size / free of the device. */
typedef struct { unsigned long long total, free, used; } nvml_bar1_t;
static int bar1_query(const char *pci, struct rl_gpu_info *info)
{
    typedef int (*init_t)(void);
    typedef int (*byid_t)(const char *, void **);
    typedef int (*bar1_t)(void *, nvml_bar1_t *);
    void *h = dlopen("libnvidia-ml.so.1", RTLD_NOW | RTLD_LOCAL);
    int rc = -1;
    if (!h)
        return -1;
    init_t init = (init_t)dlsym(h, "nvmlInit_v2");
    init_t shut = (init_t)dlsym(h, "nvmlShutdown");
    byid_t byid = (byid_t)dlsym(h, "nvmlDeviceGetHandleByPciBusId_v2");
    bar1_t bar1 = (bar1_t)dlsym(h, "nvmlDeviceGetBAR1MemoryInfo");
    void *dev = NULL;
    nvml_bar1_t b;
    if (init && shut && byid && bar1 && init() == 0) {
        if (byid(pci, &dev) == 0 && bar1(dev, &b) == 0) {
            info->bar1_total = b.total;
            info->bar1_free = b.free;
            rc = 0;
        }
        shut();
    }
    dlclose(h);
    return rc;
}

static void c_close(struct rl_gpu_ctx *g);

static int c_open(struct rl_gpu_ctx **gp, int dev, unsigned nb, unsigned bmax,
                  struct rl_gpu_info *info)
{
    struct rl_gpu_ctx *g;
    struct cudaDeviceProp prop;
    CUdevice cdev;
    int n = 0;
    unsigned i;

    memset(info, 0, sizeof(*info));
    if (cudaGetDeviceCount(&n) != cudaSuccess || n == 0) {
        logerr("CUDA: no CUDA device found (driver loaded? `nvidia-smi`)");
        return -1;
    }
    if (dev < 0 || dev >= n) {
        logerr("CUDA: --gpu %d: only %d device(s)", dev, n);
        return -1;
    }
    CKR(cudaSetDevice(dev), "cudaSetDevice");
    CKR(cudaFree(0), "context creation");
    CKR(cudaGetDeviceProperties(&prop, dev), "cudaGetDeviceProperties");
    snprintf(info->name, sizeof(info->name), "%.95s", prop.name);
    cudaDeviceGetPCIBusId(info->pci, sizeof(info->pci), dev);
    info->cc_major = prop.major;
    info->cc_minor = prop.minor;
    CKD(cuInit(0), "cuInit");
    CKD(cuDeviceGet(&cdev, dev), "cuDeviceGet");
    cuDeviceGetAttribute(&info->dmabuf, CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED, cdev);
    cuDeviceGetAttribute(&info->gdr, CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_SUPPORTED, cdev);
    cuDeviceGetAttribute(&info->rdma_ordering, CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_WRITES_ORDERING,
                         cdev);
    cuDeviceGetAttribute(&info->flush_options,
                         CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_FLUSH_WRITES_OPTIONS, cdev);
    /* The CPU sees a completion, then launches the kernel: make the NIC's writes visible to
     * the GPU first where the driver offers a flush (a no-op when the device orders remote
     * writes natively, as the RTX PRO 4000 does: 0.03 us). */
    info->flush_each = (info->flush_options & CU_FLUSH_GPU_DIRECT_RDMA_WRITES_OPTION_HOST) != 0;
    if (info->flush_each) {
        double t0 = now_s();
        for (i = 0; i < 100; i++)
            CKD(cuFlushGPUDirectRDMAWrites(CU_FLUSH_GPU_DIRECT_RDMA_WRITES_TARGET_CURRENT_CTX,
                                           CU_FLUSH_GPU_DIRECT_RDMA_WRITES_TO_OWNER),
                "cuFlushGPUDirectRDMAWrites");
        info->flush_us = (now_s() - t0) * 1e6 / 100;
    }
    bar1_query(info->pci, info);

    g = (struct rl_gpu_ctx *)calloc(1, sizeof(*g));
    if (!g)
        return -1;
    g->dev = dev;
    g->nb = nb;
    g->bmax = bmax;
    g->flush_each = info->flush_each;
    snprintf(g->pci, sizeof(g->pci), "%s", info->pci);
    g->ev0 = (cudaEvent_t *)calloc(nb, sizeof(cudaEvent_t));
    g->ev1 = (cudaEvent_t *)calloc(nb, sizeof(cudaEvent_t));
    *gp = g;
    if (!g->ev0 || !g->ev1)
        goto fail;
    if (cudaStreamCreateWithFlags(&g->stream, cudaStreamNonBlocking) != cudaSuccess)
        goto fail;
    for (i = 0; i < nb; i++)
        if (cudaEventCreate(&g->ev0[i]) != cudaSuccess || cudaEventCreate(&g->ev1[i]) != cudaSuccess)
            goto fail;
    if (cudaHostAlloc((void **)&g->d, sizeof(*g->d) * nb * bmax, cudaHostAllocMapped) != cudaSuccess ||
        cudaHostAlloc((void **)&g->r, sizeof(*g->r) * nb * bmax, cudaHostAllocMapped) != cudaSuccess ||
        cudaHostGetDevicePointer((void **)&g->d_dev, g->d, 0) != cudaSuccess ||
        cudaHostGetDevicePointer((void **)&g->r_dev, g->r, 0) != cudaSuccess ||
        cudaMalloc((void **)&g->scan_dev, sizeof(*g->scan_dev)) != cudaSuccess)
        goto fail;
    memset(g->d, 0, sizeof(*g->d) * nb * bmax);
    memset(g->r, 0, sizeof(*g->r) * nb * bmax);
    return 0;
fail:
    logerr("CUDA: cannot create the stream, events or pinned batch buffers: %s",
           cudaGetErrorString(cudaGetLastError()));
    c_close(g);
    *gp = NULL;
    return -1;
}

static void c_close(struct rl_gpu_ctx *g)
{
    unsigned i;
    if (!g)
        return;
    if (g->stream)
        cudaStreamSynchronize(g->stream);
    for (i = 0; i < g->nb; i++) {
        if (g->ev0 && g->ev0[i])
            cudaEventDestroy(g->ev0[i]);
        if (g->ev1 && g->ev1[i])
            cudaEventDestroy(g->ev1[i]);
    }
    if (g->d)
        cudaFreeHost(g->d);
    if (g->r)
        cudaFreeHost(g->r);
    if (g->scan_dev)
        cudaFree(g->scan_dev);
    if (g->stream)
        cudaStreamDestroy(g->stream);
    free(g->ev0);
    free(g->ev1);
    free(g);
}

static int c_ring_alloc(struct rl_gpu_ctx *g, size_t size, uint8_t fill, uint64_t *dptr,
                        size_t *alloc_size)
{
    size_t as = (size + (2u << 20) - 1) & ~(size_t)((2u << 20) - 1);
    void *p = NULL;
    unsigned one = 1;
    (void)g;
    if (cudaMalloc(&p, as) != cudaSuccess) {
        logerr("CUDA: cannot allocate a %zu MiB GPU ring: %s", as >> 20,
               cudaGetErrorString(cudaGetLastError()));
        return -1;
    }
    if (cudaMemset(p, fill, as) != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess) {
        logerr("CUDA: cannot fill the GPU ring: %s", cudaGetErrorString(cudaGetLastError()));
        cudaFree(p);
        return -1;
    }
    /* recommended for memory that peers write (GPUDirect RDMA) */
    cuPointerSetAttribute(&one, CU_POINTER_ATTRIBUTE_SYNC_MEMOPS, (CUdeviceptr)(uintptr_t)p);
    *dptr = (uint64_t)(uintptr_t)p;
    *alloc_size = as;
    return 0;
}

static void c_ring_free(struct rl_gpu_ctx *g, uint64_t dptr)
{
    if (g && g->stream)
        cudaStreamSynchronize(g->stream);
    cudaFree((void *)(uintptr_t)dptr);
}

static int c_ring_export(struct rl_gpu_ctx *g, uint64_t dptr, size_t size, int *fd)
{
    (void)g;
    *fd = -1;
    CKD(cuMemGetHandleForAddressRange(fd, (CUdeviceptr)dptr, size,
                                      CU_MEM_RANGE_HANDLE_TYPE_DMA_BUF_FD, 0),
        "dma-buf export (cuMemGetHandleForAddressRange)");
    return 0;
}

static int c_upload(struct rl_gpu_ctx *g, uint64_t dst, const void *src, size_t n)
{
    CKR(cudaStreamSynchronize(g->stream), "stream sync");
    CKR(cudaMemcpy((void *)(uintptr_t)dst, src, n, cudaMemcpyHostToDevice), "upload");
    return 0;
}

static int c_download(struct rl_gpu_ctx *g, void *dst, uint64_t src, size_t n)
{
    CKR(cudaStreamSynchronize(g->stream), "stream sync");
    CKR(cudaMemcpy(dst, (const void *)(uintptr_t)src, n, cudaMemcpyDeviceToHost), "download");
    return 0;
}

static struct rl_gdesc *c_descs(struct rl_gpu_ctx *g, unsigned b)
{
    return g->d + (size_t)b * g->bmax;
}

static struct rl_gres *c_results(struct rl_gpu_ctx *g, unsigned b)
{
    return g->r + (size_t)b * g->bmax;
}

static int c_flush(struct rl_gpu_ctx *g)
{
    if (g->flush_each)
        CKD(cuFlushGPUDirectRDMAWrites(CU_FLUSH_GPU_DIRECT_RDMA_WRITES_TARGET_CURRENT_CTX,
                                       CU_FLUSH_GPU_DIRECT_RDMA_WRITES_TO_OWNER),
            "cuFlushGPUDirectRDMAWrites");
    return 0;
}

static int c_launch(struct rl_gpu_ctx *g, unsigned b, unsigned n, uint64_t dptr,
                    const struct rl_gparams *p)
{
    if (n == 0 || n > g->bmax || b >= g->nb)
        return -1;
    if (c_flush(g))
        return -1;
    CKR(cudaEventRecord(g->ev0[b], g->stream), "cudaEventRecord");
    verify_kernel<<<n, VK_THREADS, 0, g->stream>>>((uint8_t *)(uintptr_t)dptr,
                                                   g->d_dev + (size_t)b * g->bmax,
                                                   g->r_dev + (size_t)b * g->bmax,
                                                   seed_sx(p->seed), p->fill);
    CKR(cudaGetLastError(), "verify kernel launch");
    CKR(cudaEventRecord(g->ev1[b], g->stream), "cudaEventRecord");
    return 0;
}

static int c_query(struct rl_gpu_ctx *g, unsigned b)
{
    cudaError_t e = cudaEventQuery(g->ev1[b]);
    if (e == cudaSuccess)
        return 1;
    if (e == cudaErrorNotReady)
        return 0;
    logerr("CUDA: verify kernel failed: %s", cudaGetErrorString(e));
    return -1;
}

static double c_elapsed(struct rl_gpu_ctx *g, unsigned b)
{
    float ms = -1.0f;
    if (cudaEventElapsedTime(&ms, g->ev0[b], g->ev1[b]) != cudaSuccess)
        return -1.0;
    return ms;
}

static int c_scan(struct rl_gpu_ctx *g, uint64_t dptr, uint64_t va, size_t len,
                  const struct rl_gparams *p, struct rl_gscan *out)
{
    struct rl_gscan init;
    uint64_t nbeats = len / 64;
    unsigned blocks = (unsigned)((nbeats + SK_THREADS - 1) / SK_THREADS);
    if (blocks > 2048)
        blocks = 2048;
    if (!blocks)
        blocks = 1;
    memset(&init, 0, sizeof(init));
    init.first_bad = UINT64_MAX;
    if (c_flush(g))
        return -1;
    CKR(cudaMemcpyAsync(g->scan_dev, &init, sizeof(init), cudaMemcpyHostToDevice, g->stream),
        "scan init");
    scan_kernel<<<blocks, SK_THREADS, 0, g->stream>>>((const uint8_t *)(uintptr_t)dptr, va, nbeats,
                                                      seed_sx(p->seed), p->fill, g->scan_dev);
    CKR(cudaGetLastError(), "scan kernel launch");
    CKR(cudaMemcpyAsync(out, g->scan_dev, sizeof(*out), cudaMemcpyDeviceToHost, g->stream),
        "scan result");
    CKR(cudaStreamSynchronize(g->stream), "scan kernel");
    if (out->nbad_idx > RL_GSCAN_IDX)
        out->nbad_idx = RL_GSCAN_IDX;
    return 0;
}

static int c_bar1(struct rl_gpu_ctx *g, struct rl_gpu_info *info)
{
    return bar1_query(g->pci, info);
}

static const struct rl_gpu_backend cuda_backend = {
    "cuda", c_open, c_close, c_ring_alloc, c_ring_free, c_ring_export, c_upload, c_download,
    c_descs, c_results, c_launch, c_query, c_elapsed, c_scan, c_bar1,
};

const struct rl_gpu_backend *rl_gpu_backend_cuda(void)
{
    return &cuda_backend;
}
