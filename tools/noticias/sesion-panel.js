'use strict';

/**
 * Toma las cookies de Facebook de la sesión del panel de vista previa de Hermes
 * (Electron) y las deja en tools/noticias/.fb_cookie.
 *
 * Windows guarda los valores con AES-256-GCM; la clave está en `Local State`
 * protegida con DPAPI del usuario. Aquí solo se descifra, nunca se imprime.
 *
 * Uso:  node tools/noticias/sesion-panel.js <ruta-cookies> <ruta-clave-hex>
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const [, , rutaCookies, rutaClave] = process.argv;
if (!rutaCookies || !rutaClave) {
  console.error('uso: sesion-panel.js <Cookies> <clave-hex>');
  process.exit(1);
}

const clave = Buffer.from(fs.readFileSync(rutaClave, 'utf8').trim(), 'hex');
if (clave.length !== 32) {
  console.error(`la clave debe ser de 32 bytes (son ${clave.length})`);
  process.exit(1);
}

function descifrar(valor) {
  if (!valor || valor.length === 0) return '';
  // v10 / v11 = AES-256-GCM con nonce de 12 bytes y etiqueta de 16.
  const prefijo = valor.subarray(0, 3).toString();
  if (prefijo !== 'v10' && prefijo !== 'v11') return valor.toString('utf8');
  const nonce = valor.subarray(3, 15);
  const etiqueta = valor.subarray(valor.length - 16);
  const cifrado = valor.subarray(15, valor.length - 16);
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', clave, nonce);
    d.setAuthTag(etiqueta);
    return Buffer.concat([d.update(cifrado), d.final()]).toString('utf8');
  } catch (error) {
    return '';
  }
}

const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(rutaCookies, { readOnly: true });
const filas = db
  .prepare("SELECT host_key, name, encrypted_value, value FROM cookies WHERE host_key LIKE '%facebook%'")
  .all();

const buscadas = new Set(['c_user', 'xs', 'datr', 'sb', 'fr', 'wd', 'presence']);
const partes = [];
const encontradas = [];
for (const fila of filas) {
  if (!buscadas.has(fila.name)) continue;
  const valor = fila.value && fila.value.length > 0 ? String(fila.value) : descifrar(fila.encrypted_value);
  if (!valor) continue;
  partes.push(`${fila.name}=${valor}`);
  encontradas.push(fila.name);
}

if (!encontradas.includes('c_user') || !encontradas.includes('xs')) {
  console.error(`sin sesión utilizable: solo ${encontradas.join(', ') || 'ninguna cookie'}`);
  process.exit(2);
}

const destino = path.join(__dirname, '.fb_cookie');
fs.writeFileSync(destino, `${partes.join('; ')}\n`, { mode: 0o600 });
console.log(`cookie guardada (${partes.length} campos: ${encontradas.join(', ')}) en ${destino}`);
