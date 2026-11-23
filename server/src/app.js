'use strict';

const http = require('node:http');
const path = require('node:path');
const { buildConfig } = require('./config');
const { createLogger } = require('./log');
const { openDatabase, createRepository } = require('./db');
const { createAuth } = require('./auth');
const { createHub } = require('./hub');
const { createIngest } = require('./ingest');
const { createHttpApp } = require('./rest');

/**
 * Construye el runtime completo. Es una fábrica para poder levantar varias
 * instancias en pruebas (puerto efímero, DB temporal, etc.).
 */
function createRuntime(overrides = {}) {
  const config = buildConfig(overrides);
  if (!config.token) {
    throw new Error('TOKEN es obligatorio (defínelo en .env o en el entorno)');
  }

  const startedAt = Date.now();
  const log = createLogger({ logFile: config.logFile, level: config.logLevel });
  const db = openDatabase(config.dbPath);
  const repo = createRepository(db);
  const auth = createAuth({
    token: config.token,
    failWindowMs: config.authFailWindowMs,
    failMax: config.authFailMax,
  });

  const server = http.createServer();
  let ingest = null;

  const hub = createHub({
    server,
    auth,
    maxClients: config.maxClients,
    maxPayloadBytes: config.maxPayloadBytes,
    log,
    onPacket: (buffer, client) => ingest.handle(buffer, client),
  });

  ingest = createIngest({ repo, hub, log });

  const publicDir = path.join(__dirname, '..', 'public');
  const app = createHttpApp({
    config,
    repo,
    auth,
    ingest,
    hub,
    log,
    publicDir,
    startedAt,
  });
  server.on('request', app);

  // Limpieza periódica de deduplicación e historial.
  const pruneTimer = setInterval(() => {
    try {
      const removed = repo.prune(Date.now(), config.seenTtlMs, config.trackTtlMs);
      if (removed.seen || removed.tracks) log.info('prune', removed);
    } catch (err) {
      log.warn('prune failed', { err: err.message });
    }
  }, 60 * 60 * 1000);
  pruneTimer.unref?.();

  try {
    repo.prune(Date.now(), config.seenTtlMs, config.trackTtlMs);
  } catch {
    /* la primera vez puede no haber nada que limpiar */
  }

  function start(port = config.port, host = config.host) {
    return new Promise((resolve, reject) => {
      const onError = (err) => reject(err);
      server.once('error', onError);
      server.listen(port, host, () => {
        server.off('error', onError);
        const address = server.address();
        log.info('listening', {
          host,
          port: address.port,
          pid: process.pid,
          public_url: config.publicUrl || null,
        });
        resolve(address);
      });
    });
  }

  async function close() {
    clearInterval(pruneTimer);
    hub.close();
    if (server.listening) {
      await new Promise((resolve) => server.close(resolve));
    }
    repo.close();
    await log.close();
  }

  return { config, log, db, repo, auth, hub, ingest, app, server, start, close };
}

module.exports = { createRuntime };
