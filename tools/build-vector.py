#!/usr/bin/env python3
"""Convierte las hojas vectoriales INEGI 1:50 000 en capas ligeras para la app.

Entrada: tools/.vector/x/<hoja>/conjunto_de_datos/*.shp (ver tools/fetch-vector.py)
Salida:  app/assets/vector/{vias,localidades}.json.gz

Las geometrías vienen en UTM (ITRF2008 zonas 13N/14N según la hoja); aquí se
reproyectan a WGS84, se simplifican a ~8 m y se recortan al estado. Se usa el
WKT del .prj como origen para no depender del número de zona.

Uso: python tools/build-vector.py
"""
import gzip
import json
import pathlib
import sys

import shapefile
from pyproj import Transformer
from shapely.geometry import LineString, MultiLineString, Point, box
from shapely.ops import transform as shp_transform

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "tools" / ".vector" / "x"
OUT = ROOT / "app" / "assets" / "vector"

# Colima y una orla de 8 km para que no se corte en los bordes.
STATE = box(-104.75, 18.60, -103.40, 19.70)
SIMPLIFY_M = 8.0

VIAS = (
    # (archivo, clase)  clase: 0 calle, 1 carretera, 2 camino
    ("calle50_l", 0),
    ("carretera50_l", 1),
    ("camino50_l", 2),
)


def dec(value, nd=5):
    return round(value, nd)


def geom_lines(shape):
    """Devuelve listas de tuplas (x, y) para una geometría de línea."""
    pts = shape.points
    parts = list(shape.parts) + [len(pts)]
    for i in range(len(parts) - 1):
        chunk = pts[parts[i]:parts[i + 1]]
        if len(chunk) >= 2:
            yield chunk


def prepare_transformer(prj_path):
    wkt = prj_path.read_text(encoding="utf-8", errors="ignore")
    return Transformer.from_crs(wkt, "EPSG:4326", always_xy=True)


def simplify(coords):
    line = LineString(coords)
    if not line.is_valid or line.length == 0:
        return None
    return line.simplify(SIMPLIFY_M, preserve_topology=False)


def main():
    if not SRC.exists():
        sys.exit(f"faltan las hojas vectoriales en {SRC}: corre antes tools/fetch-vector.py")
    OUT.mkdir(parents=True, exist_ok=True)

    vias = []
    localidades = []
    hojas = sorted(p for p in SRC.iterdir() if p.is_dir())
    if not hojas:
        sys.exit("no hay hojas descomprimidas")

    for hoja in hojas:
        datos = hoja / "conjunto_de_datos"
        if not datos.exists():
            continue
        for nombre, clase in VIAS:
            base = datos / nombre
            if not base.with_suffix(".shp").exists():
                continue
            tf = prepare_transformer(base.with_suffix(".prj"))
            reader = shapefile.Reader(str(base), encoding="utf-8", encodingErrors="replace")
            campos = [f[0] for f in reader.fields[1:]]
            tiene_nombre = "nombre" in campos
            for item in reader.iterShapeRecords():
                attrs = dict(zip(campos, list(item.record)))
                etiqueta = ""
                if clase == 0:
                    etiqueta = (attrs.get("nombre") or "").strip()
                elif clase == 1:
                    num = (attrs.get("numero") or "").strip()
                    tipo = (attrs.get("nume_carr") or "").strip()
                    etiqueta = f"{num} {tipo}".strip() if num and num != "0" else tipo
                for chunk in geom_lines(item.shape):
                    lonlat = [tf.transform(x, y) for x, y in chunk]
                    simple = simplify(lonlat)
                    if simple is None or simple.is_empty:
                        continue
                    if not STATE.intersects(simple):
                        continue
                    coords = [[dec(x), dec(y)] for x, y in simple.coords]
                    if len(coords) < 2:
                        continue
                    vias.append({"k": clase, "n": etiqueta[:48], "p": coords})

        # Localidades: punto con nombre y población.
        base = datos / "localidad50_p"
        if base.with_suffix(".shp").exists():
            tf = prepare_transformer(base.with_suffix(".prj"))
            reader = shapefile.Reader(str(base), encoding="utf-8", encodingErrors="replace")
            campos = [f[0] for f in reader.fields[1:]]
            for item in reader.iterShapeRecords():
                attrs = dict(zip(campos, list(item.record)))
                nombre = (attrs.get("nombre") or "").strip()
                if not nombre or len(item.shape.points) == 0:
                    continue
                x, y = item.shape.points[0]
                lon, lat = tf.transform(x, y)
                if not STATE.contains(Point(lon, lat)):
                    continue
                hab = attrs.get("nume_hab") or 0
                try:
                    hab = int(hab)
                except (TypeError, ValueError):
                    hab = 0
                localidades.append([dec(lon), dec(lat), nombre[:40], hab])

    # Deduplicar localidades repetidas entre hojas vecinas.
    vistas = set()
    unicas = []
    for lon, lat, nombre, hab in localidades:
        key = (nombre, round(lon, 3), round(lat, 3))
        if key in vistas:
            continue
        vistas.add(key)
        unicas.append([lon, lat, nombre, hab])

    for nombre, payload in (("vias", {"v": 1, "vias": vias}),
                            ("localidades", {"v": 1, "localidades": unicas})):
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        target = OUT / f"{nombre}.json.gz"
        with gzip.open(target, "wb", compresslevel=9) as fh:
            fh.write(raw)
        print(f"{target.name}: {len(raw)/1048576:.1f} MB crudos -> {target.stat().st_size/1048576:.1f} MB gzip")

    print(f"vías: {len(vias)} | localidades: {len(unicas)}")


if __name__ == "__main__":
    main()
