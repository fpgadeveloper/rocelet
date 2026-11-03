/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * rl_verbs.h - libibverbs helpers of rocelet_host (device, port, GID, RC/UC QP).
 */
#ifndef RL_VERBS_H_
#define RL_VERBS_H_

#include <infiniband/verbs.h>
#include <net/if.h>
#include <stdint.h>

struct vdev {
    char                 name[64];
    uint8_t              port;
    int                  gid_index;
    struct ibv_context  *ctx;
    struct ibv_pd       *pd;
    struct ibv_device_attr dattr;
    struct ibv_port_attr pattr;
    uint8_t              gid[16];
    uint8_t              ipv4[4];
    uint8_t              mac[6];
    char                 netdev[IF_NAMESIZE];
    int                  netdev_mtu;
};

struct qp_params {
    enum ibv_qp_type type;     /* IBV_QPT_RC or IBV_QPT_UC */
    uint32_t mtu;              /* path MTU, bytes */
    uint32_t dest_qpn;
    uint32_t rq_psn;           /* = the FPGA's first send PSN */
    uint32_t sq_psn;           /* = the host's first send PSN */
    uint8_t  dgid[16];         /* ::ffff:<fpga ip> */
    uint8_t  traffic_class;
    uint8_t  hop_limit;
    uint8_t  timeout;          /* 4.096 us * 2^timeout (some drivers ignore it) */
    uint8_t  retry_cnt;
    uint8_t  rnr_retry;
    uint8_t  min_rnr_timer;
    uint8_t  max_rd_atomic;    /* host READs outstanding (<= FPGA READ depth) */
    uint8_t  max_dest_rd_atomic;
    int      migreq;           /* -1 = leave unset, else enum ibv_mig_state */
    int      access;           /* IBV_ACCESS_* granted to the peer */
};

enum ibv_mtu mtu_to_ibv(uint32_t bytes);
uint32_t mtu_from_ibv(enum ibv_mtu m);
int is_ipv4_mapped(const uint8_t g[16]);
const char *gid_str(const uint8_t g[16], char *s, size_t n);

/* Open dev/port; gid_index < 0 = pick the RoCE v2 IPv4-mapped GID of the
 * port's netdev (local_ip, if non-NULL, selects among several). need_active:
 * fail if the port is not ACTIVE. Returns 0 or an EX_* code. */
int vdev_open(struct vdev *d, const char *name, int port, int gid_index,
              const uint8_t *local_ip, int need_active, int alloc_pd);
void vdev_close(struct vdev *d);
int vdev_print_info(const char *name, int port);

/* Name of the first RDMA device present (the --dev default) into buf; 0, or -1 with
 * an error logged when none is present or the list cannot be read. */
int vdev_first(char *buf, size_t n);

/* QP with separate send/recv CQs. */
struct vqp {
    struct ibv_cq *scq, *rcq;
    struct ibv_qp *qp;
};
int vqp_create(struct vdev *d, struct vqp *q, enum ibv_qp_type type, uint32_t max_send_wr,
               uint32_t max_recv_wr);
void vqp_destroy(struct vqp *q);
int vqp_to_init(struct vqp *q, uint8_t port, int access);
int vqp_to_rtr(struct vqp *q, const struct vdev *d, const struct qp_params *p);
int vqp_to_rts(struct vqp *q, const struct qp_params *p);
void vqp_print_state(struct vqp *q, const char *when);
const char *qp_state_str(enum ibv_qp_state s);

/* Kernel neighbour entry for ip on netdev: 1 = complete (mac filled),
 * 0 = absent/incomplete, -1 = cannot read /proc/net/arp. */
int neigh_lookup(const char *netdev, const uint8_t ip[4], uint8_t mac[6], char *flags, size_t fl);

#endif
