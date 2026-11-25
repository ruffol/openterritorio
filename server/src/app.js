'use strict';

const http = require('node:http');
const path = require('node:path');
const { buildConfig } = require('./config');
const { crearMonitor } = require('./monitor');
const { crearVigiaTunel } = require('./watchdog');
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
    rateMax: config.wsRateMax,
    rateWindowMs: config.wsRateWindowMs,
    log,
    onPacket: (buffer, client) => ingest.handle(buffer, client),
  });

  ingest = createIngest({ repo, hub, log });

  // El monitor de notas corre dentro del backend: si el servicio se reinicia,
  // él también, y su estado se consulta por HTTP.
  const monitor = crearMonitor({
    appRoot: path.resolve(process.cwd()),
    baseUrl: `http://127.0.0.1:${config.port}`,
    token: config.token,
    intervalMs: config.monitorIntervalMs,
    log,
  });

  const vigiaTunel = crearVigiaTunel({
    log,
    servicio: config.tunnelService,
    publicUrl: config.publicUrl,
  });

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
    monitor,
    vigiaTunel,
  });
  server.on('request', app);

  // Limpieza periódica de deduplicación e historial.
  const pruneTimer = setInterval(() => {
    try {
      const removed = repo.prune(Date.now(), config.seenTtlMs, config.trackTtlMs, {
        eventTtlMs: config.eventTtlMs,
        peerTtlMs: config.peerTtlMs,
      });
      if (Object.values(removed).some((n) => n > 0)) log.info('prune', removed);
    } catch (err) {
      log.warn('prune failed', { err: err.message });
    }
  }, 60 * 60 * 1000);
  pruneTimer.unref?.();

  try {
    repo.prune(Date.now(), config.seenTtlMs, config.trackTtlMs, {
      eventTtlMs: config.eventTtlMs,
      peerTtlMs: config.peerTtlMs,
    });
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
        if (config.monitorEnabled) monitor.arrancar();
        if (config.tunnelWatchdog) vigiaTunel.arrancar();
        resolve(address);
      });
    });
  }

  async function close() {
    clearInterval(pruneTimer);
    monitor.detener();
    vigiaTunel.detener();
    hub.close();
    if (server.listening) {
      await new Promise((resolve) => server.close(resolve));
    }
    repo.close();
    await log.close();
  }

  return { config, log, db, repo, auth, hub, ingest, app, server, start, close, monitor, vigiaTunel };
}

module.exports = { createRuntime };
