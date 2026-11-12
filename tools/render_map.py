#!/usr/bin/env python3
"""Render assets/road.json as a high-resolution PNG coloured by speed limit.

Usage (needs matplotlib):
  python3 tools/render_map.py            # docs/speed_zones.png (mountain roads)
  python3 tools/render_map.py --ruta41   # docs/speed_zones_ruta41.png (+ airport to gate)
"""
import json
import math
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import ConnectionPatch, Rectangle

ROOT = Path(__file__).resolve().parent.parent
RUTA41 = "--ruta41" in sys.argv
OUT = ROOT / "docs" / ("speed_zones_ruta41.png" if RUTA41 else "speed_zones.png")

COLORS = {20: "#7b2cbf", 30: "#d7191c", 40: "#f28e00", 50: "#f2d300", 60: "#8fd14f", 70: "#1a7a2e",
          80: "#17a5c8", 100: "#1f4fbf"}
REF_LAT = math.radians(-30.15)
M_PER_DEG = 111_320.0
# name -> (lat, lon, label offset in points)
PLACES = {
    "Control Puerta (gate)": (-30.0462381, -70.8193721, (-14, 10)),
    "El Quisco (split)": (-30.195868, -70.779942, (14, 12)),
    "Cerro Tololo (CTIO)": (-30.1696927, -70.8064637, (14, 12)),
    "Gemini South": (-30.2407, -70.7366, (-14, 16)),
    "SOAR": (-30.2380723, -70.7337158, (-14, 10)),
    "Rubin Observatory": (-30.2446535, -70.7493386, (0, 22)),
}
if RUTA41:
    PLACES["La Serena airport"] = (-29.9162, -71.1995, (-14, 12))
# (title, lat_min, lon_min, lat_max, lon_max)
INSETS = [
    ("El Quisco split", -30.2045, -70.7905, -30.1885, -70.7700),
    ("Pachón summit: Rubin, Gemini South, SOAR", -30.2585, -70.7640, -30.2340, -70.7310),
]


def xy(lat, lon):
    return lon * M_PER_DEG * math.cos(REF_LAT) / 1000, lat * M_PER_DEG / 1000


def branch_geometry(branch):
    pts = [xy(*p) for p in branch["points"]]
    cum = [0.0]
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        cum.append(cum[-1] + math.hypot(bx - ax, by - ay) * 1000)
    return pts, cum


def point_at(pts, cum, d):
    for i in range(len(cum) - 1):
        if cum[i + 1] >= d:
            t = 0 if cum[i + 1] == cum[i] else (d - cum[i]) / (cum[i + 1] - cum[i])
            return (pts[i][0] + t * (pts[i + 1][0] - pts[i][0]), pts[i][1] + t * (pts[i + 1][1] - pts[i][1]))
    return pts[-1]


def segments(branch):
    """Yield (xs, ys, limit) for each zone, cut exactly at zone boundaries."""
    pts, cum = branch_geometry(branch)
    zones = branch["zones"] + [[cum[-1], None]]
    for (start, limit), (end, _) in zip(zones, zones[1:]):
        end = min(end, cum[-1])
        if end <= start:
            continue
        piece = [point_at(pts, cum, start)]
        piece += [p for p, c in zip(pts, cum) if start < c < end]
        piece.append(point_at(pts, cum, end))
        xs, ys = zip(*piece)
        yield xs, ys, int(limit)


def draw_roads(ax, road, lw):
    for b in road["branches"]:
        for xs, ys, limit in segments(b):
            ax.plot(xs, ys, color="#333333", lw=lw + 2, solid_capstyle="round", zorder=1)
        for xs, ys, limit in segments(b):
            ax.plot(xs, ys, color=COLORS.get(limit, "#888888"), lw=lw, solid_capstyle="butt", zorder=2)


def inside(p, rect):
    return rect[0] <= p[0] <= rect[2] and rect[1] <= p[1] <= rect[3]


def draw_zone_labels(ax, road, size, clip=None, exclude=()):
    seen = []  # (point, side)
    x0, x1 = ax.get_xlim()
    span = (clip[2] - clip[0]) if clip else (x1 - x0)
    for b in road["branches"]:
        pts, cum = branch_geometry(b)
        for (start, limit), name in zip(b["zones"], b["zone_names"]):
            p = point_at(pts, cum, start)
            if (clip and not inside(p, clip)) or any(inside(p, r) for r in exclude):
                continue
            if any(math.hypot(p[0] - q[0], p[1] - q[1]) < 0.01 for q, _ in seen):
                continue
            # Put the label on the other side from any nearby label.
            near = [s for q, s in seen if math.hypot(p[0] - q[0], p[1] - q[1]) < span * 0.1]
            side = -near[-1] if near else 1
            seen.append((p, side))
            label = (name.replace("Zone ", "Z") if name.startswith("Zone")
                     else "OSM" if name.startswith("OSM") else "Rubin")
            ax.plot(*p, marker="|", ms=size * 1.6, mew=1.5, color="black", zorder=3)
            ax.annotate(f"{label} · {limit:.0f}", p, xytext=(8 * side, 0), textcoords="offset points",
                        fontsize=size, va="center", ha="left" if side > 0 else "right", zorder=4, annotation_clip=True,
                        bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="#999999", lw=0.4, alpha=0.9))


