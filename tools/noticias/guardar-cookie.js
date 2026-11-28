'use strict';

/**
 * Convierte una exportación de cookies (Cookie-Editor en JSON, formato
 * Netscape cookies.txt, o una cadena "c_user=...; xs=...") en la cookie que usa
 * el monitor, y la guarda en .fb_cookie con permisos 600.
 *
 * Uso:
 *   node tools/noticias/guardar-cookie.js cookies.json
 *   node tools/noticias/guardar-cookie.js "c_user=123; xs=abc"
 *   cat cookies.txt | node tools/noticias/guardar-cookie.js -
 */

const fs = require('node:fs');
const path = require('node:path');

const IMPORTANTES = ['c_user', 'xs', 'datr', 'sb', 'fr', 'wd', 'presence'];

function desdeJson(datos) {
  if (!Array.isArray(datos)) return null;
  const partes = [];
  for (const item of datos) {
    if (!item) continue;
    const nombre = item.name || item.nombre || item.key;
    const valor = item.value ?? item.valor;
    const dominio = String(item.domain || item.dominio || 'facebook.com');
    if (!nombre || valor === undefined || valor === null) continue;
    if (!/facebook\.com$/.test(dominio.replace(/^\./, ''))) continue;
    partes.push(`${nombre}=${valor}`);
  }
  return partes;
}

function desdeNetscape(texto) {
  const partes = [];
  for (const linea of texto.split(/\r?\n/)) {
    if (!linea || linea.startsWith('#')) continue;
    const campos = linea.split('\t');
    if (campos.length < 7) continue;
    const [dominio, , , , , nombre, valor] = campos;
    if (!/facebook\.com$/.test(String(dominio).replace(/^\./, ''))) continue;
    partes.push(`${nombre}=${valor}`);
  }
  return partes;
}

function desdeCadena(texto) {
  const limpio = texto.trim().replace(/^Cookie:\s*/i, '');
  if (!/[=;]/.test(limpio)) return null;
  return limpio
    .split(';')
    .map((p) => p.trim())
    .filter((p) => p.includes('='));
}

function convertir(entrada) {
  const texto = String(entrada || '').trim();
  let partes = null;

  try {
    partes = desdeJson(JSON.parse(texto));
  } catch {
    partes = null;
  }
  if (!partes || partes.length === 0) partes = desdeNetscape(texto);
  if (!partes || partes.length === 0) partes = desdeCadena(texto);
  return partes || [];
}

function principales(partes) {
  const mapa = new Map();
  for (const parte of partes) {
    const [nombre, ...resto] = parte.split('=');
    if (!nombre) continue;
    mapa.set(nombre.trim(), resto.join('='));
  }
  return IMPORTANTES.filter((n) => mapa.has(n)).map((n) => `${n}=${mapa.get(n)}`);
}

function main() {
  const fuente = process.argv[2];
  if (!fuente) {
    console.error('uso: guardar-cookie.js <archivo.json | "c_user=...; xs=..." | ->');
    process.exit(1);
  }
  const entrada = fuente === '-' ? fs.readFileSync(0, 'utf8') : (
    fs.existsSync(fuente) ? fs.readFileSync(fuente, 'utf8') : fuente
  );

  const partes = convertir(entrada);
  if (partes.length === 0) {
    console.error('no encontré cookies de facebook.com en la entrada');
    process.exit(2);
  }

  const nombres = partes.map((p) => p.split('=')[0]);
  const esenciales = principales(partes);
  if (!nombres.includes('c_user') || !nombres.includes('xs')) {
    console.error(`faltan c_user/xs (llegaron: ${nombres.join(', ')})`);
    process.exit(3);
  }

  const destino = path.join(__dirname, '.fb_cookie');
  fs.writeFileSync(destino, `${esenciales.join('; ')}\n`, { mode: 0o600 });
  console.log(`cookie guardada (${esenciales.length} campos: ${esenciales.map((p) => p.split('=')[0]).join(', ')}) en ${destino}`);
  console.log('siguiente paso: node tools/noticias/fb.js --probar afmedios');
}

main();
