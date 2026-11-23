'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const SCHEMA = `
CREATE TABLE IF NOT EXISTS peers (
  sender_id    INTEGER PRIMARY KEY,
  lat_e7       INTEGER NOT NULL,
  lon_e7       INTEGER NOT NULL,
  alt_m        INTEGER,
  speed_cms    INTEGER,
  heading_deg  INTEGER,
  battery_pct  INTEGER,
  last_ts      INTEGER NOT NULL,
  last_seen_ms INTEGER NOT NULL,
  transport    TEXT
);

CREATE TABLE IF NOT EXISTS tracks (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  sender_id   INTEGER NOT NULL,
  lat_e7      INTEGER NOT NULL,
  lon_e7      INTEGER NOT NULL,
  speed_cms   INTEGER,
  heading_deg INTEGER,
  battery_pct INTEGER,
  ts          INTEGER NOT NULL,
  created_ms  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tracks_sender_created ON tracks(sender_id, created_ms);

CREATE TABLE IF NOT EXISTS events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  packet_id   BLOB UNIQUE NOT NULL,
  sender_id   INTEGER NOT NULL,
  category_id INTEGER NOT NULL,
  lat_e7      INTEGER NOT NULL,
  lon_e7      INTEGER NOT NULL,
  short_note  TEXT,
  ts          INTEGER NOT NULL,
  created_ms  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_ms);

