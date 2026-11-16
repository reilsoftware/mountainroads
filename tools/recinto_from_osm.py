#!/usr/bin/env python3
"""Make tools/data/recinto.json: the AURA recinto roads in La Serena (Av. Juan
Cisternas 1500), 25 km/h, plus the other roads around them.

The recinto ways were picked by hand on a map (RECINTO_WAYS). The other
roads nearby (Av. Juan Cisternas, the ULS campus, ...) are kept as
"not ours": when one of them is nearest, the driver is not in the recinto.

  python3 tools/recinto_from_osm.py            # from tools/data/recinto_osm_map.json
  python3 tools/recinto_from_osm.py --fetch    # re-download that area first
"""
import json
import math
import sys
import urllib.request
from pathlib import Path

DATA = Path(__file__).resolve().parent / "data"
SRC = DATA / "recinto_osm_map.json"
OUT = DATA / "recinto.json"
BBOX = (-71.2480, -29.9200, -71.2370, -29.9115)  # lon/lat min, max
RECINTO_WAYS = {
    35822009, 301958757, 301958758, 301958767, 301958773, 301958775, 605017901, 605017902, 605017904,
    605017905, 605017918, 605017919, 605017920, 605017921, 605017927, 605017928, 605017949, 605017950,
    605017951, 605017957, 626965070, 626965071, 1059157237, 1059324673, 1331992844,
}
# Where a recinto road joins an outside road (e.g. the gate on Av. Juan
# Cisternas), its first metres are dropped so GPS jitter on the avenue is
# not taken for the recinto.
TRIM_M = 20
# Other roads count only this close to the recinto (keeps the data small).
NEAR_M = 150
SKIP = {"footway", "steps", "cycleway", "pedestrian", "path", "bridleway", "corridor", "proposed", "construction"}


def xy(p):
    return p[1] * 111_320 * math.cos(math.radians(-29.9)), p[0] * 111_320


def trim(pts):
    """Drop the first TRIM_M metres of a polyline."""
    left = TRIM_M
    for i in range(len(pts) - 1):
        seg = math.dist(xy(pts[i]), xy(pts[i + 1]))
        if seg > left:
            f = left / seg
            cut = (round(pts[i][0] + f * (pts[i + 1][0] - pts[i][0]), 6), round(pts[i][1] + f * (pts[i + 1][1] - pts[i][1]), 6))
            return [cut] + pts[i + 1 :]
        left -= seg
    return pts[-2:]  # shorter than TRIM_M: keep the last piece


def main():
    if "--fetch" in sys.argv:
        url = "https://api.openstreetmap.org/api/0.6/map.json?bbox=" + ",".join(map(str, BBOX))
        req = urllib.request.Request(url, headers={"User-Agent": "mountainroads-build"})
        SRC.write_bytes(urllib.request.urlopen(req, timeout=60).read())
    d = json.loads(SRC.read_text())
    nodes = {e["id"]: (round(e["lat"], 6), round(e["lon"], 6)) for e in d["elements"] if e["type"] == "node"}
    recinto, others = [], []
    for w in d["elements"]:
        hw = w.get("tags", {}).get("highway")
        if w["type"] != "way" or not hw:
            continue
        pts = [nodes[n] for n in w["nodes"] if n in nodes]
        if len(pts) < 2:
            continue
        if w["id"] in RECINTO_WAYS:
            recinto.append({"id": w["id"], "points": pts})
        elif hw not in SKIP:
            others.append({"id": w["id"], "name": w["tags"].get("name", hw), "points": pts})
    missing = RECINTO_WAYS - {r["id"] for r in recinto}
    if missing:
        sys.exit(f"recinto ways not in the OSM data: {missing}")
    trimmed = 0
    other_nodes = {p for o in others for p in o["points"]}
    for r in recinto:
        for end in (0, -1):
            if r["points"][end] in other_nodes:
                trimmed += 1
                r["points"] = trim(r["points"] if end == 0 else r["points"][::-1])
                if end == -1:
                    r["points"] = r["points"][::-1]
    rxy = [xy(p) for r in recinto for p in r["points"]]
    near = [o for o in others if min(math.dist(xy(p), q) for p in o["points"] for q in rxy) < NEAR_M]
    OUT.write_text(json.dumps({"limit_kmh": 25, "recinto": recinto, "others": near}, separators=(",", ":")))
    print(f"trimmed {trimmed} recinto road ends at outside roads")
    print(f"{len(recinto)} recinto ways, {len(near)} other roads nearby -> {OUT.name}")


if __name__ == "__main__":
    main()
