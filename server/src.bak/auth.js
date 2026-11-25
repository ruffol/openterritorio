'use strict';

const crypto = require('node:crypto');

/**
 * Autenticación por token con límite de fallos por IP.
 * El token viaja en Authorization: Bearer o en ?token= (WebSocket).
 */
function createAuth({ token, failWindowMs = 60000, failMax = 20 }) {
  if (!token) throw new Error('TOKEN is required');

  const failures = new Map();

  function safeEqual(a, b) {
    const left = Buffer.from(String(a));
    const right = Buffer.from(String(b));
    if (left.length !== right.length) return false;
    return crypto.timingSafeEqual(left, right);
  }

  function allowed(ip) {
    const record = failures.get(ip);
    if (!record) return true;
    if (Date.now() - record.start > failWindowMs) {
      failures.delete(ip);
      return true;
    }
    return record.count < failMax;
  }

  function verify(candidate, ip) {
    const key = ip || 'unknown';
    if (!allowed(key)) return false;
    if (candidate && safeEqual(candidate, token)) return true;

    const now = Date.now();
    let record = failures.get(key);
    if (!record || now - record.start > failWindowMs) {
      record = { start: now, count: 0 };
    }
    record.count += 1;
    failures.set(key, record);
    return false;
  }

  return { verify, allowed };
}

module.exports = { createAuth };
