/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_verbs.c - libibverbs helpers of rocelet_host. Plain verbs only (no rdma_cm):
 * the QP parameters come from the out-of-band record exchange.
 */
#include "rl_verbs.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rl_common.h"

enum ibv_mtu mtu_to_ibv(uint32_t bytes)
{
    switch (bytes) {
    case 256:  return IBV_MTU_256;
    case 512:  return IBV_MTU_512;
    case 1024: return IBV_MTU_1024;
    case 2048: return IBV_MTU_2048;
    case 4096: return IBV_MTU_4096;
    }
    return (enum ibv_mtu)0;
}

uint32_t mtu_from_ibv(enum ibv_mtu m)
{
    return (m >= IBV_MTU_256 && m <= IBV_MTU_4096) ? 128u << m : 0;
}

int is_ipv4_mapped(const uint8_t g[16])
{
    static const uint8_t pfx[12] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    return memcmp(g, pfx, sizeof(pfx)) == 0;
}

const char *gid_str(const uint8_t g[16], char *s, size_t n)
{
    if (!inet_ntop(AF_INET6, g, s, (socklen_t)n))
        snprintf(s, n, "?");
    return s;
}

static const char *gid_type_str(uint32_t t)
{
    switch (t) {
    case IBV_GID_TYPE_IB:      return "IB";
    case IBV_GID_TYPE_ROCE_V1: return "RoCEv1";
    case IBV_GID_TYPE_ROCE_V2: return "RoCEv2";
    }
    return "?";
}

const char *qp_state_str(enum ibv_qp_state s)
{
    switch (s) {
    case IBV_QPS_RESET: return "RESET";
    case IBV_QPS_INIT:  return "INIT";
    case IBV_QPS_RTR:   return "RTR";
    case IBV_QPS_RTS:   return "RTS";
    case IBV_QPS_SQD:   return "SQD";
    case IBV_QPS_SQE:   return "SQE";
    case IBV_QPS_ERR:   return "ERR";
    default:            return "?";
    }
}

static int read_sysfs_str(const char *path, char *buf, size_t n)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    if (!fgets(buf, (int)n, f)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    buf[strcspn(buf, "\r\n")] = 0;
    return 0;
}

