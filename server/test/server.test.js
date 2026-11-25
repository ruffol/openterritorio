'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');

// En Windows el `tar` del PATH puede ser el GNU de git-bash, que interpreta
// "C:\..." como un host remoto. bsdtar de System32 hace lo correcto.
const TAR = process.platform === 'win32' && fs.existsSync('C:/Windows/System32/tar.exe')
  ? 'C:/Windows/System32/tar.exe'
  : 'tar';
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
    monitorEnabled: false,
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
      headers: { Authorization: 'Bearer ' + TOKEN },
    });
    assert.equal(download.status, 404);
  } finally {
    await server.close();
    fs.rmSync(emptyDir, { recursive: true, force: true });
  }
});

test('POST /api/events recorta por bytes UTF-8, no por unidades UTF-16', async () => {
  const server = await startServer();
  try {
    // 51 caracteres con acentos = 53 bytes; con el corte anterior por
    // `slice(0, 64)` una nota de este estilo pasaba el límite de 64 bytes del
    // contrato y el endpoint respondía 400 "short_note exceeds 64 bytes".
    const long = 'Punto de reunión en el jardín principal de Villa de Álvarez, evacuar';
    assert.ok(Buffer.byteLength(long, 'utf8') > 64);

    const created = await getJson(server.url, '/api/events', TOKEN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ lat: 19.2433, lon: -103.7247, short_note: long }),
    });
    assert.equal(created.status, 201);

    const state = await getJson(server.url, '/api/state');
    const note = state.body.events[0].short_note;
    assert.ok(Buffer.byteLength(note, 'utf8') <= 64, 'la nota no debe pasar de 64 bytes');
    assert.ok(long.startsWith(note), 'el recorte no debe alterar los caracteres');
    assert.ok(!note.includes('\uFFFD'), 'no debe quedar un carácter partido');
  } finally {
    await server.close();
  }
});

test('el mismo límite se aplica al título de una alerta', async () => {
  const server = await startServer();
  try {
    const long = 'Desalojo preventivo por derrumbe en la colonia Centro de Colima';
    const created = await getJson(server.url, '/api/alerts', TOKEN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ severity: 3, lat: 19.24, lon: -103.72, title: long }),
    });
    assert.equal(created.status, 201);

    const state = await getJson(server.url, '/api/state');
    const title = state.body.alerts[0].title;
    assert.ok(Buffer.byteLength(title, 'utf8') <= 64);
    assert.ok(long.startsWith(title));
  } finally {
    await server.close();
  }
});

test('prune purga eventos, alertas y pares caducados (no solo tracks)', async () => {
  const server = await startServer();
  try {
    await getJson(server.url, '/api/events', TOKEN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ lat: 19.24, lon: -103.72, short_note: 'evento viejo' }),
    });
    await getJson(server.url, '/api/alerts', TOKEN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ severity: 2, lat: 19.24, lon: -103.72, title: 'alerta vieja' }),
    });
    const a = await connect(server.wsUrl);
    a.ws.send(proto.encode(positionPacket(301, 'b7b2c3d4e5f60708')));
    await new Promise((resolve) => setTimeout(resolve, 200));
    a.close();

    const before = server.rt.repo.counts();
    assert.equal(before.events, 1);
    assert.equal(before.alerts, 1);
    assert.equal(before.peers, 1);

    const removed = server.rt.repo.prune(Date.now() + 1000, 0, 0, {
      eventTtlMs: 0,
      peerTtlMs: 0,
    });
    assert.equal(removed.events, 1);
    assert.equal(removed.alerts, 1);
    assert.equal(removed.peers, 1);
    assert.deepEqual(server.rt.repo.counts(), {
      peers: 0,
      events: 0,
      alerts: 0,
      tracks: 0,
      packets_seen: 0,
    });
  } finally {
    await server.close();
  }
});

