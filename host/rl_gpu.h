/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gpu.h - GPU ring back ends of rocelet_host (`--mem gpu`).
 *
 * Adapted from an earlier Opsero host receiver (same copyright holder, MIT): the back-end
 * interface, the build split and the BAR1 cap come from there; the checks are rocelet's (the
 * address-based payload pattern of rl_common.h).
 *
 * The rest of rocelet_host sees the GPU through struct rl_gpu_backend, so it builds and is
 * tested without CUDA:
 *   rl_gpu_backend_cuda()  CUDA (rl_gpu_cuda.cu, `make CUDA=1`; NULL otherwise): cudaMalloc
 *                          ring, dma-buf export for ibv_reg_dmabuf_mr(), the verify and scan
 *                          kernels on one stream.
 *   rl_gpu_backend_mock()  host memory and the CPU reference (rl_gpu_ref.c): same interface
 *                          and the same asynchronous completion model, for the unit tests
 *                          and `rocelet_host selftest-gpu --mock`.
 *
 * Verification goes in batches: the caller fills up to bmax descriptors of batch b (memory
 * the GPU reads directly) and calls launch(b, n); one thread block per descriptor checks the
 * region against the pattern and writes one result (memory the CPU reads directly);
 * query(b) says when they are there. Batches run in launch order on one stream.
 */
#ifndef RL_GPU_H_
#define RL_GPU_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One region to check (32 bytes): normally one WRITE-with-immediate message. */
struct rl_gdesc {
    uint64_t off;    /* byte offset of the region in the ring */
    uint64_t pat;    /* pattern address of its first byte (= the VA the FPGA wrote to) */
    uint64_t seq;    /* message number (information, reports) */
    uint32_t len;    /* bytes */
    uint32_t flags;  /* RL_GD_* */
};
#define RL_GD_VERIFY 1u   /* check the region (otherwise only retired in order) */
#define RL_GD_SCRUB  2u   /* after the check, overwrite the region with the fill byte */

/* Its result (128 bytes). bad_bytes and first are exactly rl_pat_check()'s answer. */
struct rl_gres {
    uint64_t bad_bytes;       /* bytes that differ from the pattern */
    uint64_t first;           /* offset of the first one, len if none */
    uint32_t beats;           /* beats checked (a partial last beat counts) */
    uint32_t fill_beats;      /* bad beats holding only the fill byte: never written, or the
                                 write was not visible yet (after a scrub: stale) */
    uint32_t misplaced_beats; /* bad full beats that are the pattern beat of another address */
    uint32_t corrupt_beats;   /* every other bad beat */
    uint32_t checked;         /* 1 = the region was checked */
    uint32_t pad0;
    uint8_t  got[64];         /* the beat holding the first bad byte, as found */
    uint8_t  pad1[24];
};

/* Address scan of a whole plain-WRITE target (scan_write_target() in rocelet_host.c):
 * every full 64-byte beat at address A is the pattern of A (ok), all fill (never written) or
 * bad. A partial last beat is not looked at, as on the CPU. */
#define RL_GSCAN_IDX 8
struct rl_gscan {
    uint64_t ok_beats, fill_beats, bad_beats, misplaced_beats;
    uint64_t first_bad;               /* beat index, UINT64_MAX if none */
    uint64_t nbad_idx;                /* how many bad_idx entries are valid (<= RL_GSCAN_IDX) */
    uint64_t bad_idx[RL_GSCAN_IDX];   /* some bad beat indices (any order on the GPU) */
};

struct rl_gparams {
    uint32_t seed;   /* pattern seed */
    uint32_t fill;   /* fill byte (low 8 bits): what the ring held before any write */
};

/* What open() found out about the device. */
struct rl_gpu_info {
    char     name[96];        /* e.g. "NVIDIA RTX PRO 4000 Blackwell" */
    char     pci[32];         /* PCI bus id */
    int      cc_major, cc_minor;
    int      dmabuf;          /* CU_DEVICE_ATTRIBUTE_DMA_BUF_SUPPORTED */
    int      gdr;             /* CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_SUPPORTED */
    int      rdma_ordering;   /* CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_WRITES_ORDERING */
    int      flush_options;   /* CU_DEVICE_ATTRIBUTE_GPU_DIRECT_RDMA_FLUSH_WRITES_OPTIONS */
    int      flush_each;      /* 1 = cuFlushGPUDirectRDMAWrites() before every launch */
    double   flush_us;        /* its measured cost */
    uint64_t bar1_total;      /* bytes; 0 = unknown (no NVML) */
    uint64_t bar1_free;
};

