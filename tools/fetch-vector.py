#!/usr/bin/env python3
"""Descarga las hojas vectoriales 1:50 000 del INEGI que cubren Colima.

Uso: python tools/fetch-vector.py [--dir tools/.vector]
"""
import argparse
import concurrent.futures as cf
import pathlib
import re
import urllib.request

BASE = ("https://www.inegi.org.mx/contenidos/productos/prod_serv/contenidos/"
        "espanol/bvinegi/productos/geografia/imagen_cartografica/1_50_000/")

# Hoja -> UPC (serie III, edición 2013-2015) del catálogo de la Biblioteca digital.
SHEETS = {
    "E13B24": "702825002998",
    "E13B25": "702825002999",
    "E13B32": "702825003004",
    "E13B33": "702825003005",
    "E13B34": "702825002919",
    "E13B35": "702825271626",
    "E13B41": "702825268374",
    "E13B42": "702825003009",
    "E13B43": "702825268398",
    "E13B44": "702825003010",
    "E13B45": "702825002199",
    "E13B53": "702825002294",
    "E13B54": "702825268435",
    "E13B55": "702825002275",
    "E13B64": "702825002375",
}

UA = "openterritorio/1.0 (mapa tactico offline; contacto srtlalchichi@gmail.com)"


def fetch(sheet, upc, out: pathlib.Path):
    target = out / f"{sheet}.zip"
    if target.exists() and target.stat().st_size > 100_000:
        return sheet, target.stat().st_size, "ya estaba"
    url = BASE + f"{upc}_s.zip"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    last = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=180) as response:
                data = response.read()
            if not data.startswith(b"PK"):
                raise ValueError("la respuesta no es un zip")
            target.write_bytes(data)
            return sheet, len(data), "ok"
        except Exception as err:  # reintento con espera creciente
            last = err
            import time
            time.sleep(2 + 3 * attempt)
    return sheet, 0, f"fallo: {last}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="tools/.vector")
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()
    out = pathlib.Path(args.dir)
    out.mkdir(parents=True, exist_ok=True)

    total = 0
    with cf.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(fetch, s, u, out) for s, u in SHEETS.items()]
        for fut in cf.as_completed(futures):
            sheet, size, state = fut.result()
            total += size
            print(f"  {sheet}  {size/1048576:6.1f} MB  {state}", flush=True)
    print(f"total: {total/1048576:.1f} MB en {out}")


if __name__ == "__main__":
    main()
