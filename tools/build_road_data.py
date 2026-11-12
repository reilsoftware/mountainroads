#!/usr/bin/env python3
"""Build assets/road.json: the mountain road geometry plus speed-limit zones.

Inputs (in tools/data/):
  route_<branch>.json   OSRM route responses, gate -> summit (--fetch re-downloads).
  zones.csv             zone,branch,start_km,lat,lon,limit_kmh,note
                        One row per zone start. Give either start_km (distance
                        from Control Puerta as in the 2020 GPS report) or
                        lat,lon (e.g. from a sign photo). branch is one of
                        all / tololo / pachon / rubin.

Usage:
  python3 tools/build_road_data.py            # build from existing data
  python3 tools/build_road_data.py --fetch    # re-download routes first
"""
import csv
import json
import math
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "tools" / "data"
OUT = ROOT / "assets" / "road.json"

GATE = (-30.0462381, -70.8193721)  # Control Puerta AURA
# name -> (summit, zone groups from general to specific)
BRANCHES = {
    "Tololo": ((-30.1696927, -70.8064637), ["all", "tololo"]),
    "Gemini": ((-30.2407, -70.7366), ["all", "pachon"]),
    "Rubin": ((-30.2446535, -70.7493386), ["all", "pachon", "rubin"]),
    # Airport to the gate; only used when /sdcard/MountainRoads/ruta41.txt exists.
    "Ruta41": ((-30.0462381, -70.8193721), ["ruta41"]),
}
AIRPORT = (-29.9162, -71.1995)  # La Serena La Florida airport
# Branches the app only loads when a switch file is present.
OPTIONAL = {"Ruta41": "ruta41"}
# In the report, El Quisco (the Tololo / Pachón split) lies between the
# starts of zone 13 (27.4 km) and zone 14 (27.6 km). Report km are scaled
# so the split lands where it is on the mapped road.
SPLIT_REPORT_KM = 27.5
SPLIT = (-30.195868, -70.779942)
# Zone starts from km are only accurate to ~100 m, so near each change the
# lower of the two limits is used for this distance either side.
TRANSITION_BUFFER_M = 100.0
REF_LAT = math.radians(-30.15)
M_PER_DEG = 111_320.0


def to_xy(lat, lon):
    return lon * M_PER_DEG * math.cos(REF_LAT), lat * M_PER_DEG


def fetch_route(name, summit):
    start = AIRPORT if name == "Ruta41" else GATE
    url = (
        "https://router.project-osrm.org/route/v1/driving/"
        f"{start[1]},{start[0]};{summit[1]},{summit[0]}"
        "?overview=full&geometries=geojson"
    )
    with urllib.request.urlopen(url, timeout=60) as r:
        (DATA / f"route_{name.lower()}.json").write_bytes(r.read())


def load_branch(name):
    if name == "Rubin":
        return rubin_branch()
    d = json.loads((DATA / f"route_{name.lower()}.json").read_text())
    # GeoJSON is [lon, lat]; store [lat, lon] rounded to ~10 cm.
    pts = [[round(lat, 6), round(lon, 6)] for lon, lat in d["routes"][0]["geometry"]["coordinates"]]
    if name == "Gemini":
        # The route stops at Gemini South; the road continues up to SOAR.
        pts += [[round(a, 6), round(b, 6)] for a, b in json.loads((DATA / "soar_road.json").read_text())["points"]]
    return pts


def rubin_branch():
    """Gemini road up to the Rubin turn-off, then the Rubin access road.

    Routers skip the access road (tagged private) and take the old, closed
    road instead, so the branch is assembled from rubin_access_road.json.
    """
    gemini = load_branch("Gemini")
    access = json.loads((DATA / "rubin_access_road.json").read_text())["points"]
    jx, jy = to_xy(*access[0])
    i = min(range(len(gemini)), key=lambda k: math.dist(to_xy(*gemini[k]), (jx, jy)))
    return gemini[: i + 1] + [[round(a, 6), round(b, 6)] for a, b in access]