static int netdev_mac(const char *ifname, uint8_t mac[6])
{
    char path[160], line[64];
    unsigned v[6];
    snprintf(path, sizeof(path), "/sys/class/net/%s/address", ifname);
    if (read_sysfs_str(path, line, sizeof(line)) ||
        sscanf(line, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6)
        return -1;
    for (int i = 0; i < 6; i++)
        mac[i] = (uint8_t)v[i];
    return 0;
}

static int netdev_mtu(const char *ifname)
{
    char path[160], line[32];
    snprintf(path, sizeof(path), "/sys/class/net/%s/mtu", ifname);
    if (read_sysfs_str(path, line, sizeof(line)))
        return -1;
    return atoi(line);
}

static struct ibv_context *open_by_name(const char *name)
{
    int n;
    struct ibv_context *ctx = NULL;
    struct ibv_device **list = ibv_get_device_list(&n);
    if (!list) {
        logerr("cannot list RDMA devices: %s (rdma-core installed, driver loaded?)",
               strerror(errno));
        return NULL;
    }
    int i;
    for (i = 0; i < n; i++)
        if (!strcmp(ibv_get_device_name(list[i]), name))
            break;
    if (i == n) {
        logerr("no RDMA device named '%s'", name);
        for (i = 0; i < n; i++)
            logmsg("  available: %s", ibv_get_device_name(list[i]));
    } else {
        ctx = ibv_open_device(list[i]);
        if (!ctx)
            logerr("cannot open RDMA device %s: %s", name, strerror(errno));
    }
    ibv_free_device_list(list);
    return ctx;
}

int vdev_first(char *buf, size_t n)
{
    int cnt;
    struct ibv_device **list = ibv_get_device_list(&cnt);
    if (!list) {
        logerr("cannot list RDMA devices: %s (rdma-core installed, driver loaded?)",
               strerror(errno));
        return -1;
    }
    if (cnt < 1) {
        logerr("no RDMA device present (use --dev once one is)");
        ibv_free_device_list(list);
        return -1;
    }
    snprintf(buf, n, "%s", ibv_get_device_name(list[0]));
    if (cnt > 1)
        logmsg("--dev not given: using the first RDMA device, %s (%d present)", buf, cnt);
    ibv_free_device_list(list);
    return 0;
}

static void print_gid_table(struct ibv_context *ctx, uint8_t port, int len)
{
    printf("  %5s  %-7s  %-40s  %s\n", "index", "type", "gid", "netdev");
    for (int i = 0; i < len; i++) {
        struct ibv_gid_entry ge;
        char gs[64], ifn[IF_NAMESIZE] = "-";
        if (ibv_query_gid_ex(ctx, port, (uint32_t)i, &ge, 0))
            continue;
        if (ge.ndev_ifindex)
            if_indextoname(ge.ndev_ifindex, ifn);
        printf("  %5d  %-7s  %-40s  %s%s\n", i, gid_type_str(ge.gid_type),
               gid_str(ge.gid.raw, gs, sizeof(gs)), ifn,
               ge.gid_type == IBV_GID_TYPE_ROCE_V2 && is_ipv4_mapped(ge.gid.raw)
                   ? "   <- RoCE v2 IPv4 (usable)" : "");
    }
}

int vdev_open(struct vdev *d, const char *name, int port, int gid_index,
              const uint8_t *local_ip, int need_active, int alloc_pd)
{
    char gs[64];
    memset(d, 0, sizeof(*d));
    snprintf(d->name, sizeof(d->name), "%s", name);
    d->port = (uint8_t)port;

    d->ctx = open_by_name(name);
    if (!d->ctx)
        return EX_SETUP;
    if (ibv_query_device(d->ctx, &d->dattr)) {
        logerr("ibv_query_device(%s): %s", name, strerror(errno));
        goto fail;
    }
    if (port < 1 || port > d->dattr.phys_port_cnt) {
        logerr("%s has port(s) 1..%u, not %d", name, d->dattr.phys_port_cnt, port);
        goto fail;
    }
    if (ibv_query_port(d->ctx, d->port, &d->pattr)) {
        logerr("ibv_query_port(%s, %d): %s", name, port, strerror(errno));
        goto fail;
    }
    if (d->pattr.link_layer != IBV_LINK_LAYER_ETHERNET) {
        logerr("%s port %d is not an Ethernet (RoCE) port", name, port);
        goto fail;
    }

    /* GID: explicit index, or the RoCE v2 IPv4-mapped entry */
    if (gid_index < 0) {
        int found = -1, nfound = 0;
        for (int i = 0; i < d->pattr.gid_tbl_len; i++) {
            struct ibv_gid_entry ge;
            if (ibv_query_gid_ex(d->ctx, d->port, (uint32_t)i, &ge, 0))
                continue;
            if (ge.gid_type != IBV_GID_TYPE_ROCE_V2 || !is_ipv4_mapped(ge.gid.raw))
                continue;
            if (local_ip && memcmp(ge.gid.raw + 12, local_ip, 4))
                continue;
            if (found < 0)
                found = i;
            nfound++;
        }
        if (found < 0) {
            logerr("%s port %d has no RoCE v2 IPv4 GID%s: give its netdev an IPv4 address "
                   "(nmcli con up <profile>) and check `rocelet_host info --dev %s`",
                   name, port, local_ip ? " for the requested --local-ip" : "", name);
            print_gid_table(d->ctx, d->port, d->pattr.gid_tbl_len);
            goto fail;
        }
        if (nfound > 1)
            logmsg("note: %d RoCE v2 IPv4 GIDs on %s port %d, using index %d (--gid-index or "
                   "--local-ip to choose)", nfound, name, port, found);
        gid_index = found;
    }
    struct ibv_gid_entry ge;
    int rc = ibv_query_gid_ex(d->ctx, d->port, (uint32_t)gid_index, &ge, 0);
    if (rc) {
        logerr("GID index %d of %s port %d: %s", gid_index, name, port,
               rc == ENODATA ? "empty entry" : strerror(rc));
        goto fail;
    }
    d->gid_index = gid_index;
    memcpy(d->gid, ge.gid.raw, 16);
    if (ge.gid_type != IBV_GID_TYPE_ROCE_V2 || !is_ipv4_mapped(d->gid)) {
        logerr("GID index %d (%s, %s) is not a RoCE v2 IPv4-mapped GID", gid_index,
               gid_str(d->gid, gs, sizeof(gs)), gid_type_str(ge.gid_type));
        goto fail;
    }
    memcpy(d->ipv4, d->gid + 12, 4);
    if (!if_indextoname(ge.ndev_ifindex, d->netdev) || netdev_mac(d->netdev, d->mac)) {
        logerr("cannot find the netdev / MAC of GID index %d", gid_index);
        goto fail;
    }
    d->netdev_mtu = netdev_mtu(d->netdev);

    if (need_active && d->pattr.state != IBV_PORT_ACTIVE) {
        logerr("%s port %d (%s) is %s, not ACTIVE: check the cable / link (`ip link show %s`)",
               name, port, d->netdev, ibv_port_state_str(d->pattr.state), d->netdev);
        goto fail;
    }
    if (alloc_pd) {
        d->pd = ibv_alloc_pd(d->ctx);
        if (!d->pd) {
            logerr("ibv_alloc_pd: %s", strerror(errno));
            goto fail;
        }
    }
    return EX_OK;
fail:
    vdev_close(d);
    return EX_SETUP;
}

void vdev_close(struct vdev *d)
{
    if (d->pd)
        ibv_dealloc_pd(d->pd);
    if (d->ctx)
        ibv_close_device(d->ctx);
    d->pd = NULL;
    d->ctx = NULL;
}

int vdev_print_info(const char *name, int port)
{
    struct ibv_context *ctx = open_by_name(name);
    struct ibv_device_attr da;
    struct ibv_port_attr pa;
    if (!ctx)
        return EX_SETUP;
    if (ibv_query_device(ctx, &da) || ibv_query_port(ctx, (uint8_t)port, &pa)) {
        logerr("query %s port %d: %s", name, port, strerror(errno));
        ibv_close_device(ctx);
        return EX_SETUP;
    }
    printf("%s: fw %s, vendor 0x%x part 0x%x, max_qp %d, max_qp_wr %d, max_cqe %d, max_mr_size 0x%llx\n",
           name, da.fw_ver, da.vendor_id, da.vendor_part_id, da.max_qp, da.max_qp_wr, da.max_cqe,
           (unsigned long long)da.max_mr_size);
    printf("  max_qp_rd_atom %d (host as responder: FPGA READs in flight), max_qp_init_rd_atom %d "
           "(host READs in flight), max_sge %d\n",
           da.max_qp_rd_atom, da.max_qp_init_rd_atom, da.max_sge);
    printf("port %d: state %s, phys %s, link layer %s, active_mtu %u, max_mtu %u, max_msg_sz 0x%x, "
           "gid_tbl_len %d\n",
           port, ibv_port_state_str(pa.state),
           pa.phys_state == 5 ? "LinkUp" : pa.phys_state == 3 ? "Disabled" : "other",
           pa.link_layer == IBV_LINK_LAYER_ETHERNET ? "Ethernet" : "IB",
           mtu_from_ibv(pa.active_mtu), mtu_from_ibv(pa.max_mtu), pa.max_msg_sz, pa.gid_tbl_len);
    print_gid_table(ctx, (uint8_t)port, pa.gid_tbl_len);
    ibv_close_device(ctx);
    return EX_OK;
}

int vqp_create(struct vdev *d, struct vqp *q, enum ibv_qp_type type, uint32_t max_send_wr,
               uint32_t max_recv_wr)
{
    struct ibv_qp_init_attr ia;
    memset(q, 0, sizeof(*q));
    if (max_send_wr > (uint32_t)d->dattr.max_qp_wr || max_recv_wr > (uint32_t)d->dattr.max_qp_wr) {
        logerr("queue depth %u/%u exceeds the device limit of %d WRs", max_send_wr, max_recv_wr,
               d->dattr.max_qp_wr);
        return -1;
    }
    q->scq = ibv_create_cq(d->ctx, (int)max_send_wr + 1, NULL, NULL, 0);
    q->rcq = ibv_create_cq(d->ctx, (int)max_recv_wr + 1, NULL, NULL, 0);
    if (!q->scq || !q->rcq) {
        logerr("ibv_create_cq: %s", strerror(errno));
        goto fail;
    }
    memset(&ia, 0, sizeof(ia));
    ia.send_cq = q->scq;
    ia.recv_cq = q->rcq;
    ia.qp_type = type;
    ia.cap.max_send_wr = max_send_wr;
    ia.cap.max_recv_wr = max_recv_wr;
    ia.cap.max_send_sge = 1;
    ia.cap.max_recv_sge = 1;
    ia.sq_sig_all = 0;
    q->qp = ibv_create_qp(d->pd, &ia);
    if (!q->qp) {
        int e = errno;
        logerr("ibv_create_qp(%s, send %u, recv %u): %s", type == IBV_QPT_UC ? "UC" : "RC",
               max_send_wr, max_recv_wr, strerror(e));
        if (type == IBV_QPT_UC && (e == EOPNOTSUPP || e == EINVAL))
            logmsg("  this device does not support UC QPs (many providers accept RC/UD only); UC is an "
                   "NVIDIA (mlx5) / rxe feature");
        goto fail;
    }
    return 0;
fail:
    vqp_destroy(q);
    return -1;
}

void vqp_destroy(struct vqp *q)
{
    if (q->qp)
        ibv_destroy_qp(q->qp);
    if (q->scq)
        ibv_destroy_cq(q->scq);
    if (q->rcq)
        ibv_destroy_cq(q->rcq);
    memset(q, 0, sizeof(*q));
}

int vqp_to_init(struct vqp *q, uint8_t port, int access)
{
    struct ibv_qp_attr a;
    memset(&a, 0, sizeof(a));
    a.qp_state = IBV_QPS_INIT;
    a.pkey_index = 0;
    a.port_num = port;
    a.qp_access_flags = (unsigned)access;
    int rc = ibv_modify_qp(q->qp, &a, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT |
                                          IBV_QP_ACCESS_FLAGS);
    if (rc)
        logerr("QP to INIT: %s", strerror(rc));
    return rc ? -1 : 0;
}

int vqp_to_rtr(struct vqp *q, const struct vdev *d, const struct qp_params *p)
{
    struct ibv_qp_attr a;
    char gs[64];
    memset(&a, 0, sizeof(a));
    a.qp_state = IBV_QPS_RTR;
    a.path_mtu = mtu_to_ibv(p->mtu);
    a.dest_qp_num = p->dest_qpn;
    a.rq_psn = p->rq_psn;
    a.ah_attr.is_global = 1;                 /* RoCE always carries the IP header */
    memcpy(a.ah_attr.grh.dgid.raw, p->dgid, 16);
    a.ah_attr.grh.sgid_index = (uint8_t)d->gid_index;
    a.ah_attr.grh.hop_limit = p->hop_limit;
    a.ah_attr.grh.traffic_class = p->traffic_class;
    a.ah_attr.port_num = d->port;
    int mask = IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN;
    if (p->type == IBV_QPT_RC) {
        a.max_dest_rd_atomic = p->max_dest_rd_atomic;
        a.min_rnr_timer = p->min_rnr_timer;
        mask |= IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER;
    }
    int rc = ibv_modify_qp(q->qp, &a, mask);
    if (rc) {
        logerr("QP to RTR (peer QPN 0x%06x, GID %s, path MTU %u): %s", p->dest_qpn,
               gid_str(p->dgid, gs, sizeof(gs)), p->mtu, strerror(rc));
        if (rc == ETIMEDOUT || rc == ENODATA || rc == EHOSTUNREACH)
            logmsg("  the kernel could not resolve the FPGA's MAC: check `ip neigh show %u.%u.%u.%u` "
                   "on %s; the FPGA must answer ARP, or add a static entry (see README)",
                   p->dgid[12], p->dgid[13], p->dgid[14], p->dgid[15], d->netdev);
        return -1;
    }
    return 0;
}

int vqp_to_rts(struct vqp *q, const struct qp_params *p)
{
    struct ibv_qp_attr a;
    memset(&a, 0, sizeof(a));
    a.qp_state = IBV_QPS_RTS;
    a.sq_psn = p->sq_psn;
    int mask = IBV_QP_STATE | IBV_QP_SQ_PSN;
    if (p->type == IBV_QPT_RC) {
        a.timeout = p->timeout;
        a.retry_cnt = p->retry_cnt;
        a.rnr_retry = p->rnr_retry;
        a.max_rd_atomic = p->max_rd_atomic;
        mask |= IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY | IBV_QP_MAX_QP_RD_ATOMIC;
    }
    if (p->migreq >= 0) {
        a.path_mig_state = (enum ibv_mig_state)p->migreq;
        mask |= IBV_QP_PATH_MIG_STATE;
    }
    int rc = ibv_modify_qp(q->qp, &a, mask);
    if (rc)
        logerr("QP to RTS: %s", strerror(rc));
    return rc ? -1 : 0;
}

void vqp_print_state(struct vqp *q, const char *when)
{
    struct ibv_qp_attr a;
    struct ibv_qp_init_attr ia;
    if (!q->qp)
        return;
    if (ibv_query_qp(q->qp, &a, IBV_QP_STATE | IBV_QP_CUR_STATE | IBV_QP_PATH_MTU | IBV_QP_RQ_PSN |
                                    IBV_QP_SQ_PSN | IBV_QP_DEST_QPN | IBV_QP_RETRY_CNT |
                                    IBV_QP_RNR_RETRY | IBV_QP_MAX_QP_RD_ATOMIC |
                                    IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_TIMEOUT,
                     &ia)) {
        logmsg("ibv_query_qp (%s): %s", when, strerror(errno));
        return;
    }
    logmsg("QP 0x%06x %s: state %s, path_mtu %u, sq_psn 0x%06x rq_psn 0x%06x, dest_qp 0x%06x, "
           "retry %u rnr_retry %u timeout %u, rd_atomic %u/%u (cached values, see README)",
           q->qp->qp_num, when, qp_state_str(a.qp_state), mtu_from_ibv(a.path_mtu), a.sq_psn,
           a.rq_psn, a.dest_qp_num, a.retry_cnt, a.rnr_retry, a.timeout, a.max_rd_atomic,
           a.max_dest_rd_atomic);
}

int neigh_lookup(const char *netdev, const uint8_t ip[4], uint8_t mac[6], char *flags, size_t fl)
{
    FILE *f = fopen("/proc/net/arp", "r");
    char line[256], ips[20];
    if (!f)
        return -1;
    ip4_str(ip, ips, sizeof(ips));
    if (!fgets(line, sizeof(line), f)) {     /* header */
        fclose(f);
        return 0;
    }
    int found = 0;
    while (fgets(line, sizeof(line), f)) {
        char aip[64], hw[64], fls[64], hwa[64], mask[64], dev[64];
        if (sscanf(line, "%63s %63s %63s %63s %63s %63s", aip, hw, fls, hwa, mask, dev) != 6)
            continue;
        if (strcmp(aip, ips) || strcmp(dev, netdev))
            continue;
        unsigned long flg = strtoul(fls, NULL, 16);
        snprintf(flags, fl, "%s%s", (flg & 0x2) ? "complete" : "incomplete",
                 (flg & 0x4) ? ",permanent" : "");
        unsigned v[6];
        if ((flg & 0x2) && sscanf(hwa, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4],
                                  &v[5]) == 6) {
            for (int i = 0; i < 6; i++)
                mac[i] = (uint8_t)v[i];
            found = 1;
        }
        break;
    }
    fclose(f);
    return found;
}
