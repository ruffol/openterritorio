'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const express = require('express');
const proto = require('./proto');
const pkg = require('../package.json');

function peerJSON(row, nowMs) {
  return {
    sender_id: row.sender_id,
    lat: row.lat_e7 / 1e7,
    lon: row.lon_e7 / 1e7,
    latitude_e7: row.lat_e7,
    longitude_e7: row.lon_e7,
    alt_m: row.alt_m,
    speed_kmh: Math.round((row.speed_cms || 0) * 0.036 * 10) / 10,
    heading_deg: row.heading_deg,
    battery_pct: row.battery_pct,
    last_ts: row.last_ts,
    age_ms: Math.max(0, nowMs - row.last_seen_ms),
    transport: row.transport,
  };
}

function eventJSON(row) {
  return {
    id: row.id,
    packet_id: row.packet_id,
    sender_id: row.sender_id,
    category_id: row.category_id,
    lat: row.lat_e7 / 1e7,
    lon: row.lon_e7 / 1e7,
    short_note: row.short_note || '',
    ts: row.ts,
    created_ms: row.created_ms,
  };
}

function alertJSON(row) {
  return {
    id: row.id,
    packet_id: row.packet_id,
    sender_id: row.sender_id,
    severity: row.severity,
    lat: row.lat_e7 / 1e7,
    lon: row.lon_e7 / 1e7,
    radius_m: row.radius_m,
    title: row.title || '',
    ts: row.ts,
    created_ms: row.created_ms,
    ack_count: row.ack_count ?? 0,
  };
}

/**
 * Recorta un texto al límite en **bytes UTF-8** (no en unidades UTF-16),
 * que es lo que exige el contrato Protobuf. Sin esto, "Punto de reunión…"
 * con acentos se rechazaba con 400 al pasar de 64 bytes.
 */
function truncateUtf8(value, maxBytes = 64) {
  const text = String(value ?? '');
  if (Buffer.byteLength(text, 'utf8') <= maxBytes) return text;
  let out = '';
  let used = 0;
  for (const char of text) {
    const size = Buffer.byteLength(char, 'utf8');
    if (used + size > maxBytes) break;
    out += char;
    used += size;
  }
  return out;
}

/** Últimas `maxLines` líneas de un archivo sin cargarlo entero en memoria. */
function readTail(file, maxLines, maxBytes = 256 * 1024) {
  const stat = fs.statSync(file);
  const length = Math.min(stat.size, maxBytes);
  const start = Math.max(0, stat.size - length);
  const fd = fs.openSync(file, 'r');
  try {
    const buffer = Buffer.alloc(length);
    const read = fs.readSync(fd, buffer, 0, length, start);
    return buffer
      .subarray(0, read)
      .toString('utf8')
      .split(/\r?\n/)
      .filter(Boolean)
      .slice(-maxLines);
  } finally {
    fs.closeSync(fd);
  }
}

function readCoords(body) {
  if (Number.isInteger(body.latitude_e7) && Number.isInteger(body.longitude_e7)) {
    return { latE7: body.latitude_e7, lonE7: body.longitude_e7 };
  }
  if (Number.isFinite(body.lat) && Number.isFinite(body.lon)) {
    return { latE7: Math.round(body.lat * 1e7), lonE7: Math.round(body.lon * 1e7) };
  }
  throw new Error('lat/lon o latitude_e7/longitude_e7 requeridos');
}

function serverPacket(type, payload) {
  return {
    packet_id: crypto.randomBytes(8),
    sender_id: 0,
    timestamp: Math.floor(Date.now() / 1000),
    hop_limit: 3,
    type,
    ...payload,
  };
}

/**
 * Lee `latest.json` y el APK publicado en `appDir` (OTA). Devuelve null si no
 * hay una actualización publicada o el archivo declarado no existe.
 */
