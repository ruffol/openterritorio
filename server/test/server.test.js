'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const WebSocket = require('ws');
const proto = require('../src/proto');
const { createRuntime } = require('../src/app');

const TOKEN = 'test-token';

function positionPacket(senderId, packetId = 'a1b2c3d4e5f60708') {
  return {
    packet_id: Buffer.from(packetId, 'hex'),
    sender_id: senderId,
    timestamp: Math.floor(Date.now() / 1000),
    hop_limit: 3,
    type: 0,
    position: {
      latitude_e7: 192433000 + senderId,
      longitude_e7: -1037247000 - senderId,
      altitude_m: 550,
      speed_cms: 1200,
      heading_deg: 90,
      battery_pct: 77,
    },
  };
}

function eventPacket(senderId, packetId = 'b1b2c3d4e5f60708') {
  return {
    packet_id: Buffer.from(packetId, 'hex'),
    sender_id: senderId,
    timestamp: Math.floor(Date.now() / 1000),
    hop_limit: 3,
    type: 1,
    event: {
      category_id: 9,
      latitude_e7: 192440000,
      longitude_e7: -1037250000,
      short_note: 'Punto de reunion',
    },
  };
}

function ackPacket(senderId, ackedPacketId, packetId = 'c1b2c3d4e5f60708') {
  return {
    packet_id: Buffer.from(packetId, 'hex'),
    sender_id: senderId,
    timestamp: Math.floor(Date.now() / 1000),
    hop_limit: 0,
    type: 3,
    ack: { acked_packet_id: Buffer.from(ackedPacketId, 'hex') },
  };
}

async function startServer(overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'openterritorio-'));
  const rt = createRuntime({
    port: 0,
    host: '127.0.0.1',
    dbPath: path.join(dir, 'test.db'),
    logFile: path.join(dir, 'server.log'),
    token: TOKEN,
    logLevel: 'error',
    ...overrides,
  });
  await rt.start(0, '127.0.0.1');
  const port = rt.server.address().port;
  return {
    rt,
    dir,
    port,
    url: `http://127.0.0.1:${port}`,
    wsUrl: `ws://127.0.0.1:${port}/ws`,
    close: () => rt.close(),
  };
}

function connect(wsUrl, token = TOKEN) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsUrl}?token=${encodeURIComponent(token)}`);
    const messages = [];
    ws.on('message', (data) => messages.push(Buffer.from(data)));
    ws.on('open', () => resolve({ ws, messages, close: () => ws.terminate() }));
    ws.on('unexpected-response', (req, res) => reject(new Error(`http ${res.statusCode}`)));
    ws.on('error', (err) => reject(err));
  });
}

async function waitFor(predicate, { timeout = 3000, interval = 25 } = {}) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, interval));
  }
  throw new Error('timeout esperando condición');
}

async function getJson(url, pathname, token = TOKEN, init = {}) {
  const headers = Object.assign({}, init.headers || {});
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(`${url}${pathname}`, { ...init, headers });
  return { status: response.status, body: await response.json() };
}

test('difunde posición a otros clientes', async () => {
  const server = await startServer();
  const a = await connect(server.wsUrl);
  const b = await connect(server.wsUrl);
  try {
    a.ws.send(proto.encode(positionPacket(101)));
    await waitFor(() => b.messages.length === 1);
    const received = proto.decode(b.messages[0]);
    assert.equal(received.sender_id, 101);
    assert.equal(received.type, 0);
  } finally {
    a.close();
    b.close();
    await server.close();
  }
});

test('deduplica paquetes repetidos (misma ráfaga por dos transportes)', async () => {
  const server = await startServer();
  const a = await connect(server.wsUrl);
  const b = await connect(server.wsUrl);
  try {
    const encoded = proto.encode(positionPacket(102, 'd1b2c3d4e5f60708'));
    a.ws.send(encoded);
    a.ws.send(encoded);
    await waitFor(() => b.messages.length === 1);
    await new Promise((resolve) => setTimeout(resolve, 250));
    assert.equal(b.messages.length, 1, 'el duplicado no debe reenviarse');
  } finally {
    a.close();
    b.close();
    await server.close();
  }
});

test('difunde eventos y los persiste', async () => {
  const server = await startServer();
  const a = await connect(server.wsUrl);
  const b = await connect(server.wsUrl);
  try {
    a.ws.send(proto.encode(eventPacket(103, 'e1b2c3d4e5f60708')));
    await waitFor(() => b.messages.length === 1);
    const state = await getJson(server.url, '/api/state');
    assert.equal(state.status, 200);
    assert.equal(state.body.events.length, 1);
    assert.equal(state.body.events[0].short_note, 'Punto de reunion');
  } finally {
    a.close();
    b.close();
    await server.close();
  }
});

test('alerta desde REST, broadcast y ACK de un cliente', async () => {
  const server = await startServer();
  const b = await connect(server.wsUrl);
  try {
    const created = await getJson(server.url, '/api/alerts', TOKEN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        severity: 3,
        lat: 19.24,
        lon: -103.72,
        radius_m: 500,
        title: 'Zona de riesgo',
      }),
    });
    assert.equal(created.status, 201);
    const alertPacketId = created.body.packet_id;
    assert.match(alertPacketId, /^[0-9a-f]{16}$/);

    await waitFor(() => b.messages.length === 1);
    const alert = proto.decode(b.messages[0]);
    assert.equal(alert.type, 2);
    assert.equal(alert.alert.severity, 3);
    assert.equal(alert.alert.title, 'Zona de riesgo');

    b.ws.send(proto.encode(ackPacket(104, alertPacketId, 'f1b2c3d4e5f60708')));
    await new Promise((resolve) => setTimeout(resolve, 150));

    const acks = await getJson(server.url, `/api/alerts/${alertPacketId}/acks`);
    assert.equal(acks.status, 200);
    assert.equal(acks.body.acks.length, 1);
    assert.equal(acks.body.acks[0].acked_by, 104);
  } finally {
    b.close();
    await server.close();
  }
});

test('rechaza token inválido en WebSocket y REST', async () => {
  const server = await startServer();
  try {
    await assert.rejects(connect(server.wsUrl, 'token-malo'), /401/);
    const response = await getJson(server.url, '/api/state', 'token-malo');
    assert.equal(response.status, 401);
  } finally {
    await server.close();
  }
});

test('los datos sobreviven a un reinicio del proceso', async () => {
  const server = await startServer();
  const a = await connect(server.wsUrl);
  try {
    a.ws.send(proto.encode(positionPacket(105, 'a9b2c3d4e5f60708')));
    await new Promise((resolve) => setTimeout(resolve, 150));
  } finally {
    a.close();
  }
  const { dbPath } = server.rt.config;
  await server.close();

  const dir = path.dirname(dbPath);
  const rt2 = createRuntime({
    port: 0,
    host: '127.0.0.1',
    dbPath,
    logFile: path.join(dir, 'server2.log'),
    token: TOKEN,
    logLevel: 'error',
  });
  await rt2.start(0, '127.0.0.1');
  const port2 = rt2.server.address().port;
  try {
    const state = await getJson(`http://127.0.0.1:${port2}`, '/api/state');
    assert.equal(state.status, 200);
    assert.equal(state.body.peers.length, 1);
    assert.equal(state.body.peers[0].sender_id, 105);
  } finally {
    await rt2.close();
  }
});