struct rl_gpu_ctx;

struct rl_gpu_backend {
    const char *name;   /* "cuda" or "mock" */
    /* Open device dev (0-based). bmax = descriptors per batch at most, nb = batches. */
    int  (*open)(struct rl_gpu_ctx **g, int dev, unsigned nb, unsigned bmax,
                 struct rl_gpu_info *info);
    void (*close)(struct rl_gpu_ctx *g);
    /* Ring memory: size bytes rounded up to 2 MiB, every byte = fill; *dptr = device address. */
    int  (*ring_alloc)(struct rl_gpu_ctx *g, size_t size, uint8_t fill, uint64_t *dptr,
                       size_t *alloc_size);
    void (*ring_free)(struct rl_gpu_ctx *g, uint64_t dptr);
    /* dma-buf fd for [dptr, dptr + size) (mock: -1 and an error). */
    int  (*ring_export)(struct rl_gpu_ctx *g, uint64_t dptr, size_t size, int *fd);
    /* Synchronous copies (self-test). */
    int  (*upload)(struct rl_gpu_ctx *g, uint64_t dst, const void *src, size_t n);
    int  (*download)(struct rl_gpu_ctx *g, void *dst, uint64_t src, size_t n);
    /* Batch b's descriptors / results: bmax entries each, host-visible. */
    struct rl_gdesc *(*descs)(struct rl_gpu_ctx *g, unsigned b);
    struct rl_gres  *(*results)(struct rl_gpu_ctx *g, unsigned b);
    /* Check descriptors 0..n-1 of batch b against the ring at dptr. Asynchronous. */
    int  (*launch)(struct rl_gpu_ctx *g, unsigned b, unsigned n, uint64_t dptr,
                   const struct rl_gparams *p);
    /* 1 = batch b's results are there, 0 = not yet, -1 = GPU error (message printed). */
    int  (*query)(struct rl_gpu_ctx *g, unsigned b);
    /* GPU time of batch b's kernel in ms (after query() == 1), < 0 unknown. */
    double (*elapsed_ms)(struct rl_gpu_ctx *g, unsigned b);
    /* Address scan of [dptr, dptr + len) with pattern address va at dptr. Synchronous: waits
     * for the batches launched before it. */
    int  (*scan)(struct rl_gpu_ctx *g, uint64_t dptr, uint64_t va, size_t len,
                 const struct rl_gparams *p, struct rl_gscan *out);
    /* Re-read BAR1 total / free (NVML). 0 = info updated, -1 = unknown. */
    int  (*bar1)(struct rl_gpu_ctx *g, struct rl_gpu_info *info);
};

const struct rl_gpu_backend *rl_gpu_backend_cuda(void); /* NULL: built without CUDA */
const struct rl_gpu_backend *rl_gpu_backend_mock(void);

/* mock only: query() answers "not yet" this many times per batch (default 2). */
void rl_gpu_mock_set_delay(struct rl_gpu_ctx *g, unsigned polls);
/* mock only: launches fail from now on (error-path tests). */
void rl_gpu_mock_set_fail(struct rl_gpu_ctx *g, int fail);
/* mock only: launches so far. */
unsigned long rl_gpu_mock_launches(struct rl_gpu_ctx *g);

/* CPU reference of one verify job and of the scan: what the CUDA kernels must reproduce
 * (rl_gpu_ref.c). ring = the ring's bytes, d->off relative to it. */
void rl_gpu_ref_job(const uint8_t *ring, const struct rl_gdesc *d, const struct rl_gparams *p,
                    struct rl_gres *o);
void rl_gpu_ref_scrub(uint8_t *ring, const struct rl_gdesc *d, const struct rl_gparams *p);
void rl_gpu_ref_scan(const uint8_t *ring, uint64_t va, size_t len, const struct rl_gparams *p,
                     struct rl_gscan *o);

/*
 * Largest GPU ring this device can expose to the NIC: the BAR1 aperture less
 * RL_GPU_BAR1_RESERVE (the driver keeps part of BAR1 for itself: on the P520's 256 MiB BAR1,
 * dma-buf registrations up to 251 MiB work, 252 fails), or RL_GPU_RING_MAX_DEFAULT when BAR1
 * is unknown. Pure.
 */
#define RL_GPU_BAR1_RESERVE     (16ull << 20)
#define RL_GPU_RING_MAX_DEFAULT (240ull << 20)
uint64_t rl_gpu_ring_cap(const struct rl_gpu_info *info);

#ifdef __cplusplus
}
#endif

#endif