CREATE TABLE IF NOT EXISTS alerts (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  packet_id   BLOB UNIQUE NOT NULL,
  sender_id   INTEGER NOT NULL,
  severity    INTEGER NOT NULL,
  lat_e7      INTEGER NOT NULL,
  lon_e7      INTEGER NOT NULL,
  radius_m    INTEGER NOT NULL,
  title       TEXT,
  ts          INTEGER NOT NULL,
  created_ms  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_alerts_created ON alerts(created_ms);

CREATE TABLE IF NOT EXISTS acks (
  packet_id   BLOB NOT NULL,
  acked_by    INTEGER NOT NULL,
  ts          INTEGER NOT NULL,
  created_ms  INTEGER NOT NULL,
  PRIMARY KEY (packet_id, acked_by)
);

CREATE TABLE IF NOT EXISTS packets_seen (
  packet_id   BLOB PRIMARY KEY,
  sender_id   INTEGER NOT NULL,
  ts          INTEGER NOT NULL,
  seen_ms     INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_seen_ms ON packets_seen(seen_ms);

PRAGMA user_version = 1;
`;

function openDatabase(dbPath) {
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA journal_mode = WAL;');
  db.exec('PRAGMA synchronous = NORMAL;');
  db.exec('PRAGMA busy_timeout = 5000;');
  db.exec(SCHEMA);
  return db;
}

function hex(bytes) {
  if (!bytes) return null;
  return Buffer.from(bytes).toString('hex');
}

function createRepository(db) {
  const statements = {
    insertSeen: db.prepare(
      'INSERT OR IGNORE INTO packets_seen(packet_id, sender_id, ts, seen_ms) VALUES (?, ?, ?, ?)',
    ),
    upsertPeer: db.prepare(`
      INSERT INTO peers(sender_id, lat_e7, lon_e7, alt_m, speed_cms, heading_deg,
                        battery_pct, last_ts, last_seen_ms, transport)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(sender_id) DO UPDATE SET
        lat_e7 = excluded.lat_e7,
        lon_e7 = excluded.lon_e7,
        alt_m = excluded.alt_m,
        speed_cms = excluded.speed_cms,
        heading_deg = excluded.heading_deg,
        battery_pct = excluded.battery_pct,
        last_ts = excluded.last_ts,
        last_seen_ms = excluded.last_seen_ms,
        transport = excluded.transport
    `),
    insertTrack: db.prepare(`
      INSERT INTO tracks(sender_id, lat_e7, lon_e7, speed_cms, heading_deg, battery_pct, ts, created_ms)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `),
    insertEvent: db.prepare(`
      INSERT OR IGNORE INTO events(packet_id, sender_id, category_id, lat_e7, lon_e7, short_note, ts, created_ms)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `),
    insertAlert: db.prepare(`
      INSERT OR IGNORE INTO alerts(packet_id, sender_id, severity, lat_e7, lon_e7, radius_m, title, ts, created_ms)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `),
    insertAck: db.prepare(`
      INSERT OR IGNORE INTO acks(packet_id, acked_by, ts, created_ms)
      VALUES (?, ?, ?, ?)
    `),
    listPeers: db.prepare('SELECT * FROM peers ORDER BY last_seen_ms DESC'),
    getPeer: db.prepare('SELECT * FROM peers WHERE sender_id = ?'),
    listEvents: db.prepare('SELECT * FROM events ORDER BY id DESC LIMIT ?'),
    listAlerts: db.prepare(`
      SELECT a.*,
             (SELECT COUNT(*) FROM acks k WHERE k.packet_id = a.packet_id) AS ack_count
      FROM alerts a
      ORDER BY a.id DESC
      LIMIT ?
    `),
    listTracks: db.prepare(`
      SELECT * FROM tracks
      WHERE sender_id = ? AND created_ms >= ?
      ORDER BY created_ms ASC
      LIMIT ?
    `),
    listAcks: db.prepare(
      'SELECT acked_by, ts, created_ms FROM acks WHERE packet_id = ? ORDER BY created_ms ASC',
    ),
    pruneSeen: db.prepare('DELETE FROM packets_seen WHERE seen_ms < ?'),
    pruneTracks: db.prepare('DELETE FROM tracks WHERE created_ms < ?'),
    countPeers: db.prepare('SELECT COUNT(*) AS n FROM peers'),
    countEvents: db.prepare('SELECT COUNT(*) AS n FROM events'),
    countAlerts: db.prepare('SELECT COUNT(*) AS n FROM alerts'),
    countTracks: db.prepare('SELECT COUNT(*) AS n FROM tracks'),
    countSeen: db.prepare('SELECT COUNT(*) AS n FROM packets_seen'),
    pageCount: db.prepare('PRAGMA page_count'),
    pageSize: db.prepare('PRAGMA page_size'),
  };

  function markSeen(packetId, senderId, timestamp, nowMs) {
    const result = statements.insertSeen.run(
      Buffer.from(packetId),
      senderId,
      timestamp,
      nowMs,
    );
    return Number(result.changes) > 0;
  }

  function upsertPeer(msg, nowMs, transport) {
    const p = msg.position;
    statements.upsertPeer.run(
      msg.sender_id,
      p.latitude_e7,
      p.longitude_e7,
      p.altitude_m ?? 0,
      p.speed_cms ?? 0,
      p.heading_deg ?? 0,
      p.battery_pct ?? 0,
      Number(msg.timestamp) || 0,
      nowMs,
      transport || null,
    );
  }

  function insertTrack(msg, nowMs) {
    const p = msg.position;
    statements.insertTrack.run(
      msg.sender_id,
      p.latitude_e7,
      p.longitude_e7,
      p.speed_cms ?? 0,
      p.heading_deg ?? 0,
      p.battery_pct ?? 0,
      Number(msg.timestamp) || 0,
      nowMs,
    );
  }

  function insertEvent(msg, nowMs) {
    const e = msg.event;
    statements.insertEvent.run(
      Buffer.from(msg.packet_id),
      msg.sender_id,
      e.category_id ?? 0,
      e.latitude_e7,
      e.longitude_e7,
      e.short_note || '',
      Number(msg.timestamp) || 0,
      nowMs,
    );
  }

  function insertAlert(msg, nowMs) {
    const a = msg.alert;
    statements.insertAlert.run(
      Buffer.from(msg.packet_id),
      msg.sender_id,
      a.severity,
      a.latitude_e7,
      a.longitude_e7,
      a.radius_m ?? 0,
      a.title || '',
      Number(msg.timestamp) || 0,
      nowMs,
    );
  }

  function insertAck(msg, nowMs) {
    statements.insertAck.run(
      Buffer.from(msg.ack.acked_packet_id),
      msg.sender_id,
      Number(msg.timestamp) || 0,
      nowMs,
    );
  }

  function prune(nowMs, seenTtlMs, trackTtlMs) {
    const seen = statements.pruneSeen.run(nowMs - seenTtlMs);
    const tracks = statements.pruneTracks.run(nowMs - trackTtlMs);
    return { seen: Number(seen.changes), tracks: Number(tracks.changes) };
  }

  function counts() {
    return {
      peers: Number(statements.countPeers.get().n),
      events: Number(statements.countEvents.get().n),
      alerts: Number(statements.countAlerts.get().n),
      tracks: Number(statements.countTracks.get().n),
      packets_seen: Number(statements.countSeen.get().n),
    };
  }

  function dbSizeBytes() {
    try {
      const pages = Number(statements.pageCount.get()['page_count']);
      const size = Number(statements.pageSize.get()['page_size']);
      return pages * size;
    } catch {
      return null;
    }
  }

  function listPeers() {
    return statements.listPeers.all().map((row) => ({ ...row }));
  }

  function getPeer(senderId) {
    return statements.getPeer.get(senderId) || null;
  }

  function listEvents(limit = 200) {
    return statements.listEvents.all(limit).map((row) => ({
      ...row,
      packet_id: hex(row.packet_id),
    }));
  }

  function listAlerts(limit = 50) {
    return statements.listAlerts.all(limit).map((row) => ({
      ...row,
      packet_id: hex(row.packet_id),
    }));
  }

  function listTracks(senderId, sinceMs, limit = 5000) {
    return statements.listTracks.all(senderId, sinceMs, limit).map((row) => ({ ...row }));
  }

  function listAcks(packetId) {
    return statements.listAcks.all(Buffer.from(packetId)).map((row) => ({ ...row }));
  }

  return {
    markSeen,
    upsertPeer,
    insertTrack,
    insertEvent,
    insertAlert,
    insertAck,
    prune,
    counts,
    dbSizeBytes,
    listPeers,
    getPeer,
    listEvents,
    listAlerts,
    listTracks,
    listAcks,
    close: () => db.close(),
    raw: db,
  };
}

module.exports = { openDatabase, createRepository, hex };
