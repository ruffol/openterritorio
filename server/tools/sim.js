'use strict';

/**
 * Simulador de pares para OPENTERITORIO.
 *
 * Uso:
 *   node tools/sim.js --url ws://192.168.100.3:3000/ws --token XXX \
 *        --peers 3 --duration 60 --interval 5000 --lat 19.2433 --lon -103.7247
 *
 * --once envía una posición por par y termina.
 */

const WebSocket = require('ws');
const proto = require('../src/proto');

const args = process.argv.slice(2);
function arg(name, fallback) {
  const index = args.indexOf(`--${name}`);
  return index >= 0 && args[index + 1] !== undefined ? args[index + 1] : fallback;
}

const wsUrl = arg('url', 'ws://127.0.0.1:3000/ws');
const token = arg('token', process.env.TOKEN || '');
const peerCount = Math.max(1, Number(arg('peers', 2)));
const durationMs = Math.max(0, Number(arg('duration', 30)) * 1000);
const intervalMs = Math.max(500, Number(arg('interval', 5000)));
const baseLat = Number(arg('lat', 19.2433));
const baseLon = Number(arg('lon', -103.7247));
const once = args.includes('--once');

if (!token) {
  console.error('Falta --token (o variable TOKEN).');
  process.exit(2);
}

let received = 0;
let sent = 0;
const clients = [];

function positionFor(peer, tick) {
  const drift = peer * 0.0005 + tick * 0.00001;
  return {
    packet_id: require('node:crypto').randomBytes(8),
    sender_id: 1000 + peer,
    timestamp: Math.floor(Date.now() / 1000),
    hop_limit: 3,
    type: 0,
    position: {
      latitude_e7: Math.round((baseLat + drift) * 1e7),
      longitude_e7: Math.round((baseLon - drift) * 1e7),
      altitude_m: 500 + peer,
      speed_cms: 800 + peer * 200,
      heading_deg: (peer * 47) % 360,
      battery_pct: Math.max(10, 95 - peer * 5),
    },
  };
}

function connectPeer(peer) {
  return new Promise((resolve, reject) => {
    const url = `${wsUrl}?token=${encodeURIComponent(token)}&transport=sim`;
    const ws = new WebSocket(url);
    ws.on('open', () => {
      console.log(`[par ${peer}] conectado`);
      resolve(ws);
    });
    ws.on('message', (data) => {
      received += 1;
      const packet = proto.decode(Buffer.from(data));
      console.log(
        `[par ${peer}] <- ${proto.PACKET_TYPE_NAME[packet.type]} de ${packet.sender_id}`,
      );
    });
    ws.on('error', (err) => {
      console.error(`[par ${peer}] error: ${err.message}`);
      reject(err);
    });
  });
}

async function main() {
  for (let peer = 0; peer < peerCount; peer += 1) {
    clients.push(await connectPeer(peer));
  }

  let tick = 0;
  function tickOnce() {
    for (let peer = 0; peer < clients.length; peer += 1) {
      const ws = clients[peer];
      if (ws.readyState !== WebSocket.OPEN) continue;
      ws.send(proto.encode(positionFor(peer, tick)));
      sent += 1;
    }
    tick += 1;
  }

  if (once) {
    tickOnce();
    await new Promise((resolve) => setTimeout(resolve, 1500));
  } else {
    tickOnce();
    const timer = setInterval(tickOnce, intervalMs);
    await new Promise((resolve) => setTimeout(resolve, durationMs));
    clearInterval(timer);
  }

  const summary = { pares: clients.length, enviados: sent, recibidos: received };
  for (const ws of clients) ws.close();
  console.log(JSON.stringify(summary));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
