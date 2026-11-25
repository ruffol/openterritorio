#!/usr/bin/env python3
"""Descarga mapas offline de Colima como pirámide de teselas, por capas.

Capas:
  oscuro  Esri Dark Gray Canvas      (tiles {z}/{y}/{x})
  osm     OpenStreetMap estándar     (tiles {z}/{x}/{y})
  inegi   INEGI Mapa Digital v6.1    (WMS EPSG:3857, sin clave)

Salida: app/assets/tiles/<capa>/colima_<z>_<x>_<y>.jpg  (plano, ya en JPEG)

Uso:
  python tools/fetch-tiles.py --layer osm
  python tools/fetch-tiles.py --layer inegi --workers 4
"""

import argparse
import io
import math
import os
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from PIL import Image

UA = "openterritorio-offline-map/0.4.0 (+https://github.com/ruffol/openterritorio)"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TILES = os.path.join(ROOT, "app", "assets", "tiles")

STATE = dict(west=-104.72, east=-103.44, south=18.64, north=19.62)
PATCHES = [
    ("colima", dict(west=-103.79, east=-103.66, south=19.19, north=19.29)),
    ("villa", dict(west=-103.80, east=-103.70, south=19.24, north=19.30)),
    ("manzanillo", dict(west=-104.36, east=-104.26, south=19.03, north=19.14)),
    ("tecoman", dict(west=-103.92, east=-103.83, south=18.88, north=18.97)),
    ("comala", dict(west=-103.79, east=-103.71, south=19.28, north=19.35)),
    ("armeria", dict(west=-104.00, east=-103.92, south=18.90, north=18.97)),
]

ESRI = "https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}"
OSM = "https://tile.openstreetmap.de/{z}/{x}/{y}.png"
INEGI = "https://gaia.inegi.org.mx/NLB/tunnel/wms/wms61"

R = 6378137.0
WORLD = 2 * math.pi * R


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


def inegi_url(z, x, y):
    size = WORLD / (2 ** z)
    minx = -WORLD / 2 + x * size
    maxx = minx + size
    maxy = WORLD / 2 - y * size
    miny = maxy - size
    query = urllib.parse.urlencode(
        {
            "SERVICE": "WMS",
            "VERSION": "1.1.1",
            "REQUEST": "GetMap",
            "LAYERS": "Servicio_WMS_MDM61",
            "STYLES": "",
            "FORMAT": "image/png",
            "TRANSPARENT": "false",
            "SRS": "EPSG:3857",
            "BBOX": f"{minx:.2f},{miny:.2f},{maxx:.2f},{maxy:.2f}",
            "WIDTH": 256,
            "HEIGHT": 256,
        }
    )
    return f"{INEGI}?{query}"


def build_url(layer, z, x, y):
    if layer == "oscuro":
        return ESRI.format(z=z, x=x, y=y)
    if layer == "osm":
        return OSM.format(z=z, x=x, y=y)
    if layer == "inegi":
        return inegi_url(z, x, y)
    raise SystemExit(f"capa desconocida: {layer}")


def plan(layer):
    """El estado completo hasta z15; las ciudades, con detalle hasta z17."""
    jobs = {}
    if layer == "oscuro":
        state_levels = (10, 11, 12, 13, 14, 15)
    elif layer == "osm":
        state_levels = (10, 11, 12, 13, 14)
    else:
        state_levels = (10, 11, 12, 13)
    for z in state_levels:
        for t in tiles_for(STATE, z):
            jobs[t] = "estado"

    if layer == "oscuro":
        fine = ("colima", "villa")
        patch_levels = (16, 17)
        other_levels = (16,)
    elif layer == "osm":
        # OSM es la capa que queda en la app: el estado hasta z14 y detalle
        # z15-z17 en las ciudades (las teselas son pesadas, hay que medir).
        fine = ("colima", "villa")
        patch_levels = (15, 16)
        other_levels = (15,)
    else:  # inegi: ~5 s por tesela
        fine = ()
        patch_levels = (14,)
        other_levels = (14,)

    for name, box in PATCHES:
        levels = patch_levels if name in fine else other_levels
        if layer == "inegi" and name in ("comala", "armeria"):
            levels = ()
        for z in levels:
            for t in tiles_for(box, z):
                jobs.setdefault(t, name)
    return jobs


def fetch(job, layer, outdir):
    z, x, y, path = job
    url = build_url(layer, z, x, y)
    for intento in range(5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
            if b"Access blocked" in raw or b"tile usage policy" in raw:
                # Límite de los servidores voluntarios de OSM: esperar y reintentar.
                time.sleep(5 + 3 * intento)
                raise RuntimeError("bloqueado por política de uso")
            # Ojo: una tesela de mar abierto pesa ~250 bytes y es perfectamente
            # válida; el tamaño no sirve como prueba de error.
            try:
                im = Image.open(io.BytesIO(raw)).convert("RGB")
            except Exception as exc:
                raise ValueError(f"respuesta no es imagen ({len(raw)} bytes)") from exc
            if im.size != (256, 256):
                im = im.resize((256, 256))
            im.save(path, "JPEG", quality=82, optimize=True)
            if layer == "osm":
                time.sleep(0.08)
            return os.path.getsize(path)
        except Exception:
            if intento == 4:
                return -1
            time.sleep(0.5 * (intento + 1))
    return -1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--layer", required=True, choices=["oscuro", "osm", "inegi"])
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    outdir = os.path.join(TILES, args.layer)
    os.makedirs(outdir, exist_ok=True)
    jobs = plan(args.layer)
    todo = []
    for (z, x, y) in sorted(jobs):
        path = os.path.join(outdir, f"colima_{z}_{x}_{y}.jpg")
        if not os.path.exists(path):
            todo.append((z, x, y, path))

    print(f"[{args.layer}] plan {len(jobs)} | pendientes {len(todo)}", flush=True)
    if not todo:
        files = os.listdir(outdir)
        total = sum(os.path.getsize(os.path.join(outdir, f)) for f in files)
        print(f"[{args.layer}] ya completo: {len(files)} teselas, {total/1048576:.1f} MB", flush=True)
        return 0

    done = failed = got = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for size in pool.map(lambda j: fetch(j, args.layer, outdir), todo):
            done += 1
            if size > 0:
                got += size
            else:
                failed += 1
            if done % 250 == 0:
                print(f"  [{args.layer}] {done}/{len(todo)} {got/1048576:.1f} MB", flush=True)

    files = os.listdir(outdir)
    total = sum(os.path.getsize(os.path.join(outdir, f)) for f in files)
    print(f"[{args.layer}] listo: {len(files)} teselas, {total/1048576:.1f} MB | fallos {failed}", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
