/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_stats.c - snapshots of the RDMA device's hw_counters
 * (/sys/class/infiniband/<dev>/ports/<port>/hw_counters/<name>) and the
 * netdev's generic statistics (/sys/class/net/<if>/statistics/<name>), with deltas.
 * Reading hw_counters can make the driver gather statistics from the device
 * (a control-path command on some NICs); it does not affect traffic.
 */
#include "rl_stats.h"

#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rl_common.h"

static int add(struct snap *s, const char *name, uint64_t v)
{
    if (s->n >= SNAP_MAX)
        return -1;
    size_t l = strlen(name);
    if (l >= sizeof(s->e[s->n].name))
        l = sizeof(s->e[s->n].name) - 1;
    memcpy(s->e[s->n].name, name, l);
    s->e[s->n].name[l] = 0;
    s->e[s->n].v = v;
    s->n++;
    return 0;
}

static int cmp_name(const void *a, const void *b)
{
    return strcmp(((const struct snap_ent *)a)->name, ((const struct snap_ent *)b)->name);
}

static int read_dir(struct snap *s, const char *dir, const char *prefix)
{
    DIR *d = opendir(dir);
    struct dirent *de;
    if (!d)
        return -1;
    while ((de = readdir(d))) {
        char path[800], line[64], name[320];
        if (de->d_name[0] == '.')
            continue;
        snprintf(path, sizeof(path), "%s/%s", dir, de->d_name);
        FILE *f = fopen(path, "r");
        if (!f)
            continue;
        if (fgets(line, sizeof(line), f)) {
            char *end;
            errno = 0;
            unsigned long long v = strtoull(line, &end, 10);
            if (!errno && end != line) {
                snprintf(name, sizeof(name), "%s%s", prefix, de->d_name);
                add(s, name, v);
            }
        }
        fclose(f);
    }
    closedir(d);
    return 0;
}

int snap_take(struct snap *s, const char *dev, int port, const char *netdev)
{
    char dir[256];
    memset(s, 0, sizeof(*s));
    s->t = now_s();
    snprintf(dir, sizeof(dir), "/sys/class/infiniband/%s/ports/%d/hw_counters", dev, port);
    int rc = read_dir(s, dir, "hw.");
    if (rc)
        logmsg("note: cannot read %s: %s", dir, strerror(errno));
    snprintf(dir, sizeof(dir), "/sys/class/infiniband/%s/ports/%d/counters", dev, port);
    read_dir(s, dir, "port.");               /* absent on some providers; present on mlx5 */
    if (netdev && *netdev) {
        snprintf(dir, sizeof(dir), "/sys/class/net/%s/statistics", netdev);
        read_dir(s, dir, "net.");
    }
    qsort(s->e, (size_t)s->n, sizeof(s->e[0]), cmp_name);
    return rc;
}

int snap_get(const struct snap *s, const char *name, uint64_t *v)
{
    for (int i = 0; i < s->n; i++)
        if (!strcmp(s->e[i].name, name)) {
            *v = s->e[i].v;
            return 0;
        }
    return -1;
}

void snap_print(const struct snap *s, FILE *out)
{
    for (int i = 0; i < s->n; i++)
        fprintf(out, "  %-28s %" PRIu64 "\n", s->e[i].name, s->e[i].v);
}

int snap_print_delta(const struct snap *a, const struct snap *b, FILE *out, int all)
{
    int shown = 0;
    for (int i = 0; i < b->n; i++) {
        uint64_t va = 0;
        if (snap_get(a, b->e[i].name, &va))
            va = 0;
        uint64_t d = b->e[i].v - va;
        if (!all && d == 0)
            continue;
        if (!strcmp(b->e[i].name, "hw.lifespan"))
            continue;
        fprintf(out, "  %-28s %+" PRId64 "   (now %" PRIu64 ")\n", b->e[i].name, (int64_t)d,
                b->e[i].v);
        shown++;
    }
    if (!shown)
        fprintf(out, "  (no counter changed)\n");
    return shown;
}

int snap_save(const struct snap *s, const char *path)
{
    FILE *f = fopen(path, "w");
    if (!f) {
        logerr("cannot write %s: %s", path, strerror(errno));
        return -1;
    }
    fprintf(f, "# rocelet_host counter snapshot t=%.6f\n", s->t);
    for (int i = 0; i < s->n; i++)
        fprintf(f, "%s %" PRIu64 "\n", s->e[i].name, s->e[i].v);
    fclose(f);
    return 0;
}

int snap_load(struct snap *s, const char *path)
{
    FILE *f = fopen(path, "r");
    char line[256];
    if (!f) {
        logerr("cannot read %s: %s", path, strerror(errno));
        return -1;
    }
    memset(s, 0, sizeof(*s));
    while (fgets(line, sizeof(line), f)) {
        char name[96];
        unsigned long long v;
        if (line[0] == '#') {
            sscanf(line, "# rocelet_host counter snapshot t=%lf", &s->t);
            continue;
        }
        if (sscanf(line, "%95s %llu", name, &v) == 2)
            add(s, name, v);
    }
    fclose(f);
    return 0;
}

/* Problem indicators: counters that should stay 0 in a clean test. */
static const char *const bad_counters[] = {
    "hw.ip4InDiscards", "hw.ip4InTruncatedPkts", "hw.ip4OutNoRoutes", "hw.rxVlanErrors",
    "hw.tcpInProtoErrors", "hw.tcpRetransSegs",
    /* mlx5 hw_counters (names as listed by a ConnectX-6 Dx on the inbox 6.8 kernel, 2026-10-30;
     * rx_discards_phy, tx/rx_pause_ctrl_phy and outbound_pci_stalled_wr are ethtool -S counters,
     * not hw_counters: read them with ethtool) */
    "hw.rx_icrc_encapsulated", "hw.out_of_sequence", "hw.packet_seq_err", "hw.duplicate_request",
    "hw.local_ack_timeout_err", "hw.rnr_nak_retry_err", "hw.implied_nak_seq_err",
    "hw.out_of_buffer", "hw.roce_adp_retrans", "hw.roce_adp_retrans_to", "hw.roce_slow_restart",
    "hw.np_cnp_sent", "hw.rp_cnp_handled", "hw.req_cqe_error", "hw.resp_cqe_error",
    "hw.req_remote_access_errors", "hw.resp_remote_access_errors", "hw.resp_local_length_error",
    "hw.req_remote_invalid_request",
    "net.rx_crc_errors", "net.rx_errors", "net.rx_dropped", "net.rx_missed_errors",
    "net.rx_over_errors", "net.rx_length_errors", "net.tx_errors", NULL
};

int snap_print_problems(const struct snap *a, const struct snap *b, FILE *out)
{
    int n = 0;
    for (int i = 0; bad_counters[i]; i++) {
        uint64_t va = 0, vb;
        if (snap_get(b, bad_counters[i], &vb))
            continue;
        snap_get(a, bad_counters[i], &va);
        if (vb != va) {
            fprintf(out, "  WATCH: %s %+" PRId64 "\n", bad_counters[i], (int64_t)(vb - va));
            n++;
        }
    }
    return n;
}
