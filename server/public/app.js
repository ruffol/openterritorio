'use strict';

const TOKEN_KEY = 'openterritorio.token';
const POLL_MS = 3000;
const DEFAULT_LAT = 19.2433;
const DEFAULT_LON = -103.7247;

const $ = (id) => document.getElementById(id);
const dot = $('dot');

let token = localStorage.getItem(TOKEN_KEY) || '';
let polling = null;
let lastState = null;

function fmtAge(ms) {
  if (ms < 0) return '—';
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d`;
}

function fmtCoord(value) {
  return Number(value).toFixed(6);
}

function setText(id, text) {
  const node = $(id);
  if (node) node.textContent = text;
}

function showLogin(message = '') {
  $('login').hidden = false;
  $('login-err').textContent = message;
  setTimeout(() => $('token').focus(), 50);
}

function hideLogin() {
  $('login').hidden = true;
}

async function api(path, options = {}) {
  const headers = Object.assign({}, options.headers || {});
  if (options.body && !headers['Content-Type']) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(path, { ...options, headers, cache: 'no-store' });
  if (response.status === 401) {
    showLogin('Token inválido o expirado.');
    throw new Error('unauthorized');
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

function cell(row, text, className) {
  const td = document.createElement('td');
  td.textContent = text;
  if (className) td.className = className;
  row.appendChild(td);
}

function renderPeers(peers) {
  const body = $('peers');
  body.textContent = '';
  if (!peers.length) {
    const row = document.createElement('tr');
    const td = document.createElement('td');
    td.colSpan = 8;
    td.className = 'empty';
    td.textContent = 'Sin pares todavía. Conecta un cliente por WebSocket.';
    row.appendChild(td);
    body.appendChild(row);
    return;
  }
  for (const peer of peers) {
    const row = document.createElement('tr');
    cell(row, String(peer.sender_id));
    cell(row, fmtCoord(peer.lat), 'mono');
    cell(row, fmtCoord(peer.lon), 'mono');
    cell(row, `${peer.speed_kmh.toFixed(1)} km/h`);
    cell(row, `${peer.heading_deg}°`);
    cell(row, `${peer.battery_pct}%`);
    cell(row, fmtAge(peer.age_ms), peer.age_ms > 120000 ? 'warn' : '');
    cell(row, peer.transport || 'ws');
    body.appendChild(row);
  }
}

function renderAlerts(alerts) {
  const list = $('alerts');
  list.textContent = '';
  if (!alerts.length) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = 'Sin alertas.';
    list.appendChild(li);
    return;
  }
  for (const alert of alerts) {
    const li = document.createElement('li');
    li.className = `item sev-${alert.severity}`;
    const title = document.createElement('div');
    title.className = 'item-title';
    title.textContent = alert.title || `Alerta ${alert.severity}`;
    const meta = document.createElement('div');
    meta.className = 'item-meta';
    meta.textContent = `${fmtCoord(alert.lat)}, ${fmtCoord(alert.lon)} · radio ${alert.radius_m} m · ${alert.ack_count} ACK · ${fmtAge(Date.now() - alert.created_ms)}`;
    li.appendChild(title);
    li.appendChild(meta);
    list.appendChild(li);
  }
}

function renderEvents(events) {
  const list = $('events');
  list.textContent = '';
  if (!events.length) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = 'Sin eventos.';
    list.appendChild(li);
    return;
  }
  for (const event of events) {
    const li = document.createElement('li');
    li.className = 'item';
    const title = document.createElement('div');
    title.className = 'item-title';
    title.textContent = event.short_note || `Evento ${event.category_id}`;
    const meta = document.createElement('div');
    meta.className = 'item-meta';
    meta.textContent = `${fmtCoord(event.lat)}, ${fmtCoord(event.lon)} · cat ${event.category_id} · ${fmtAge(Date.now() - event.created_ms)}`;
    li.appendChild(title);
    li.appendChild(meta);
    list.appendChild(li);
  }
}

function prefillCoords() {
  const peer = lastState && lastState.peers && lastState.peers[0];
  const lat = peer ? peer.lat : DEFAULT_LAT;
  const lon = peer ? peer.lon : DEFAULT_LON;
  for (const form of [$('alert-form'), $('event-form')]) {
    if (!form) continue;
    if (!form.elements.lat.value) form.elements.lat.value = lat.toFixed(7);
    if (!form.elements.lon.value) form.elements.lon.value = lon.toFixed(7);
  }
}

async function refresh() {
  try {
    const state = await api('/api/state');
    lastState = state;
    dot.className = 'dot ok';
    setText('c-peers', state.counts.peers);
    setText('c-events', state.counts.events);
    setText('c-alerts', state.counts.alerts);
    setText('c-tracks', state.counts.tracks);
    setText('updated', `actualizado ${new Date().toLocaleTimeString()}`);
    renderPeers(state.peers);
    renderAlerts(state.alerts);
    renderEvents(state.events);
    prefillCoords();
  } catch (err) {
    if (String(err.message) !== 'unauthorized') {
      dot.className = 'dot bad';
      setText('updated', `error: ${err.message}`);
    }
  }
}

async function loadHealth() {
  try {
    const health = await api('/api/health');
    setText('c-ws', health.ws_clients);
    setText('health', `v${health.version} · ${health.uptime_s}s · DB ${Math.round((health.db.size_bytes || 0) / 1024)} KB`);
    dot.className = 'dot ok';
  } catch {
    setText('health', 'sin conexión');
  }
}

function startPolling() {
  if (polling) clearInterval(polling);
  refresh();
  loadHealth();
  polling = setInterval(() => {
    refresh();
    loadHealth();
  }, POLL_MS);
}

function stopPolling() {
  if (polling) clearInterval(polling);
  polling = null;
}

async function submitJson(path, payload) {
  try {
    await api(path, { method: 'POST', body: JSON.stringify(payload) });
    await refresh();
  } catch (err) {
    if (String(err.message) !== 'unauthorized') alert(`No se pudo publicar: ${err.message}`);
  }
}

$('alert-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const form = event.target;
  submitJson('/api/alerts', {
    severity: Number(form.elements.severity.value),
    lat: Number(form.elements.lat.value),
    lon: Number(form.elements.lon.value),
    radius_m: Number(form.elements.radius_m.value) || 0,
    title: form.elements.title.value || 'Alerta',
  });
});

$('event-form').addEventListener('submit', (event) => {
  event.preventDefault();
  const form = event.target;
  submitJson('/api/events', {
    category_id: Number(form.elements.category_id.value) || 0,
    lat: Number(form.elements.lat.value),
    lon: Number(form.elements.lon.value),
    short_note: form.elements.short_note.value || 'Evento',
  });
});

$('login-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const candidate = $('token').value.trim();
  if (!candidate) return;
  token = candidate;
  try {
    await api('/api/state');
    localStorage.setItem(TOKEN_KEY, token);
    hideLogin();
    startPolling();
  } catch {
    token = '';
    showLogin('Token inválido.');
  }
});

$('logout').addEventListener('click', () => {
  token = '';
  localStorage.removeItem(TOKEN_KEY);
  stopPolling();
  showLogin('Sesión cerrada.');
});

setInterval(() => {
  setText('clock', new Date().toLocaleTimeString());
}, 1000);
setText('origin', location.host);

if (token) {
  hideLogin();
  startPolling();
} else {
  showLogin('');
}
$('logout').hidden = false;