test('OTA: subida remota por HTTPS con token actualiza el manifiesto', async () => {
  const appDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openterritorio-upload-'));
  const server = await startServer({ appDir });
  const apk = Buffer.from('APK-SUBIDO-POR-HTTPS-0123456789');
  const sha256 = crypto.createHash('sha256').update(apk).digest('hex');
  try {
    const url = `${server.url}/api/app/upload?version=9.9.9&version_code=99&sha256=${sha256}&notes=subida%20remota`;
    const uploaded = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + TOKEN,
        'Content-Type': 'application/octet-stream',
      },
      body: apk,
    });
    assert.equal(uploaded.status, 201);
    const body = await uploaded.json();
    assert.equal(body.version, '9.9.9');
    assert.equal(body.size_bytes, apk.length);
    assert.equal(body.sha256, sha256);

    const latest = await getJson(server.url, '/api/app/latest');
    assert.equal(latest.status, 200);
    assert.equal(latest.body.version_code, 99);
    assert.equal(latest.body.notes, 'subida remota');

    const download = await fetch(`${server.url}/api/app/download`, {
      headers: { Authorization: 'Bearer ' + TOKEN },
    });
    assert.equal(download.status, 200);
    assert.deepEqual(Buffer.from(await download.arrayBuffer()), apk);
  } finally {
    await server.close();
    fs.rmSync(appDir, { recursive: true, force: true });
  }
});

