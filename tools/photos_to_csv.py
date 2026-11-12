#!/usr/bin/env python3
"""Read GPS positions from speed-limit sign photos into a CSV to fill in.

Usage:
  pip install pillow
  python3 tools/photos_to_csv.py ~/Pictures/speed_signs > tools/data/speed_limits.csv

Writes lat,lon,limit_kmh,note with limit_kmh empty and the photo name in
note. Open the CSV, type the limit shown in each photo, then run
build_road_data.py. Photos without GPS data are listed on stderr.
"""
import csv
import sys
from pathlib import Path

from PIL import Image
from PIL.ExifTags import GPSTAGS, IFD


def dms_to_deg(dms, ref):
    deg = float(dms[0]) + float(dms[1]) / 60 + float(dms[2]) / 3600
    return -deg if ref in ("S", "W") else deg


def gps_of(path):
    with Image.open(path) as im:
        gps = im.getexif().get_ifd(IFD.GPSInfo)
    g = {GPSTAGS.get(k, k): v for k, v in gps.items()}
    if "GPSLatitude" not in g:
        return None
    return (
        dms_to_deg(g["GPSLatitude"], g["GPSLatitudeRef"]),
        dms_to_deg(g["GPSLongitude"], g["GPSLongitudeRef"]),
        str(g.get("GPSDateStamp", "")),
    )


def main():
    folder = Path(sys.argv[1]).expanduser()
    out = csv.writer(sys.stdout)
    out.writerow(["lat", "lon", "limit_kmh", "note"])
    rows = []
    for p in sorted(folder.iterdir()):
        if p.suffix.lower() not in (".jpg", ".jpeg", ".heic", ".png", ".tif", ".tiff"):
            continue
        try:
            g = gps_of(p)
        except Exception as e:  # unreadable format (e.g. HEIC without pillow-heif)
            print(f"cannot read {p.name}: {e}", file=sys.stderr)
            continue
        if g is None:
            print(f"no GPS: {p.name}", file=sys.stderr)
            continue
        rows.append([f"{g[0]:.6f}", f"{g[1]:.6f}", "", p.name])
    out.writerows(rows)
    print(f"{len(rows)} photos with GPS", file=sys.stderr)


if __name__ == "__main__":
    main()