test('healthz es público y no filtra detalles', async () => {
  const server = await startServer();
  try {
    const response = await fetch(`${server.url}/healthz`);
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.ok, true);
    assert.equal(body.counts, undefined);
  } finally {
    await server.close();
  }
});

test('OTA: publica metadata y descarga el APK con token', async () => {
  const appDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openterritorio-ota-'));
  const apk = Buffer.from('APK-DE-PRUEBA-0123456789');
  const sha256 = crypto.createHash('sha256').update(apk).digest('hex');
  fs.writeFileSync(path.join(appDir, 'openterritorio.apk'), apk);
  fs.writeFileSync(
    path.join(appDir, 'latest.json'),
    JSON.stringify({
      version: '0.2.0',
      version_code: 2,
      apk: 'openterritorio.apk',
      sha256,
      notes: 'prueba OTA',
      published_at: '2026-11-23T00:00:00.000Z',
    }),
  );

  const server = await startServer({ appDir });
  try {
    const latest = await getJson(server.url, '/api/app/latest');
    assert.equal(latest.status, 200);
    assert.equal(latest.body.version, '0.2.0');
    assert.equal(latest.body.version_code, 2);
    assert.equal(latest.body.size_bytes, apk.length);
    assert.equal(latest.body.sha256, sha256);
    assert.equal(latest.body.apk_name, 'openterritorio.apk');
    assert.equal(latest.body.url, '/api/app/download');

    const download = await fetch(`${server.url}/api/app/download`, {
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    assert.equal(download.status, 200);
    assert.match(download.headers.get('content-type'), /android\.package-archive/);
    assert.deepEqual(Buffer.from(await download.arrayBuffer()), apk);

    const unauthorized = await fetch(`${server.url}/api/app/latest`);
    assert.equal(unauthorized.status, 401);
  } finally {
    await server.close();
    fs.rmSync(appDir, { recursive: true, force: true });
  }
});

test('OTA: 404 si no hay actualización publicada', async () => {
  const emptyDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openterritorio-empty-'));
  const server = await startServer({ appDir: emptyDir });
  try {
    const latest = await getJson(server.url, '/api/app/latest');
    assert.equal(latest.status, 404);
    assert.equal(latest.body.ok, false);

    const download = await fetch(`${server.url}/api/app/download`, {
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    assert.equal(download.status, 404);
  } finally {
    await server.close();
    fs.rmSync(emptyDir, { recursive: true, force: true });
  }
});
