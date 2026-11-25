'use strict';

const fs = require('node:fs');
const path = require('node:path');

/**
 * Carga un archivo .env sencillo (KEY=VALOR, sin dependencias).
 * No sobreescribe variables ya presentes en process.env.
 */
function loadEnvFile(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return;
  }
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}

function buildConfig(overrides = {}) {
  loadEnvFile(path.join(process.cwd(), '.env'));

  const num = (value, fallback) => {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  };

  const config = {
    port: num(process.env.PORT, 3000),
    host: process.env.HOST || '0.0.0.0',
    token: process.env.TOKEN || '',
    dbPath: path.resolve(process.cwd(), process.env.DB_PATH || 'data/tactical.db'),
    logFile: path.resolve(process.cwd(), process.env.LOG_FILE || 'logs/server.log'),
    // Carpeta con el APK publicado para OTA: latest.json + openterritorio.apk.
    appDir: path.resolve(process.cwd(), process.env.APP_DIR || 'app'),
    // Despliegue remoto del backend: el vigilante del teléfono (runit) mira
    // estos dos archivos y aplica el tarball cuando cambia el sello.
    deployDir: process.env.DEPLOY_DIR || '/sdcard/Download',
    deployEnabled: process.env.DEPLOY_DISABLE !== '1',
    maxDeployBytes: Number(process.env.MAX_DEPLOY_BYTES || 12 * 1024 * 1024),
    // Puntos fijos del tablero (se pueden editar por API sin tocar la app).
    landmarksFile: path.resolve(process.cwd(), process.env.LANDMARKS_FILE || 'landmarks.json'),
    maxClients: num(process.env.MAX_CLIENTS, 200),
    maxPayloadBytes: num(process.env.MAX_PAYLOAD_BYTES, 4096),
    // APK por OTA subido desde el PC (400 MB cubre de sobra el mapa completo).
    maxUploadBytes: num(process.env.MAX_UPLOAD_BYTES, 400 * 1024 * 1024),
    seenTtlMs: num(process.env.SEEN_TTL_MS, 24 * 60 * 60 * 1000),
    trackTtlMs: num(process.env.TRACK_TTL_MS, 7 * 24 * 60 * 60 * 1000),
    eventTtlMs: num(process.env.EVENT_TTL_MS, 30 * 24 * 60 * 60 * 1000),
    peerTtlMs: num(process.env.PEER_TTL_MS, 7 * 24 * 60 * 60 * 1000),
    logMaxBytes: num(process.env.LOG_MAX_BYTES, 2 * 1024 * 1024),
    wsRateMax: num(process.env.WS_RATE_MAX, 60),
    wsRateWindowMs: num(process.env.WS_RATE_WINDOW_MS, 1000),
    trustCfHeader: process.env.TRUST_CF_HEADER !== '0',
    authFailWindowMs: num(process.env.AUTH_FAIL_WINDOW_MS, 60 * 1000),
    authFailMax: num(process.env.AUTH_FAIL_MAX, 20),
    publicUrl: process.env.PUBLIC_URL || '',
    logLevel: process.env.LOG_LEVEL || 'info',
  };

  return Object.assign(config, overrides);
}

module.exports = { buildConfig, loadEnvFile };