def draw_places(ax, size, clip=None, offsets=None):
    for name, (lat, lon, (dx, dy)) in PLACES.items():
        dx, dy = (offsets or {}).get(name, (dx, dy))
        if dx is None:
            continue
        x, y = xy(lat, lon)
        if clip and not (clip[0] <= x <= clip[2] and clip[1] <= y <= clip[3]):
            continue
        ax.plot(x, y, marker="o", ms=size * 0.8, mfc="white", mec="black", mew=1.5, zorder=5)
        ax.annotate(name, (x, y), xytext=(dx, dy), textcoords="offset points",
                    ha="center" if dx == 0 else "right" if dx < 0 else "left", fontsize=size, fontweight="bold", zorder=6,
                    bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="black", lw=0.8))


def style(ax):
    ax.set_facecolor("#f4f1ea")
    ax.set_aspect("equal")
    ax.set_xticks([])
    ax.set_yticks([])


def main():
    road = json.loads((ROOT / "assets" / "road.json").read_text())
    road["branches"] = [b for b in road["branches"] if RUTA41 or "optional" not in b]
    # Only show colours that are used.
    used = {int(z[1]) for b in road["branches"] for z in b["zones"]}
    fig = plt.figure(figsize=(23, 14) if RUTA41 else (17, 14), dpi=300)
    gs = fig.add_gridspec(2, 2, width_ratios=[1.8 if RUTA41 else 1.15, 1], wspace=0.04, hspace=0.12)
    ax = fig.add_subplot(gs[:, 0])
    style(ax)
    draw_roads(ax, road, lw=4.5)
    ax.margins(0.07)
    ax.autoscale_view()
    x0, x1 = ax.get_xlim()
    ax.set_xlim(x0, x1 + (5.5 if RUTA41 else 3.5))  # room for the Gemini South label
    rects = [(*xy(a, b), *xy(c, d)) for _, a, b, c, d in INSETS]
    draw_zone_labels(ax, road, size=7, exclude=rects)
    draw_places(ax, size=11, offsets={"Gemini South": (14, 10), "SOAR": (None, None), "Rubin Observatory": (-14, -26)})

    for row, (title, lat0, lon0, lat1, lon1) in enumerate(INSETS):
        ins = fig.add_subplot(gs[row, 1])
        style(ins)
        (x0, y0), (x1, y1) = xy(lat0, lon0), xy(lat1, lon1)
        draw_roads(ins, road, lw=7)
        draw_zone_labels(ins, road, size=10, clip=(x0, y0, x1, y1))
        draw_places(ins, size=11, clip=(x0, y0, x1, y1))
        ins.set_xlim(x0, x1)
        ins.set_ylim(y0, y1)
        ins.set_title(title, fontsize=13)
        ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, ec="#444444", lw=1.2, ls="--", zorder=7))
        for cx, cy in [((x1, y1), (0, 1)), ((x1, y0), (0, 0))]:
            fig.add_artist(ConnectionPatch(cx, cy, coordsA="data", coordsB="axes fraction",
                                           axesA=ax, axesB=ins, color="#888888", lw=0.8))

    handles = [Line2D([], [], color=c, lw=7, label=f"{k} km/h") for k, c in COLORS.items() if k in used]
    ax.legend(handles=handles, loc="lower left", fontsize=13, framealpha=0.95, title="Speed limit",
              title_fontsize=13)
    x0, x1 = ax.get_xlim()
    y0, y1 = ax.get_ylim()
    sx, sy = x0 + (x1 - x0) * 0.05, y0 + (y1 - y0) * (0.45 if RUTA41 else 0.30)
    ax.plot([sx, sx + 5], [sy, sy], color="black", lw=3)
    ax.text(sx + 2.5, sy + 0.25, "5 km", ha="center", fontsize=12)
    ax.annotate("N", xy=(x1 - (x1 - x0) * 0.06, y1 - (y1 - y0) * 0.03), xytext=(0, -45),
                textcoords="offset points", ha="center", fontsize=15, fontweight="bold",
                arrowprops=dict(arrowstyle="-|>", lw=2, color="black"))
    if RUTA41:
        fig.text(0.5, 0.985, "Speed alarm starts at Control Puerta unless /sdcard/MountainRoads/ruta41.txt exists. "
                 "Then, speed alarm starts at the airport.", ha="center", fontsize=15, fontweight="bold",
                 color="#b00000")
        fig.suptitle("AURA road speed zones: La Serena airport (Ruta 41) to Cerro Tololo and Cerro Pachón",
                     fontsize=18, y=0.955)
        fig.text(0.5, 0.925, "Ruta 41 zones (ZA–ZM) and mountain zones (Z#) from Report_GPS_RUBIN_08_2020"
                 " · Rubin spur 20 km/h", ha="center", fontsize=11, color="#444444")
    else:
        fig.suptitle("AURA road speed zones: Control Puerta to Cerro Tololo and Cerro Pachón", fontsize=18, y=0.95)
        fig.text(0.5, 0.915, "Zones (Z#) and limits from Report_GPS_RUBIN_08_2020 · Rubin spur 20 km/h from the "
                 "Gemini/SOAR split · zone starts placed by km, about ±100 m", ha="center", fontsize=11, color="#444444")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT, dpi=300, bbox_inches="tight", facecolor="white")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
