/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_gpu_nocuda.c - Built without CUDA (`make` without CUDA=1): no CUDA back end, so
 * `--mem gpu` and `selftest-gpu` (without --mock) stop with a message.
 */
#include "rl_gpu.h"

const struct rl_gpu_backend *rl_gpu_backend_cuda(void)
{
    return 0;
}
