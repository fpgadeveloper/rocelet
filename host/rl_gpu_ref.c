/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gpu_ref.c - CPU reference of the GPU checks (rl_gpu.h): one verify job, the scrub and
 * the address scan of a plain-WRITE target. The mock back end runs these; the CUDA kernels
 * (rl_gpu_cuda.cu) must give the same answers, which `rocelet_host selftest-gpu` compares
 * on a real GPU. bad_bytes / first are rl_pat_check()'s numbers, so a GPU run reports the
 * same verified and wrong byte counts as the CPU path.
 */
#include "rl_gpu.h"

#include <string.h>

#include "rl_common.h"

_Static_assert(sizeof(struct rl_gdesc) == 32, "rl_gdesc size");
_Static_assert(sizeof(struct rl_gres) == 128, "rl_gres size");

static uint64_t le64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--)
        v = (v << 8) | p[i];
    return v;
}

static int all_fill(const uint8_t *p, size_t n, uint8_t fill)
{
    for (size_t j = 0; j < n; j++)
        if (p[j] != fill)
            return 0;
    return 1;
}

/* A full beat that is the pattern beat of the address in its own bytes 0..7. */
static int own_pattern(const uint8_t *p, uint32_t seed)
{
    uint8_t e[64];
    rl_pat_beat(le64(p), seed, e);
    return !memcmp(p, e, 64);
}

void rl_gpu_ref_job(const uint8_t *ring, const struct rl_gdesc *d, const struct rl_gparams *p,
                    struct rl_gres *o)
{
    const uint8_t *b = ring + d->off;
    const uint8_t fill = (uint8_t)p->fill;
    uint8_t e[64];

    memset(o, 0, sizeof(*o));
    o->first = d->len;
    if (!(d->flags & RL_GD_VERIFY))
        return;
    o->checked = 1;
    for (uint64_t bo = 0; bo < d->len; bo += 64) {
        size_t n = d->len - bo < 64 ? (size_t)(d->len - bo) : 64;
        unsigned bad = 0;
        rl_pat_beat(d->pat + bo, p->seed, e);
        o->beats++;
        for (size_t j = 0; j < n; j++)
            if (b[bo + j] != e[j]) {
                if (!bad && o->first == d->len)
                    o->first = bo + j;
                bad++;
            }
        if (!bad)
            continue;
        o->bad_bytes += bad;
        if (all_fill(b + bo, n, fill))
            o->fill_beats++;
        else if (n == 64 && own_pattern(b + bo, p->seed))
            o->misplaced_beats++;
        else
            o->corrupt_beats++;
    }
    if (o->bad_bytes) {
        uint64_t beat = o->first & ~(uint64_t)63;
        size_t n = d->len - beat < 64 ? (size_t)(d->len - beat) : 64;
        memcpy(o->got, b + beat, n);
    }
}

void rl_gpu_ref_scrub(uint8_t *ring, const struct rl_gdesc *d, const struct rl_gparams *p)
{
    if (d->flags & RL_GD_SCRUB)
        memset(ring + d->off, (uint8_t)p->fill, d->len);
}

void rl_gpu_ref_scan(const uint8_t *ring, uint64_t va, size_t len, const struct rl_gparams *p,
                     struct rl_gscan *o)
{
    uint8_t e[64];
    memset(o, 0, sizeof(*o));
    o->first_bad = UINT64_MAX;
    for (size_t off = 0; off + 64 <= len; off += 64) {
        rl_pat_beat(va + off, p->seed, e);
        if (!memcmp(ring + off, e, 64)) {
            o->ok_beats++;
        } else if (all_fill(ring + off, 64, (uint8_t)p->fill)) {
            o->fill_beats++;
        } else {
            uint64_t k = off / 64;
            o->bad_beats++;
            if (own_pattern(ring + off, p->seed))
                o->misplaced_beats++;
            if (k < o->first_bad)
                o->first_bad = k;
            if (o->nbad_idx < RL_GSCAN_IDX)
                o->bad_idx[o->nbad_idx++] = k;
        }
    }
}

uint64_t rl_gpu_ring_cap(const struct rl_gpu_info *info)
{
    if (!info || info->bar1_total == 0)
        return RL_GPU_RING_MAX_DEFAULT;
    if (info->bar1_total <= RL_GPU_BAR1_RESERVE)
        return 0;
    return info->bar1_total - RL_GPU_BAR1_RESERVE;
}
