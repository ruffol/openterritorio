'use strict';

const { WebSocketServer, WebSocket } = require('ws');

/**
 * Servidor WebSocket sobre el mismo puerto HTTP.
 * - Autenticación por token en el handshake (?token=...).
 * - Solo frames binarios (protobuf).
 * - Ping/pong cada 30 s y descarte de clientes lentos.
 */
function createHub({
  server,
  auth,
  maxClients,
  maxPayloadBytes,
  log,
  onPacket,
  rateMax = 60,
  rateWindowMs = 1000,
}) {
  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: maxPayloadBytes,
    perMessageDeflate: false,
  });
  const clients = new Set();
  let closed = false;

  server.on('upgrade', (req, socket, head) => {
    let url;
    try {
      url = new URL(req.url, 'http://localhost');
    } catch {
      socket.destroy();
      return;
    }
    if (url.pathname !== '/ws') {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }

    const ip = req.headers['cf-connecting-ip'] || req.socket.remoteAddress || 'unknown';
    const token = url.searchParams.get('token') || '';
    if (!auth.verify(token, ip)) {
      log.warn('ws auth rejected', { ip });
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    if (clients.size >= maxClients) {
      log.warn('ws rejected: server full', { total: clients.size });
      socket.write('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit('connection', ws, req, url, ip);
    });
  });

  wss.on('connection', (ws, req, url, ip) => {
    const client = {
      ws,
      ip,
      transport: url.searchParams.get('transport') || 'ws',
      alive: true,
      senderId: null,
      received: 0,
      rateStart: Date.now(),
      rateCount: 0,
      rateWarned: false,
    };
    clients.add(client);

    ws.on('pong', () => {
      client.alive = true;
    });

    ws.on('message', (data, isBinary) => {
      if (!isBinary) {
        ws.close(1003, 'binary frames only');
        return;
      }
      // Límite por cliente: un solo emisor no puede saturar SQLite ni la
      // difusión a todos los pares (amplificación N-1).
      const now = Date.now();
      if (now - client.rateStart >= rateWindowMs) {
        client.rateStart = now;
        client.rateCount = 0;
      }
      client.rateCount += 1;
      if (client.rateCount > rateMax) {
        if (!client.rateWarned) {
          client.rateWarned = true;
          log.warn('ws rate limit exceeded', {
            ip: client.ip,
            limit: `${rateMax}/${rateWindowMs}ms`,
          });
        }
        ws.close(1008, 'rate limit');
        return;
      }
      client.received += 1;
      try {
        onPacket(Buffer.from(data), client);
      } catch (err) {
        log.warn('packet handler error', { err: err.message });
      }
    });

    ws.on('close', () => {
      clients.delete(client);
      log.info('ws closed', { transport: client.transport, total: clients.size });
    });
    ws.on('error', () => {
      clients.delete(client);
    });

    log.info('ws connected', { transport: client.transport, total: clients.size });
  });

  const heartbeat = setInterval(() => {
    for (const client of clients) {
      if (!client.alive) {
        client.ws.terminate();
        clients.delete(client);
        continue;
      }
      client.alive = false;
      try {
        client.ws.ping();
      } catch {
        /* socket ya cerrado */
      }
    }
  }, 30000);
  heartbeat.unref?.();

  function broadcast(buffer, except = null) {
    let sent = 0;
    for (const client of clients) {
      if (client === except) continue;
      if (client.ws.readyState !== WebSocket.OPEN) continue;
      if (client.ws.bufferedAmount > 512 * 1024) continue;
      try {
        client.ws.send(buffer);
        sent += 1;
      } catch {
        /* ignore */
      }
    }
    return sent;
  }

  function close() {
    if (closed) return;
    closed = true;
    clearInterval(heartbeat);
    for (const client of clients) {
      try {
        client.ws.terminate();
      } catch {
        /* ignore */
      }
    }
    clients.clear();
    wss.close();
  }

  return { wss, clients, broadcast, close };
}

module.exports = { createHub };
