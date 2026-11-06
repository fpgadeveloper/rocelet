#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""
Generate the diagrams for the rocelet docs.

    rocelet-block.png     rocelet_top: the MAC glue (rocelet_mac), the engine
                          (rocelet_core: RX path, TX path, responder, requester),
                          the AXI4 memory master (rocelet_axi_mem) and the register
                          file (rocelet_regs), with every external port
                          (rtl/rocelet_top.sv, rtl/mac/rocelet_mac.sv,
                          rtl/rocelet_core.sv; RTX_MODE "RING", the default)

Conventions shared with the Opsero reference-design diagrams
(fpga-drive-nvme-offload/docs/source/images/gen_block_diagram.py): same palette,
helpers and fonts, left-to-right layout with the MAC (100G CMAC, or a 40G / 10G MAC at
MAC_WIDTH 256 / 128 / 64) on the left and the
user ports on the right; lavender = soft logic, cream = hard blocks, blue arrows =
register access and configuration, green arrows = data into or out of memory
(m_axi), pale green arrows = AXI4-Stream, orange = the clock, dark-blue thin =
descriptors and commands, grey thin = sideband signals.

The PNGs are written next to this script (i.e. into docs/images/).

Usage (from anywhere):
    python3 docs/images/gen_block_diagram.py
