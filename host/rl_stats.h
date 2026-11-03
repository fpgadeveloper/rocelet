/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_stats.h - hw_counters / netdev statistics snapshots.
 */
#ifndef RL_STATS_H_
#define RL_STATS_H_

#include <stdint.h>
#include <stdio.h>

#define SNAP_MAX 256

struct snap_ent {
    char     name[96];   /* "hw.<counter>", "port.<counter>", "net.<stat>" */
    uint64_t v;
};

struct snap {
    double t;
    int    n;
    struct snap_ent e[SNAP_MAX];
};

int  snap_take(struct snap *s, const char *dev, int port, const char *netdev);
int  snap_get(const struct snap *s, const char *name, uint64_t *v);
void snap_print(const struct snap *s, FILE *out);
int  snap_print_delta(const struct snap *a, const struct snap *b, FILE *out, int all);
int  snap_print_problems(const struct snap *a, const struct snap *b, FILE *out);
int  snap_save(const struct snap *s, const char *path);
int  snap_load(struct snap *s, const char *path);

#endif
