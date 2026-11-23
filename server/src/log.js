'use strict';

const fs = require('node:fs');
const path = require('node:path');

/**
 * Logger JSON-lines: escribe a stdout (capturado por runit/svlogd) y,
 * si se indica, a un archivo propio para el endpoint /api/logs.
 */
function createLogger({ logFile, level = 'info' } = {}) {
  const weights = { debug: 10, info: 20, warn: 30, error: 40 };
  const min = weights[level] || weights.info;
  let stream = null;

  if (logFile) {
    fs.mkdirSync(path.dirname(logFile), { recursive: true });
    stream = fs.createWriteStream(logFile, { flags: 'a' });
    stream.on('error', () => {
      stream = null;
    });
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
    if (stream) stream.write(line);
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