"""

import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, FancyArrowPatch
from matplotlib.lines import Line2D

# ---- palette (shared with the other Opsero reference-design block diagrams) --
C_PS_FILL      = "#D9D9D9"; C_PS_EDGE      = "#7F7F7F"   # processor / DDR column
C_FAB_FILL     = "#F2F2F2"; C_FAB_EDGE     = "#BFBFBF"   # FPGA fabric container
C_MAC_FILL     = "#E8E8F2"; C_MAC_EDGE     = "#8C8CC0"   # soft logic (lavender)
C_GT_FILL      = "#F3EFE2"; C_GT_EDGE      = "#BFB585"   # hard blocks: PCIe, GT (cream)
C_FMC_FILL     = "#DCE6F2"; C_FMC_EDGE     = "#9DB7D4"   # external FMC (blue-grey)
C_SLOT_FILL    = "#FFFFFF"                                # M.2 slots (white on FMC)
C_CLK_FILL     = "#FDE9D9"; C_CLK_EDGE     = "#E0B090"   # clocking (peach)
C_CTRL_FILL    = "#ECECEC"; C_CTRL_EDGE    = "#BFBFBF"   # notes / control caption
C_AXARR_FILL   = "#EDF3D4"; C_AXARR_EDGE   = "#A6B85A"   # DMA arrows (pale green)
C_LINKARR_FILL = "#DAE8F5"; C_LINKARR_EDGE = "#6F9FCF"   # host access + link arrows
C_REFCLK_LINE  = "#C8823C"                                # clocks (orange)
C_THIN         = "#8C8C8C"                                # sideband / interrupts
C_MUTED        = "#6E6E6E"
TXT = "#1A1A1A"
# recorder additions (same family of tints)
C_USER_FILL    = "#E2F0E4"; C_USER_EDGE    = "#7FB08A"   # user insertion points
C_DATA_LINE    = "#6E8F1E"                                # zero-copy data path (dark green)
C_CTRL_LINE    = "#4A7DB5"                                # control path (dark blue)
C_WARN         = "#A0522D"                                # contract annotations



def box(ax, x, y, w, h, fc, ec, label, fs=10, lw=1.2, weight="normal",
        txtcolor=None, ls="-", z=2):
    ax.add_patch(plt.Rectangle((x, y), w, h, fc=fc, ec=ec, lw=lw, ls=ls,
                               zorder=z))
    if label:
        ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
                fontsize=fs, color=txtcolor or TXT, weight=weight,
                zorder=z + 1, linespacing=1.25)


def titled_box(ax, x, y, w, h, fc, ec, title, body, title_fs=9.5, body_fs=7.6,
               lw=1.2, txtcolor=None, title_dy=2.4, ls="-", z=2):
    """A box() with a bold title line at the top and a smaller body below it."""
    box(ax, x, y, w, h, fc, ec, "", lw=lw, ls=ls, z=z)
    cx = x + w / 2
    ax.text(cx, y + h - title_dy, title, ha="center", va="center",
            fontsize=title_fs, weight="bold", color=txtcolor or TXT, zorder=z + 1,
            linespacing=1.15)
    ax.text(cx, y + (h - title_dy * 1.9) / 2, body, ha="center", va="center",
            fontsize=body_fs, color=txtcolor or TXT, zorder=z + 1, linespacing=1.3)


def harrow(ax, x0, x1, yc, label, fc, ec, double=False, bh=1.1, hh=2.0,
           hl=1.6, fs=7.4, lw=1.0, lab_dy=2.9, lab_color=None, z=2):
    """Horizontal block arrow from x0 to x1 (head at x1; both ends if double)."""
    if double:
        lo, hi = min(x0, x1), max(x0, x1)
        pts = [(lo, yc), (lo + hl, yc + hh), (lo + hl, yc + bh),
               (hi - hl, yc + bh), (hi - hl, yc + hh), (hi, yc),
               (hi - hl, yc - hh), (hi - hl, yc - bh),
               (lo + hl, yc - bh), (lo + hl, yc - hh)]
    else:
        s = 1.0 if x1 >= x0 else -1.0
        neck = x1 - s * hl
        pts = [(x0, yc + bh), (neck, yc + bh), (neck, yc + hh),
               (x1, yc), (neck, yc - hh), (neck, yc - bh), (x0, yc - bh)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))
    if label:
        ax.text((x0 + x1) / 2, yc + lab_dy, label, ha="center", va="center",
                fontsize=fs, color=lab_color or TXT, zorder=z + 1, linespacing=1.15)


def vblock(ax, xc, y0, y1, fc, ec, bw=1.0, hw=1.9, hl=1.5, lw=1.0, double=True,
           z=2):
    """Vertical block arrow from y0 to y1 (head at y1; both ends if double)."""
    if double:
        lo, hi = min(y0, y1), max(y0, y1)
        pts = [(xc, lo), (xc + hw, lo + hl), (xc + bw, lo + hl),
               (xc + bw, hi - hl), (xc + hw, hi - hl), (xc, hi),
               (xc - hw, hi - hl), (xc - bw, hi - hl),
               (xc - bw, lo + hl), (xc - hw, lo + hl)]
    else:
        s = 1.0 if y1 >= y0 else -1.0
        neck = y1 - s * hl
        pts = [(xc + bw, y0), (xc + bw, neck), (xc + hw, neck), (xc, y1),
               (xc - hw, neck), (xc - bw, neck), (xc - bw, y0)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))


def route(ax, pts, color, lw=1.3, ls="-", z=3, ms=9):
    """Thin elbow arrow through the points in pts (head at the last point)."""
    xs, ys = zip(*pts[:-1])
    ax.add_line(Line2D(list(xs) + [pts[-2][0]], list(ys) + [pts[-2][1]],
                       color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt", solid_joinstyle="miter"))
    ax.add_patch(FancyArrowPatch(pts[-2], pts[-1], arrowstyle="-|>",
                                 mutation_scale=ms, lw=lw, color=color,
                                 zorder=z, shrinkA=0, shrinkB=0))


def line(ax, pts, color, lw=1.1, ls="-", z=3):
    xs, ys = zip(*pts)
    ax.add_line(Line2D(xs, ys, color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt"))


def clk_tag(ax, x, y, text, fs=7.2, ha="center"):
    """An orange clock-domain label."""
    ax.text(x, y, text, ha=ha, va="center", fontsize=fs, color=C_REFCLK_LINE,
            weight="bold", zorder=6, linespacing=1.15)



def new_fig(w=17.0, h=10.6, xmax=170, ymax=106):
    fig, ax = plt.subplots(figsize=(w, h), dpi=120)
    ax.set_xlim(0, xmax)
    ax.set_ylim(0, ymax)
    ax.axis("off")
    return fig, ax


def save(fig, name):
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    fig.savefig(out, bbox_inches="tight", pad_inches=0.15, facecolor="white")
    plt.close(fig)
    print("wrote", out)



DPI = 150          # the axes are 0.775 x 18 in wide: about 2100 px
GRP_EDGE = "#B4B4D2"                                      # dashed sub-group outline (lighter lavender)


def ptext(ax, x, y, text, ha="left", fs=7.0, color=TXT, weight="normal",
          rot=0, va="center", style="normal"):
    """Plain text label."""
    ax.text(x, y, text, ha=ha, va=va, fontsize=fs, color=color, weight=weight,
            rotation=rot, zorder=6, linespacing=1.2, style=style)


def group(ax, x0, y0, x1, y1, label, lx=None, ly=None):
    """Dashed sub-group outline inside rocelet_core with a small italic name."""
    ax.add_patch(plt.Rectangle((x0, y0), x1 - x0, y1 - y0, fc="none", ec=GRP_EDGE,
                               lw=1.0, ls=(0, (4, 2)), zorder=1.5))
    ptext(ax, x0 + 0.8 if lx is None else lx, y1 - 1.3 if ly is None else ly, label,
          fs=7.2, color=C_MUTED, style="italic")


def gap(ax, xc, yc, w=1.1, h=4.0):
    """White gap in a block arrow where a thin line passes over it (a bridge)."""
    ax.add_patch(plt.Rectangle((xc - w / 2, yc - h / 2), w, h, fc="white", ec="none",
                               zorder=2.6))


def port_in(ax, x_tip, y, x_out, name, fc, ec, lab_dy=1.9, bh=0.75, hh=1.45):
    """External input port: block arrow from outside (x_out) to x_tip, name outside."""
    harrow(ax, x_out, x_tip, y, "", fc, ec, bh=bh, hh=hh, hl=1.1)
    ptext(ax, PORT_X, y + lab_dy, name)


def port_out(ax, x_from, y, x_out, name, fc, ec, lab_dy=1.9, bh=0.75, hh=1.45,
             double=False):
    harrow(ax, x_from, x_out, y, "", fc, ec, bh=bh, hh=hh, hl=1.1, double=double)
    ptext(ax, PORT_X, y + lab_dy, name)


def legend(ax, x, y):
    """Arrow-colour key of the rocelet block diagram (two rows)."""
    col = [x, x + 50.0, x + 102.0]
    keys = [
        (0, 0, "block", C_USER_FILL, C_USER_EDGE, "AXI4-Stream (512 bit inside; MAC ports MAC_WIDTH bit)"),
        (1, 0, "block", C_AXARR_FILL, C_AXARR_EDGE, "memory data: m_axi (AXI4, 512 bit) and its paths"),
        (2, 0, "block", C_LINKARR_FILL, C_LINKARR_EDGE, "register access (AXI4-Lite) and configuration"),
        (0, 1, "line", C_CTRL_LINE, None, "descriptors and commands (WR, job, ACK / NAK, ...)"),
        (1, 1, "line", C_DATA_LINE, None, "WRITE payload and READ commands to axi_mem"),
        (2, 1, "line", C_THIN, None, "sideband (status, flow control, link_up, irq)"),
    ]
    for c, r, kind, a, b, text in keys:
        kx, ky = col[c], y - 3.4 * r
        if kind == "block":
            harrow(ax, kx, kx + 5.5, ky, "", a, b, bh=0.7, hh=1.3, hl=1.1)
        else:
            route(ax, [(kx, ky), (kx + 5.5, ky)], a, lw=1.3, ms=8)
        ptext(ax, kx + 7.0, ky, text)


PORT_X = 147.6     # left edge of the external port names (right of rocelet_top)
X_OUT = 163.0      # where the external port arrows end / start


def draw_block():
    fig, ax = new_fig(18.0, 14.0, 172, 134)
    matplotlib.rcParams["savefig.dpi"] = DPI

    yR, yT = 105.0, 52.0              # centre lines of the RX and TX rows
    ax.text(86.0, 130.5, "rocelet  —  RoCE v2 engine for one 100G / 40G / 10G port  (rocelet_top)",
            ha="center", va="center", fontsize=13.0, weight="bold", color=TXT)

    # ---- external: the CMAC -----------------------------------------------------
    titled_box(ax, 1.0, 30.0, 7.0, 82.0, C_GT_FILL, C_GT_EDGE, "MAC",
               "MAC_WIDTH\n\n100G\nCMAC\n(512 b)\n\nor 40G /\n10G MAC\n(256 /\n128 /\n64 b)", title_fs=8.6, body_fs=7.0,
               title_dy=2.4, lw=1.3)

    # ---- rocelet_top container --------------------------------------------------
    top_x0, top_x1, top_y0, top_y1 = 15.0, 146.0, 12.0, 121.0
    ax.add_patch(plt.Rectangle((top_x0, top_y0), top_x1 - top_x0, top_y1 - top_y0,
                               fc=C_FAB_FILL, ec=C_FAB_EDGE, lw=1.3, zorder=1))
    ptext(ax, top_x0 + 1.2, top_y1 - 1.9, "rocelet_top", fs=10.0, weight="bold")
    clk_tag(ax, 56.0, top_y1 - 1.9,
            "clk = MAC user clock (CMAC 322.27 MHz, 40G / 10G MAC 156.25 MHz):  one clock domain, no CDC",
            fs=7.4, ha="left")

    # ---- rocelet_mac -------------------------------------------------------------
    mac_x0, mac_x1, mac_y0, mac_y1 = 16.5, 57.5, 28.0, 117.0
    box(ax, mac_x0, mac_y0, mac_x1 - mac_x0, mac_y1 - mac_y0, "#FAFAFD", C_MAC_EDGE, "",
        lw=1.3, z=1.2)
    ptext(ax, mac_x0 + 1.2, mac_y1 - 1.7, "rocelet_mac", fs=8.8, weight="bold")

    # RX row
    titled_box(ax, 19.0, 98.0, 11.0, 14.0, C_MAC_FILL, C_MAC_EDGE, "rx_fifo",
               "32 KB, store-\nand-forward;\ndrops bad-FCS\nand overflow\nframes",
               title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 33.0, 99.5, 9.0, 11.0, C_MAC_FILL, C_MAC_EDGE, "vlan_strip",
               "VID-0\ntag\nremoved", title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 45.0, 99.5, 11.0, 11.0, C_MAC_FILL, C_MAC_EDGE, "rx_cls",
               "classifier:\nUDP 4791\n→ engine", title_fs=8.0, body_fs=7.0,
               title_dy=2.0, z=3)
    harrow(ax, 8.0, 19.0, yR, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.2)
    ptext(ax, 11.5, yR + 3.0, "s_axis_rx_*\n(width conv.)", ha="center")
    ptext(ax, 11.5, yR - 3.0, "no tready", ha="center", color=C_WARN)
    harrow(ax, 30.0, 33.0, yR, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0, z=4)
    harrow(ax, 42.0, 45.0, yR, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0, z=4)
    harrow(ax, 56.0, 61.0, yR, "RoCE", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0,
           lab_dy=2.6, z=4)
    # other traffic out (top border)
    vblock(ax, 52.5, 110.5, 125.0, C_USER_FILL, C_USER_EDGE, bw=0.75, hw=1.45, hl=1.1,
           double=False)
    ptext(ax, 54.4, 124.0, "m_axis_other   512 b  (non-RoCE frames to a CPU / NIC stack)")
    # ARP / ICMP responder
    vblock(ax, 48.5, 99.5, 93.0, C_USER_FILL, C_USER_EDGE, bw=0.75, hw=1.45, hl=1.0,
           double=False)
    ptext(ax, 47.6, 96.3, "ARP /\nICMP", ha="right")
    titled_box(ax, 44.0, 84.0, 12.0, 9.0, C_MAC_FILL, C_MAC_EDGE, "arp_icmp",
               "ARP + ICMP\necho replies", title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    vblock(ax, 50.0, 84.0, 77.5, C_USER_FILL, C_USER_EDGE, bw=0.75, hw=1.45, hl=1.0,
           double=False)
    titled_box(ax, 44.0, 70.0, 12.0, 7.5, C_MAC_FILL, C_MAC_EDGE, "pkt_fifo", "2 KB",
               title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    harrow(ax, 44.0, 30.0, 73.75, "replies", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5,
           hl=1.1, fs=7.0, lab_dy=2.5)
    # PAUSE
    titled_box(ax, 19.0, 84.0, 11.0, 9.0, C_MAC_FILL, C_MAC_EDGE, "pause",
               "PAUSE in → gate\nfill → XOFF/XON", title_fs=8.0, body_fs=7.0,
               title_dy=2.0, z=3)
    route(ax, [(24.5, 98.0), (24.5, 93.0)], C_THIN, lw=1.1, ms=7)
    ptext(ax, 25.2, 95.5, "fill", color=C_MUTED)
    route(ax, [(24.5, 84.0), (24.5, 78.0)], C_THIN, lw=1.1, ms=7)
    ptext(ax, 25.2, 81.0, "gate", color=C_MUTED)
    route(ax, [(8.0, 90.5), (19.0, 90.5)], C_THIN, lw=1.1, ms=7)
    ptext(ax, 12.3, 93.0, "mac_\npause_*", ha="center", color=C_MUTED)
    route(ax, [(19.0, 86.0), (8.0, 86.0)], C_THIN, lw=1.1, ms=7)
    ptext(ax, 12.3, 83.0, "mac_\npause_req", ha="center", color=C_MUTED)
    # TX arbiter
    titled_box(ax, 19.0, 30.0, 11.0, 48.0, C_MAC_FILL, C_MAC_EDGE, "mac_arb",
               "frame-atomic\narbiter\n\nfixed priority:\n1  ARP / ICMP\n2  other\n3  engine\n\n"
               "no new frame\nwhile a\nreceived\nPAUSE is in\nforce",
               title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    harrow(ax, 19.0, 8.0, yT, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.2)
    ptext(ax, 13.5, yT + 3.0, "m_axis_tx_*\n(width conv.)", ha="center")
    # engine TX into the MAC
    titled_box(ax, 45.0, 47.0, 11.0, 10.0, C_MAC_FILL, C_MAC_EDGE, "vlan_ins",
               "optional\ntag", title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 33.0, 47.0, 9.0, 10.0, C_MAC_FILL, C_MAC_EDGE, "pkt_fifo",
               "TX FIFO\n32 KB", title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    harrow(ax, 45.0, 42.0, yT, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0, z=4)
    harrow(ax, 33.0, 30.0, yT, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0, z=4)
    # other traffic in (bottom border)
    titled_box(ax, 33.0, 32.0, 11.0, 10.0, C_MAC_FILL, C_MAC_EDGE, "pkt_fifo",
               "other TX\n16 KB", title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    harrow(ax, 33.0, 30.0, 37.0, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0, z=4)
    vblock(ax, 38.5, 8.6, 32.0, C_USER_FILL, C_USER_EDGE, bw=0.75, hw=1.45, hl=1.1,
           double=False)
    ptext(ax, 40.4, 10.2, "s_axis_other   512 b  (frames to send)")

    # ---- rocelet_core --------------------------------------------------------------
    core_x0, core_x1, core_y0, core_y1 = 59.5, 144.5, 42.0, 117.0
    box(ax, core_x0, core_y0, core_x1 - core_x0, core_y1 - core_y0, "#FAFAFD",
        C_MAC_EDGE, "", lw=1.3, z=1.2)
    ptext(ax, core_x0 + 1.2, core_y1 - 1.7, "rocelet_core", fs=8.8, weight="bold")
    group(ax, 60.3, 97.0, 89.2, 114.6, "RX path")
    group(ax, 94.6, 60.0, 115.6, 114.6, "responder")
    group(ax, 117.0, 60.0, 144.0, 97.0, "requester")
    group(ax, 60.3, 44.0, 144.0, 59.0, "TX path", ly=60.3)

    # RX path
    titled_box(ax, 61.0, 99.5, 11.0, 11.0, C_MAC_FILL, C_MAC_EDGE, "icrc_rx",
               "ICRC check;\nverdict with\nthe last beat", title_fs=8.0, body_fs=7.0,
               title_dy=2.0, z=3)
    titled_box(ax, 75.0, 99.5, 13.0, 11.0, C_MAC_FILL, C_MAC_EDGE, "rx_parser",
               "IPv4 / UDP / BTH\nheader record,\npayload realigned", title_fs=8.0,
               body_fs=7.0, title_dy=2.0, z=3)
    harrow(ax, 72.0, 75.0, yR, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0, z=4)
    harrow(ax, 88.0, 96.0, yR, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0, z=4)

    # responder
    titled_box(ax, 96.0, 97.0, 19.0, 15.0, C_MAC_FILL, C_MAC_EDGE, "resp_rx",
               "RC responder: QP context,\nPSN / opcode sequence,\nlength, R_Key and\nwindow checks;\n"
               "commits on good ICRC", title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 96.0, 66.0, 16.0, 13.0, C_MAC_FILL, C_MAC_EDGE, "resp_tx",
               "response queue in\nPSN order: ACK /\nNAK packets, READ\nresponse packets",
               title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    route(ax, [(100.0, 97.0), (100.0, 79.0)], C_CTRL_LINE, lw=1.2, ms=8)
    ptext(ax, 100.7, 88.0, "ACK / NAK /\nRNR NAK /\nREAD jobs", color=C_CTRL_LINE)
    route(ax, [(110.5, 79.0), (110.5, 97.0)], C_THIN, lw=1.1, ms=7)
    ptext(ax, 111.1, 88.0, "READ\ndone", color=C_MUTED)
    route(ax, [(104.0, 66.0), (104.0, 57.0)], C_CTRL_LINE, lw=1.2, ms=8)
    ptext(ax, 104.7, 61.5, "desc", color=C_CTRL_LINE)
    # responder ports
    port_out(ax, 115.0, 110.0, X_OUT, "m_axis_send   512 b\n+ send_commit_*", C_USER_FILL,
             C_USER_EDGE, lab_dy=2.6)
    port_out(ax, 115.0, 104.5, X_OUT, "m_axis_rc   128 b", C_USER_FILL, C_USER_EDGE,
             lab_dy=1.8)
    route(ax, [(X_OUT, 101.4), (115.0, 101.4)], C_THIN, lw=1.1, ms=7)
    ptext(ax, PORT_X, 100.0, "send_rnr", color=C_MUTED)

    # WRITE payload and READ commands to the memory master (they pass over the TX path)
    route(ax, [(97.8, 97.0), (97.8, 94.0), (90.5, 94.0), (90.5, 34.0)], C_DATA_LINE,
          lw=1.4, ms=8)
    route(ax, [(96.0, 70.0), (92.6, 70.0), (92.6, 34.0)], C_DATA_LINE, lw=1.4, ms=8)
    ptext(ax, 89.6, 87.0, "WRITE payload,\none command per\npacket, cut-through", ha="right",
          color=C_DATA_LINE)
    ptext(ax, 89.6, 71.5, "memory reads for\nREAD responses", ha="right", color=C_DATA_LINE)

    # requester
    titled_box(ax, 119.0, 86.0, 24.5, 8.5, C_MAC_FILL, C_MAC_EDGE, "ack_proc",
               "window, ACK / NAK / RNR, timers,\nretry counters, QP error state",
               title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    route(ax, [(115.0, 99.0), (131.0, 99.0), (131.0, 94.5)], C_CTRL_LINE, lw=1.2, ms=8)
    ptext(ax, 131.7, 97.6, "received ACK / NAK", color=C_CTRL_LINE)
    route(ax, [(X_OUT, 90.0), (143.5, 90.0)], C_THIN, lw=1.1, ms=7)
    ptext(ax, PORT_X, 91.5, "link_up", color=C_MUTED)
    titled_box(ax, 119.0, 74.0, 13.0, 8.0, C_MAC_FILL, C_MAC_EDGE, "retx_desc",
               "outstanding WRs,\ngo-back-N re-issue", title_fs=8.0, body_fs=7.0,
               title_dy=2.0, z=3)
    route(ax, [(125.5, 86.0), (125.5, 82.0)], C_CTRL_LINE, lw=1.2, ms=7)
    ptext(ax, 126.2, 84.0, "rel / rtx", color=C_CTRL_LINE)
    port_out(ax, 132.0, 78.0, X_OUT, "m_axis_wc   64 b", C_USER_FILL, C_USER_EDGE)
    titled_box(ax, 119.0, 61.0, 11.5, 7.5, C_MAC_FILL, C_MAC_EDGE, "req_ctrl",
               "WR → packets,\nsend PSN", title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    route(ax, [(121.5, 68.5), (121.5, 74.0)], C_CTRL_LINE, lw=1.2, ms=7)
    ptext(ax, 120.9, 71.2, "trk", ha="right", color=C_CTRL_LINE)
    route(ax, [(128.5, 74.0), (128.5, 68.5)], C_CTRL_LINE, lw=1.2, ms=7)
    ptext(ax, 127.9, 71.2, "re-issue", ha="right", color=C_CTRL_LINE)
    route(ax, [(124.0, 61.0), (124.0, 57.0)], C_CTRL_LINE, lw=1.2, ms=8)
    ptext(ax, 124.7, 58.0, "desc", color=C_CTRL_LINE)
    route(ax, [(119.0, 64.5), (116.3, 64.5), (116.3, 90.0), (119.0, 90.0)], C_THIN,
          lw=1.1, ms=7)
    ptext(ax, 115.0, 73.0, "sent\nPSNs", ha="right", color=C_MUTED)
    titled_box(ax, 134.0, 60.0, 9.5, 13.0, C_MAC_FILL, C_MAC_EDGE, "retx_ring",
               "256 KB URAM\npayload ring\n= retransmit\nbuffer", title_fs=8.0,
               body_fs=7.0, title_dy=2.0, z=3)
    route(ax, [(134.0, 66.5), (130.5, 66.5)], C_CTRL_LINE, lw=1.2, ms=7)
    ptext(ax, 132.25, 68.0, "WR", ha="center", color=C_CTRL_LINE)
    route(ax, [(130.5, 63.0), (134.0, 63.0)], C_CTRL_LINE, lw=1.2, ms=7)
    ptext(ax, 132.25, 61.5, "rd", ha="center", color=C_CTRL_LINE)
    vblock(ax, 138.75, 60.0, 57.0, C_USER_FILL, C_USER_EDGE, bw=0.75, hw=1.45, hl=1.0,
           double=False)
    ptext(ax, 136.9, 58.0, "payload", ha="right")
    port_in(ax, 143.5, 68.5, X_OUT, "s_axis_wr   256 b  (WR)", C_USER_FILL, C_USER_EDGE)
    port_in(ax, 143.5, 63.0, X_OUT, "s_axis_wr_data   512 b", C_USER_FILL, C_USER_EDGE)

    # TX path
    titled_box(ax, 96.0, 47.0, 47.5, 10.0, C_MAC_FILL, C_MAC_EDGE, "tx_arb",
               "responses before requests;  descriptor and payload kept in step\n"
               "requester packets paced by a token bucket (PACE_RATE, PACE_BURST)",
               title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 75.0, 47.0, 13.0, 10.0, C_MAC_FILL, C_MAC_EDGE, "tx_builder",
               "Eth / IPv4 / UDP /\nBTH / RETH / AETH\n/ ImmDt headers", title_fs=8.0,
               body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 61.0, 47.0, 11.0, 10.0, C_MAC_FILL, C_MAC_EDGE, "icrc_tx",
               "ICRC\nappended", title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    harrow(ax, 96.0, 88.0, yT, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.1)
    gap(ax, 90.5, yT)
    gap(ax, 92.6, yT)
    harrow(ax, 75.0, 72.0, yT, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0, z=4)
    harrow(ax, 61.0, 56.0, yT, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0, z=4)

    # ---- rocelet_axi_mem ----------------------------------------------------------
    titled_box(ax, 89.5, 22.0, 25.0, 12.0, C_MAC_FILL, C_MAC_EDGE, "axi_mem",
               "AXI4 master, 512 bit\nwrite: WRITE payload\nread: READ response data",
               title_fs=8.0, body_fs=7.0, title_dy=2.0, z=3)
    vblock(ax, 108.0, 34.0, 47.0, C_AXARR_FILL, C_AXARR_EDGE, bw=0.8, hw=1.5, hl=1.1,
           double=False)
    ptext(ax, 110.0, 39.0, "READ response data", color=C_DATA_LINE)
    ptext(ax, 117.0, 34.6, 'RTX_MODE "RING" (default) shown.\n'
          '"REREAD": req_ctrl reads the payload\nthrough axi_mem;  "LOSSY": no ring.',
          color=C_MUTED)
    port_out(ax, 114.5, 28.0, X_OUT, "m_axi   AXI4, 512 b\n(FPGA memory)", C_AXARR_FILL,
             C_AXARR_EDGE, lab_dy=2.6, double=True)

    # ---- rocelet_regs -------------------------------------------------------------
    titled_box(ax, 63.0, 13.5, 24.5, 22.0, C_CTRL_FILL, C_CTRL_EDGE, "rocelet_regs",
               "AXI4-Lite register file:\nQP and window tables,\nCTRL, status, counters\n\n"
               "MAC status, FEC\nand PAUSE events in", title_fs=8.0, body_fs=7.0,
               title_dy=2.0, z=3)
    vblock(ax, 75.0, 35.5, 42.0, C_LINKARR_FILL, C_LINKARR_EDGE, bw=0.8, hw=1.5, hl=1.1)
    ptext(ax, 77.0, 38.8, "configuration / status", color=C_CTRL_LINE)
    harrow(ax, 63.0, 57.5, 31.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True,
           bh=0.8, hh=1.5, hl=1.1)
    port_in(ax, 87.5, 18.0, X_OUT, "s_axil   AXI4-Lite, 32 b", C_LINKARR_FILL,
            C_LINKARR_EDGE)
    route(ax, [(87.5, 14.6), (X_OUT, 14.6)], C_THIN, lw=1.1, ms=7)
    ptext(ax, PORT_X, 13.1, "irq", color=C_MUTED)

    legend(ax, 2.0, 5.2)
    save(fig, "rocelet-block.png")


def main():
    draw_block()


if __name__ == "__main__":
    main()