test('OTA: la subida remota rechaza sha256 incorrecto y token ausente', async () => {
  const appDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openterritorio-upload-bad-'));
  const server = await startServer({ appDir });
  const apk = Buffer.from('APK-DISTINTO');
  const wrong = 'a'.repeat(64);
  try {
    const bad = await fetch(
      `${server.url}/api/app/upload?version=1.0.0&version_code=1&sha256=${wrong}`,
      {
        method: 'POST',
        headers: {
          Authorization: 'Bearer ' + TOKEN,
          'Content-Type': 'application/octet-stream',
        },
        body: apk,
      },
    );
    assert.equal(bad.status, 400);
    assert.equal((await bad.json()).error, 'sha256 no coincide');
    assert.equal(fs.existsSync(path.join(appDir, 'latest.json')), false);

    const sha = crypto.createHash('sha256').update(apk).digest('hex');
    const anon = await fetch(
      `${server.url}/api/app/upload?version=1.0.0&version_code=1&sha256=${sha}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/octet-stream' },
        body: apk,
      },
    );
    assert.equal(anon.status, 401);
  } finally {
    await server.close();
    fs.rmSync(appDir, { recursive: true, force: true });
  }
});

test('los puntos fijos se sirven y se pueden cambiar por API (sin tocar la app)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'openterritorio-landmarks-'));
  const server = await startServer({ landmarksFile: path.join(dir, 'landmarks.json') });
  try {
    const initial = await getJson(server.url, '/api/landmarks');
    assert.equal(initial.status, 200);
    assert.equal(initial.body.landmarks.length, 3);
    const sangre = initial.body.landmarks.find((l) => l.name === 'SANGRE');
    assert.equal(sangre.radius_m, 500);
    assert.deepEqual(sangre.colors, ['#FF3B30', '#1E90FF']);
    const marron = initial.body.landmarks.find((l) => l.name === 'MARRÓN');
    assert.equal(marron.radius_m, 100);
    assert.deepEqual(marron.colors, ['#A0522D']);

    const updated = await getJson(server.url, '/api/landmarks', TOKEN, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        landmarks: [
          { name: 'SANGRE', lat: 19.2551, lon: -103.7294, emoji: '🩸', radius_m: 800, colors: ['#FF0000', '#0000FF'] },
        ],
      }),
    });
    assert.equal(updated.status, 200);
    assert.equal(updated.body.landmarks[0].radius_m, 800);

    const after = await getJson(server.url, '/api/landmarks');
    assert.equal(after.body.landmarks.length, 1);
    assert.equal(after.body.landmarks[0].radius_m, 800);
    assert.equal(fs.existsSync(path.join(dir, 'landmarks.json')), true);

    const bad = await getJson(server.url, '/api/landmarks', TOKEN, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ landmarks: [{ name: 'X', lat: 999, lon: 0 }] }),
    });
    assert.equal(bad.status, 400);

    const anonymous = await fetch(`${server.url}/api/landmarks`);
    assert.equal(anonymous.status, 401);
  } finally {
    await server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('OTA: subida por trozos publica solo cuando llega el último', async () => {
  const appDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openterritorio-chunks-'));
  const server = await startServer({ appDir });
  const apk = Buffer.from('APK-GRANDE-'.repeat(40) + 'FIN');
  const sha256 = crypto.createHash('sha256').update(apk).digest('hex');
  const query = `version=2.0.0&version_code=200&sha256=${sha256}&size=${apk.length}`;
  const headers = {
    Authorization: 'Bearer ' + TOKEN,
    'Content-Type': 'application/octet-stream',
  };
  const half = Math.floor(apk.length / 2);
  try {
    const first = await fetch(`${server.url}/api/app/upload?${query}&offset=0`, {
      method: 'POST',
      headers,
      body: apk.subarray(0, half),
    });
    assert.equal(first.status, 202);
    assert.equal((await first.json()).received, half);

    const none = await getJson(server.url, '/api/app/latest');
    assert.equal(none.status, 404, 'no debe publicarse con el APK a medias');

    const second = await fetch(`${server.url}/api/app/upload?${query}&offset=${half}`, {
      method: 'POST',
      headers,
      body: apk.subarray(half),
    });
    assert.equal(second.status, 201);
    const body = await second.json();
    assert.equal(body.size_bytes, apk.length);
    assert.equal(body.sha256, sha256);

    const latest = await getJson(server.url, '/api/app/latest');
    assert.equal(latest.status, 200);
    assert.equal(latest.body.version_code, 200);
  } finally {
    await server.close();
    fs.rmSync(appDir, { recursive: true, force: true });
  }
});


test('despliegue remoto: rechaza sha256 y sintaxis inválida, acepta lo válido', async () => {
  const deployDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ot-deploy-dir-'));
  const server = await startServer({ deployDir });
  const headers = { Authorization: 'Bearer ' + TOKEN };

  // Tarball de mentira con un .js válido y otro roto.
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'ot-stage-'));
  fs.mkdirSync(path.join(stage, 'app', 'src'), { recursive: true });
  fs.writeFileSync(path.join(stage, 'app', 'src', 'server.js'), "require('./ok');\n");
  fs.writeFileSync(path.join(stage, 'app', 'src', 'ok.js'), 'module.exports = 1;\n');
  const tarball = path.join(stage, 'ok.tar.gz');
  const tarOk = spawnSync(TAR, ['-czf', tarball, '-C', stage, '.']);
  assert.equal(tarOk.status, 0);

  const data = fs.readFileSync(tarball);
  const sha = crypto.createHash('sha256').update(data).digest('hex');

  try {
    const sinSha = await fetch(`${server.url}/api/admin/deploy?version=x`, {
      method: 'POST', headers, body: data,
    });
    assert.equal(sinSha.status, 400);

    const malSha = await fetch(`${server.url}/api/admin/deploy?sha256=${'f'.repeat(64)}&version=x`, {
      method: 'POST', headers, body: data,
    });
    assert.equal(malSha.status, 400);
    assert.equal(fs.existsSync(path.join(deployDir, 'openterritorio.stamp')), false);

    // Sintaxis rota: se rechaza y no deja sello.
    fs.writeFileSync(path.join(stage, 'app', 'src', 'roto.js'), 'function ( {\n');
    const badTar = path.join(stage, 'bad.tar.gz');
    spawnSync(TAR, ['-czf', badTar, '-C', stage, '.']);
    const badData = fs.readFileSync(badTar);
    const badSha = crypto.createHash('sha256').update(badData).digest('hex');
    const roto = await fetch(`${server.url}/api/admin/deploy?sha256=${badSha}&version=x`, {
      method: 'POST', headers, body: badData,
    });
    assert.equal(roto.status, 400);
    assert.match((await roto.json()).error, /sintaxis/);
    assert.equal(fs.existsSync(path.join(deployDir, 'openterritorio.stamp')), false);

    // El bueno: deja tarball, sello y respaldo.
    const ok = await fetch(`${server.url}/api/admin/deploy?sha256=${sha}&version=prueba`, {
      method: 'POST', headers, body: data,
    });
    assert.equal(ok.status, 202);
    const body = await ok.json();
    assert.equal(body.version, 'prueba');
    assert.equal(fs.existsSync(path.join(deployDir, 'openterritorio.tar.gz')), true);
    assert.equal(fs.readFileSync(path.join(deployDir, 'openterritorio.stamp'), 'utf8').startsWith('prueba-'), true);

    const info = await fetch(`${server.url}/api/admin/version`, { headers }).then((r) => r.json());
    assert.equal(info.deployed.version, 'prueba');

    const sinToken = await fetch(`${server.url}/api/admin/deploy?sha256=${sha}`, {
      method: 'POST', body: data,
    });
    assert.equal(sinToken.status, 401);
  } finally {
    fs.rmSync(stage, { recursive: true, force: true });
    fs.rmSync(deployDir, { recursive: true, force: true });
    await server.close();
  }
});


test('un evento con ttl_horas desaparece cuando caduca', async () => {
  const server = await startServer();
  const headers = {
    Authorization: 'Bearer ' + TOKEN,
    'Content-Type': 'application/json',
  };
  try {
    const creado = await fetch(`${server.url}/api/events`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        lat: 19.2433,
        lon: -103.7247,
        category_id: 2,
        short_note: 'Choque con caducidad',
        ttl_horas: 1,
      }),
    });
    assert.equal(creado.status, 201);
    const body = await creado.json();
    assert.ok(body.expires_ms > Date.now(), 'debe traer caducidad');

    const estado = await getJson(server.url, '/api/state');
    const evento = estado.body.events.find((e) => e.short_note === 'Choque con caducidad');
    assert.ok(evento, 'el evento debe estar visible');
    assert.ok(evento.expires_ms > Date.now());

    // Dos horas después ya cumplió su hora y se borra sin tocar el TTL global.
    const borrado = server.rt.repo.prune(Date.now() + 2 * 3600_000, 86400_000, 86400_000, {
      eventTtlMs: 86400_000,
    });
    assert.ok(borrado.expirados >= 1);

    const despues = await getJson(server.url, '/api/state');
    assert.equal(
      despues.body.events.filter((e) => e.short_note === 'Choque con caducidad').length,
      0,
    );
  } finally {
    await server.close();
  }
});


test('el evento guarda la cita y las fuentes, y se puede borrar', async () => {
  const server = await startServer();
  const headers = { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json' };
  try {
    const creado = await fetch(`${server.url}/api/events`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        lat: 19.2433,
        lon: -103.7247,
        category_id: 2,
        short_note: 'Accidente vial · Colima (aprox)',
        texto: 'Una camioneta volcó sobre el libramiento; el conductor fue trasladado.',
        fuentes: ['afmedios', 'colimanoticias'],
        ttl_horas: 24,
      }),
    });
    assert.equal(creado.status, 201);

    const lista = await getJson(server.url, '/api/events');
    const evento = lista.body.events.find((e) => e.short_note.startsWith('Accidente vial · Colima'));
    assert.ok(evento, 'el evento debe estar en la lista');
    assert.match(evento.texto, /camioneta volcó/);
    assert.deepEqual(evento.fuentes, ['afmedios', 'colimanoticias']);

    const borrado = await fetch(`${server.url}/api/events/${evento.packet_id}`, {
      method: 'DELETE',
      headers,
    });
    assert.equal((await borrado.json()).borrados, 1);
    const despues = await getJson(server.url, '/api/events');
    assert.equal(
      despues.body.events.filter((e) => e.packet_id === evento.packet_id).length,
      0,
    );
  } finally {
    await server.close();
  }
});

test('un cliente que inunda el WebSocket se cierra con 1008', async () => {
  const server = await startServer({ wsRateMax: 5, wsRateWindowMs: 60000 });
  const client = await connect(server.wsUrl);
  try {
    const closed = new Promise((resolve) => client.ws.on('close', (code) => resolve(code)));
    for (let i = 0; i < 40; i += 1) {
      client.ws.send(proto.encode(positionPacket(400 + i, `${(0x10 + i).toString(16)}bb2c3d4e5f60708`)));
    }
    const code = await Promise.race([
      closed,
      new Promise((resolve) => setTimeout(() => resolve(-1), 3000)),
    ]);
    assert.equal(code, 1008, 'debe cerrarse por límite de ritmo');
  } finally {
    client.close();
    await server.close();
  }
});