def project(points, lat, lon):
    """Return (distance_from_road_m, distance_along_road_m)."""
    px, py = to_xy(lat, lon)
    best = (math.inf, 0.0)
    along = 0.0
    for (alat, alon), (blat, blon) in zip(points, points[1:]):
        ax, ay = to_xy(alat, alon)
        bx, by = to_xy(blat, blon)
        dx, dy = bx - ax, by - ay
        seg = math.hypot(dx, dy)
        t = 0.0 if seg == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / seg**2))
        d = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
        if d < best[0]:
            best = (d, along + t * seg)
        along += seg
    return best


def load_zones():
    with (DATA / "zones.csv").open(newline="") as f:
        return list(csv.DictReader(f))


def place_zones(pts, groups, rows, km_scale, split_m):
    """[(start_m, limit, zone_name, exact)] for one branch, before buffering.

    exact is True for zones placed by lat,lon (branch splits, sign photos);
    those starts are not moved by the transition buffer.
    """
    placed = []  # (start_m, group_rank, limit, name, exact)
    for row in rows:
        if row["branch"] not in groups:
            continue
        rank = groups.index(row["branch"])
        if row["start_km"]:
            # Ruta 41 km are along its own route; report km need scaling.
            scale = 1.0 if row["branch"] == "ruta41" else km_scale
            start = float(row["start_km"]) * 1000 * scale
            if rank > 0:
                # Zones past El Quisco never start on the shared road.
                start = max(start, split_m)
            exact = False
        else:
            off, start = project(pts, float(row["lat"]), float(row["lon"]))
            if off > 50:
                sys.exit(f"{row['zone']} is {off:.0f} m from the road")
            exact = True
        placed.append((start, rank, float(row["limit_kmh"]), row["zone"], exact))
    # A zone from a more specific group (e.g. the Rubin spur) replaces the
    # general zones that would start after it.
    result = []
    cutoff = {}
    for start, rank, _, _, _ in placed:
        if rank > 0:
            cutoff[rank] = min(cutoff.get(rank, math.inf), start)
    for start, rank, limit, name, exact in sorted(placed):
        if any(r > rank and start > c for r, c in cutoff.items()):
            continue
        result.append((round(start, 1), limit, name, exact or start == split_m))
    return result


def buffer_zones(zones):
    """Extend the lower limit TRANSITION_BUFFER_M across each change."""
    out = [list(zones[0][:3])]
    for start, limit, name, exact in zones[1:]:
        prev = out[-1][1]
        if limit == prev:
            continue
        if not exact:
            start = start - TRANSITION_BUFFER_M if limit < prev else start + TRANSITION_BUFFER_M
        start = max(start, out[-1][0])
        if start == out[-1][0] and len(out) > 1:
            # Previous zone squeezed to nothing: keep the lower limit.
            if limit < out[-1][1]:
                out[-1] = [start, limit, name]
            continue
        out.append([round(start, 1), limit, name])
    return [z for i, z in enumerate(out) if i == 0 or z[1] != out[i - 1][1]]


def main():
    if "--fetch" in sys.argv:
        for name, (summit, _) in BRANCHES.items():
            if name != "Rubin":
                fetch_route(name, summit)

    rows = load_zones()
    tololo = load_branch("Tololo")
    _, split_m = project(tololo, *SPLIT)
    km_scale = split_m / (SPLIT_REPORT_KM * 1000)
    print(f"split at {split_m / 1000:.2f} km on the map; report km x {km_scale:.4f}")

    branches = []
    for name, (_, groups) in BRANCHES.items():
        pts = load_branch(name)
        zones = place_zones(pts, groups, rows, km_scale, split_m)
        buffered = buffer_zones(zones)
        branches.append({
            "name": name,
            **({"optional": OPTIONAL[name]} if name in OPTIONAL else {}),
            "points": pts,
            "zones": [[s, l] for s, l, _ in buffered],
            "zone_names": [n for _, _, n in buffered],
        })
        print(f"{name}: {len(pts)} points, {len(buffered)} zones: "
              + " ".join(f"{n}@{s / 1000:.2f}={l:.0f}" for s, l, n in buffered))

    OUT.write_text(json.dumps({"placeholder_limits": False, "branches": branches}, separators=(",", ":")))
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
