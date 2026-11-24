#!/usr/bin/env node
'use strict';

/**
 * Publica un APK por HTTPS en el backend (OTA), en trozos si hace falta.
 *
 * Uso:
 *   node tools/publish-remote.js <apk> <version> <version_code> <notes> [url] [token]
 *
 * Variables: OPENTERITORIO_TOKEN, OPENTERITORIO_URL.
 *
 * Se usa Node y no PowerShell porque `Invoke-RestMethod -Body byte[]` no
 * garantiza el envío byte a byte de bloques grandes: el archivo llegaba
 * corrupto y el servidor rechazaba el sha256.
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const CHUNK = Number(process.env.OPENTERITORIO_CHUNK) || 64 * 1024 * 1024;

function die(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

async function main() {
  const [, , apkPath, version, versionCode, notes = '', urlArg, tokenArg] = process.argv;
  const base = (urlArg || process.env.OPENTERITORIO_URL || 'https://tienda.tlalchichi.xyz').replace(/\/+$/, '');
  const token = tokenArg || process.env.OPENTERITORIO_TOKEN || '';

  if (!apkPath) die('falta la ruta del APK');
  if (!/^\d+\.\d+\.\d+$/.test(version || '')) die('version debe ser X.Y.Z');
  if (!Number.isInteger(Number(versionCode)) || Number(versionCode) <= 0) die('version_code inválido');
  if (!token) die('falta el token (OPENTERITORIO_TOKEN o argumento)');

  const file = path.resolve(apkPath);
  const data = fs.readFileSync(file);
  const sha256 = crypto.createHash('sha256').update(data).digest('hex');
  const size = data.length;
  console.log(`${path.basename(file)}  ${(size / 1048576).toFixed(1)} MB  sha256=${sha256}`);

  const query = new URLSearchParams({
    version,
    version_code: String(versionCode),
    sha256,
    notes,
    size: String(size),
  });

  const headers = {
    Authorization: 'Bearer ' + token,
    'Content-Type': 'application/octet-stream',
  };

  const chunks = Math.ceil(size / CHUNK);
  for (let offset = 0; offset < size; offset += CHUNK) {
    const part = data.subarray(offset, Math.min(offset + CHUNK, size));
    const response = await fetch(`${base}/api/app/upload?${query}&offset=${offset}`, {
      method: 'POST',
      headers,
      body: part,
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      die(`trozo en ${offset}: HTTP ${response.status} ${JSON.stringify(body)}`);
    }
    const done = Math.min(offset + part.length, size);
    console.log(`  ${(done / 1048576).toFixed(1)}/${(size / 1048576).toFixed(1)} MB` +
      (chunks > 1 ? `  (${body.pending ? 'parcial' : 'final'})` : ''));
  }

  const latest = await fetch(`${base}/api/app/latest`, {
    headers: { Authorization: 'Bearer ' + token },
  }).then((r) => r.json());

  if (latest.version_code !== Number(versionCode) || latest.sha256 !== sha256) {
    die(`verificación fallida: el servidor sirve ${latest.version_code}/${latest.sha256}`);
  }
  console.log(`publicado: v${latest.version} (code ${latest.version_code}), ${latest.size_bytes} bytes`);
}

main().catch((err) => die(err && err.stack ? err.stack : String(err)));
