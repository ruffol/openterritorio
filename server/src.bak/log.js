'use strict';

const fs = require('node:fs');
const path = require('node:path');

/**
 * Logger JSON-lines: escribe a stdout (capturado por runit/svlogd) y,
 * si se indica, a un archivo propio para el endpoint /api/logs.
 */
function createLogger({ logFile, level = 'info', maxBytes = 2 * 1024 * 1024 } = {}) {
  const weights = { debug: 10, info: 20, warn: 30, error: 40 };
  const min = weights[level] || weights.info;
  let stream = null;
  let pendingBytes = 0;

  function open() {
    stream = fs.createWriteStream(logFile, { flags: 'a' });
    stream.on('error', () => {
      stream = null;
    });
  }

  // Rotación por tamaño: el teléfono tiene 26 GB y el log crecía sin techo.
  // Se conserva una sola generación (`server.log.1`).
  function rotateIfNeeded() {
    if (!stream || !logFile) return;
    try {
      if (fs.statSync(logFile).size <= maxBytes) return;
      const old = stream;
      stream = null;
      old.end(() => {
        try {
          fs.renameSync(logFile, `${logFile}.1`);
        } catch {
          /* si no se puede rotar, se sigue escribiendo */
        }
        open();
      });
    } catch {
      /* stat falló: se sigue escribiendo */
    }
  }

  if (logFile) {
    fs.mkdirSync(path.dirname(logFile), { recursive: true });
    open();
  }

  function write(lvl, msg, extra) {
    if ((weights[lvl] || 0) < min) return;
    const record = { ts: new Date().toISOString(), level: lvl, msg };
    if (extra && typeof extra === 'object') {
      for (const key of Object.keys(extra)) record[key] = extra[key];
    }
    const line = `${JSON.stringify(record)}\n`;
    try {
      process.stdout.write(line);
    } catch {
      /* stdout cerrado */
    }
    if (stream) {
      stream.write(line);
      pendingBytes += line.length;
      if (pendingBytes >= 256 * 1024) {
        pendingBytes = 0;
        rotateIfNeeded();
      }
    }
  }

  return {
    debug: (msg, extra) => write('debug', msg, extra),
    info: (msg, extra) => write('info', msg, extra),
    warn: (msg, extra) => write('warn', msg, extra),
    error: (msg, extra) => write('error', msg, extra),
    close: () =>
      new Promise((resolve) => {
        if (!stream) return resolve();
        stream.end(resolve);
      }),
  };
}

module.exports = { createLogger };