function readAppRelease(appDir) {
  let manifest;
  try {
    const raw = fs.readFileSync(path.join(appDir, 'latest.json'), 'utf8');
    // Tolerar BOM si el manifiesto se generó con Windows PowerShell.
    manifest = JSON.parse(raw.replace(/^\uFEFF/, ''));
  } catch {
    return null;
  }
  if (!manifest || typeof manifest !== 'object') return null;

  const apkName = path.basename(String(manifest.apk || 'openterritorio.apk'));
  if (!/^[\w .-]+\.apk$/i.test(apkName)) return null;

  const apkPath = path.join(appDir, apkName);
  let stat;
  try {
    stat = fs.statSync(apkPath);
  } catch {
    return null;
  }
  if (!stat.isFile()) return null;

  return {
    version: String(manifest.version || ''),
    version_code: Number(manifest.version_code) || 0,
    notes: String(manifest.notes || ''),
    published_at: manifest.published_at || null,
    sha256: String(manifest.sha256 || ''),
    apk_name: apkName,
    apk_path: apkPath,
    size_bytes: stat.size,
  };
}

function createHttpApp({ config, repo, auth, ingest, hub, log, publicDir, startedAt }) {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', true);

  app.use((req, res, next) => {
    res.set('X-Content-Type-Options', 'nosniff');
    res.set('Referrer-Policy', 'no-referrer');
    res.set('Cache-Control', 'no-store');
    next();
  });

  app.use(express.raw({ type: 'application/x-protobuf', limit: config.maxPayloadBytes }));
  app.use(express.json({ limit: '64kb' }));

  function clientIp(req) {
    // `cf-connecting-ip` solo es fiable detrás de Cloudflare; con acceso
    // directo a la LAN cualquiera puede rotarlo para esquivar el límite.
    if (config.trustCfHeader && req.headers['cf-connecting-ip']) {
      return String(req.headers['cf-connecting-ip']);
    }
    return req.socket.remoteAddress || 'unknown';
  }
  function bearer(req) {
    const header = req.headers.authorization || '';
    return header.startsWith('Bearer ') ? header.slice(7) : '';
  }
  function authorized(req) {
    return auth.verify(bearer(req) || req.query.token || '', clientIp(req));
  }

  app.get('/healthz', (req, res) => {
    res.json({ ok: true, ts: Date.now() });
  });

  app.use('/api', (req, res, next) => {
    if (!authorized(req)) {
      return res.status(401).json({ ok: false, error: 'unauthorized' });
    }
    next();
  });

  app.get('/api/health', (req, res) => {
    const now = Date.now();
    res.json({
      ok: true,
      version: pkg.version,
      uptime_s: Math.floor((now - startedAt) / 1000),
      server_time_ms: now,
      ws_clients: hub.clients.size,
      db: { path: config.dbPath, size_bytes: repo.dbSizeBytes() },
      counts: repo.counts(),
    });
  });

  app.get('/api/state', (req, res) => {
    const now = Date.now();
    res.json({
      ok: true,
      server_time_ms: now,
      peers: repo.listPeers().map((row) => peerJSON(row, now)),
      events: repo.listEvents(200).map(eventJSON),
      alerts: repo.listAlerts(50).map(alertJSON),
      counts: repo.counts(),
    });
  });

  app.get('/api/peers', (req, res) => {
    const now = Date.now();
    res.json({ ok: true, peers: repo.listPeers().map((row) => peerJSON(row, now)) });
  });

  app.get('/api/events', (req, res) => {
    const limit = Math.min(Number(req.query.limit) || 200, 1000);
    res.json({ ok: true, events: repo.listEvents(limit).map(eventJSON) });
  });

  app.post('/api/events', (req, res) => {
    try {
      const body = req.body || {};
      const coords = readCoords(body);
      const packet = serverPacket(proto.PACKET_TYPE.USER_EVENT, {
        event: {
          category_id: Number.isInteger(body.category_id) ? body.category_id : 0,
          latitude_e7: coords.latE7,
          longitude_e7: coords.lonE7,
          short_note: truncateUtf8(body.short_note ?? body.note ?? '', 64),
        },
      });
      const result = ingest.handle(proto.encode(packet), null);
      if (!result.ok) return res.status(400).json(result);
      return res.status(201).json({
        ok: true,
        packet_id: packet.packet_id.toString('hex'),
        type: 'USER_EVENT',
      });
    } catch (err) {
      return res.status(400).json({ ok: false, error: err.message });
    }
  });

  app.get('/api/alerts', (req, res) => {
    const limit = Math.min(Number(req.query.limit) || 50, 500);
    res.json({ ok: true, alerts: repo.listAlerts(limit).map(alertJSON) });
  });

  app.post('/api/alerts', (req, res) => {
    try {
      const body = req.body || {};
      const coords = readCoords(body);
      const severity = Number(body.severity);
      if (![1, 2, 3].includes(severity)) throw new Error('severity debe ser 1, 2 o 3');
      const packet = serverPacket(proto.PACKET_TYPE.SERVER_ALERT, {
        alert: {
          severity,
          latitude_e7: coords.latE7,
          longitude_e7: coords.lonE7,
          radius_m: Math.max(0, Number(body.radius_m) || 0),
          title: truncateUtf8(body.title || '', 64),
        },
      });
      const result = ingest.handle(proto.encode(packet), null);
      if (!result.ok) return res.status(400).json(result);
      return res.status(201).json({
        ok: true,
        packet_id: packet.packet_id.toString('hex'),
        type: 'SERVER_ALERT',
      });
    } catch (err) {
      return res.status(400).json({ ok: false, error: err.message });
    }
  });

  app.get('/api/alerts/:packetId/acks', (req, res) => {
    const packetId = String(req.params.packetId || '');
    if (!/^[0-9a-f]{16}$/i.test(packetId)) {
      return res.status(400).json({ ok: false, error: 'packetId debe ser 16 hex' });
    }
    const acks = repo.listAcks(Buffer.from(packetId, 'hex'));
    return res.json({ ok: true, packet_id: packetId.toLowerCase(), acks });
  });

  app.get('/api/tracks/:senderId', (req, res) => {
    const senderId = Number(req.params.senderId);
    if (!Number.isInteger(senderId)) {
      return res.status(400).json({ ok: false, error: 'senderId invalido' });
    }
    const now = Date.now();
    const sinceMs = Number(req.query.since_ms) || now - 24 * 60 * 60 * 1000;
    const limit = Math.min(Number(req.query.limit) || 5000, 20000);
    res.json({
      ok: true,
      sender_id: senderId,
      since_ms: sinceMs,
      tracks: repo.listTracks(senderId, sinceMs, limit),
    });
  });

  app.get('/api/app/latest', (req, res) => {
    const release = readAppRelease(config.appDir);
    if (!release) {
      return res.status(404).json({ ok: false, error: 'sin actualización publicada' });
    }
    return res.json({
      ok: true,
      version: release.version,
      version_code: release.version_code,
      notes: release.notes,
      published_at: release.published_at,
      sha256: release.sha256,
      apk_name: release.apk_name,
      size_bytes: release.size_bytes,
      url: '/api/app/download',
      server_time_ms: Date.now(),
    });
  });

  app.get('/api/app/download', (req, res, next) => {
    const release = readAppRelease(config.appDir);
    if (!release) {
      return res.status(404).json({ ok: false, error: 'sin actualización publicada' });
    }
    res.set('Content-Type', 'application/vnd.android.package-archive');
    res.set('Cache-Control', 'no-store');
    res.set('Content-Disposition', `attachment; filename="${release.apk_name}"`);
    return res.sendFile(release.apk_path, (err) => {
      if (err && !res.headersSent) next(err);
    });
  });

  app.post('/api/packets', (req, res) => {
    if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
      return res.status(415).json({
        ok: false,
        error: 'se requiere Content-Type: application/x-protobuf con cuerpo binario',
      });
    }
    const result = ingest.handle(req.body, null);
    return res.status(result.ok ? 202 : 400).json(result);
  });

  app.get('/api/logs', (req, res) => {
    const lines = Math.min(Number(req.query.lines) || 200, 2000);
    try {
      const tail = readTail(config.logFile, lines);
      return res.json({ ok: true, file: path.basename(config.logFile), lines: tail });
    } catch {
      return res.json({ ok: true, lines: [] });
    }
  });

  app.use('/api', (req, res) => {
    res.status(404).json({ ok: false, error: 'not found' });
  });

  app.use(express.static(publicDir, { etag: false, maxAge: 0 }));
  app.get('/', (req, res) => {
    res.sendFile(path.join(publicDir, 'index.html'));
  });

  app.use((err, req, res, next) => {
    const status = err.status || err.statusCode || 500;
    if (status >= 500) log.error('http error', { err: err.message, path: req.path });
    res.status(status).json({ ok: false, error: status === 500 ? 'internal' : err.message });
  });

  return app;
}

module.exports = { createHttpApp, peerJSON, eventJSON, alertJSON, readAppRelease, truncateUtf8, readTail };
