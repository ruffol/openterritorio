#!/usr/bin/env python3
"""Descarga el mapa offline de TODO el estado de Colima como pirámide de teselas.

Fuente: Esri ArcGIS Online "Dark Gray Canvas" (sin clave, requiere atribución).
Salida: app/assets/tiles/colima_<z>_<x>_<y>.jpg  (plano, una sola carpeta para
que `flutter: assets: - assets/tiles/` las incluya todas).

Uso: python tools/fetch-tiles.py [--workers 6] [--force]
"""

import argparse
import math
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

UA = "Mozilla/5.0 (Linux; Android 14; Q524) openterritorio/0.3.0 (+https://github.com/ruffol/openterritorio)"
URL = "https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}"
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app", "assets", "tiles")

# Estado de Colima completo (incluye costa, volcán y los 10 municipios).
STATE = dict(west=-104.72, east=-103.44, south=18.64, north=19.62)

# Parches de detalle fino (z16) en las zonas urbanas.
PATCHES = [
    ("colima", dict(west=-103.79, east=-103.66, south=19.19, north=19.29)),
    ("villa", dict(west=-103.80, east=-103.70, south=19.24, north=19.30)),
    ("manzanillo", dict(west=-104.36, east=-104.26, south=19.03, north=19.14)),
    ("tecoman", dict(west=-103.92, east=-103.83, south=18.88, north=18.97)),
    ("comala", dict(west=-103.79, east=-103.71, south=19.28, north=19.35)),
    ("armeria", dict(west=-104.00, east=-103.92, south=18.90, north=18.97)),
]

STATE_LEVELS = [10, 11, 12, 13, 14]
PATCH_LEVELS = [15, 16]


def lon2x(lon, z):
    return int((lon + 180.0) / 360.0 * (2 ** z))


def lat2y(lat, z):
    r = math.radians(lat)
    return int((1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0 * (2 ** z))


def tiles_for(box, z):
    x0, x1 = lon2x(box["west"], z), lon2x(box["east"], z)
    y0, y1 = lat2y(box["north"], z), lat2y(box["south"], z)
    for x in range(min(x0, x1), max(x0, x1) + 1):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            yield z, x, y


def plan():
    jobs = {}
    for z in STATE_LEVELS:
        for t in tiles_for(STATE, z):
            jobs[t] = "estado"
    for name, box in PATCHES:
        for z in PATCH_LEVELS:
            for t in tiles_for(box, z):
                jobs.setdefault(t, name)
    return jobs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    jobs = plan()
    todo = []
    for (z, x, y) in sorted(jobs):
        path = os.path.join(OUT, f"colima_{z}_{x}_{y}.jpg")
        if args.force or not os.path.exists(path):
            todo.append((z, x, y, path))

    print(f"teselas en el plan: {len(jobs)} | pendientes: {len(todo)}", flush=True)
    if not todo:
        return 0

    done = 0
    failed = 0
    total_bytes = 0

    def fetch(job):
        z, x, y, path = job
        req = urllib.request.Request(URL.format(z=z, y=y, x=x), headers={"User-Agent": UA})
        for intento in range(4):
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    data = r.read()
                if len(data) < 400:  # tesela de error
                    raise ValueError(f"tesela vacía ({len(data)} bytes)")
                with open(path, "wb") as f:
                    f.write(data)
                return len(data)
            except Exception as err:  # reintento con espera
                if intento == 3:
                    print(f"FALLO z{z}/{x}/{y}: {err}", flush=True)
                    return -1
                import time

                time.sleep(0.4 * (intento + 1))
        return -1

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for result in pool.map(fetch, todo):
            done += 1
            if result > 0:
                total_bytes += result
            else:
                failed += 1
            if done % 200 == 0:
                print(f"  {done}/{len(todo)}  {total_bytes / 1048576:.1f} MB", flush=True)

    files = [f for f in os.listdir(OUT) if f.endswith(".jpg")]
    disk = sum(os.path.getsize(os.path.join(OUT, f)) for f in files)
    print(f"\nlisto: {len(files)} teselas, {disk / 1048576:.1f} MB en {OUT} | fallos: {failed}", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
