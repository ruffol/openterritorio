'use strict';

/**
 * Prueba de extremo a extremo contra un servidor vivo (LAN o URL pública).
 *
 * Uso:
 *   node tools/e2e.js --url http://192.168.100.3:3000 --token XXX
 */

const WebSocket = require('ws');
const proto = require('../src/proto');

const args = process.argv.slice(2);
function arg(name, fallback) {
  const index = args.indexOf(`--${name}`);
  return index >= 0 && args[index + 1] !== undefined ? args[index + 1] : fallback;
}

const httpUrl = arg('url', 'http://127.0.0.1:3000').replace(/\/$/, '');
const token = arg('token', process.env.TOKEN || '');
const wsUrl = `${httpUrl.replace(/^http/, 'ws')}/ws`;

if (!token) {
  console.error('Falta --token (o variable TOKEN).');
  process.exit(2);
}

const results = [];
function check(name, ok, detail = '') {
  results.push({ name, ok });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}`);
}

function connect() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsUrl}?token=${encodeURIComponent(token)}`);
    const messages = [];
    ws.on('message', (data) => messages.push(Buffer.from(data)));
    ws.on('open', () => resolve({ ws, messages }));
    ws.on('unexpected-response', (req, res) => reject(new Error(`HTTP ${res.statusCode}`)));
    ws.on('error', reject);
  });
}

async function waitFor(predicate, timeout = 4000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
  throw new Error('timeout');
}

async function api(pathname, init = {}) {
  const response = await fetch(`${httpUrl}${pathname}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, ...(init.headers || {}) },
  });
  const body = await response.json().catch(() => ({}));
  return { status: response.status, body };
}

function packet(overrides) {
  return {
    packet_id: require('node:crypto').randomBytes(8),
    sender_id: 9001,
    timestamp: Math.floor(Date.now() / 1000),
    hop_limit: 3,
    ...overrides,
  };
}

async function main() {
  const health = await fetch(`${httpUrl}/healthz`);
  check('GET /healthz público', health.status === 200);

  const unauthorized = await fetch(`${httpUrl}/api/state`);
  check('REST sin token devuelve 401', unauthorized.status === 401);

  const state = await api('/api/state');
  check('REST /api/state con token', state.status === 200 && state.body.ok === true);

  const a = await connect();
  const b = await connect();
  check('dos clientes WebSocket conectados', true);

  const position = packet({
    type: 0,
    position: {
      latitude_e7: 192433000,
      longitude_e7: -1037247000,
      altitude_m: 520,
      speed_cms: 1500,
      heading_deg: 180,
      battery_pct: 66,
    },
  });
  const positionBytes = proto.encode(position);
  a.ws.send(positionBytes);
  await waitFor(() => b.messages.some((m) => proto.packetIdToHex(proto.decode(m).packet_id) === position.packet_id.toString('hex')));
  check('broadcast de posición', true, `${positionBytes.length} bytes`);

  a.ws.send(positionBytes);
  await new Promise((resolve) => setTimeout(resolve, 400));
  const duplicates = b.messages.filter((m) => proto.packetIdToHex(proto.decode(m).packet_id) === position.packet_id.toString('hex'));
  check('deduplicación', duplicates.length === 1, `${duplicates.length} copia(s)`);

  const event = packet({
    type: 1,
    event: {
      category_id: 4,
      latitude_e7: 192440000,
      longitude_e7: -1037250000,
      short_note: 'E2E evento',
    },
  });
  a.ws.send(proto.encode(event));
  await waitFor(() => b.messages.some((m) => proto.PACKET_TYPE_NAME[proto.decode(m).type] === 'USER_EVENT'));
  check('broadcast de evento', true);

  const alert = await api('/api/alerts', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ severity: 2, lat: 19.245, lon: -103.726, radius_m: 250, title: 'E2E alerta' }),
  });
  check('POST /api/alerts', alert.status === 201, alert.body.packet_id || '');
  await waitFor(() => b.messages.some((m) => proto.PACKET_TYPE_NAME[proto.decode(m).type] === 'SERVER_ALERT'));
  check('broadcast de alerta', true);

  const ackPacket = packet({
    type: 3,
    ack: { acked_packet_id: Buffer.from(alert.body.packet_id, 'hex') },
  });
  b.ws.send(proto.encode(ackPacket));
  await new Promise((resolve) => setTimeout(resolve, 300));
  const acks = await api(`/api/alerts/${alert.body.packet_id}/acks`);
  check('ACK registrado', acks.status === 200 && acks.body.acks.length >= 1);

  a.ws.close();
  b.ws.close();

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} pruebas OK`);
  process.exit(failed.length ? 1 : 0);
}

main().catch((err) => {
  console.error('E2E ERROR:', err.message);
  process.exit(1);
});
