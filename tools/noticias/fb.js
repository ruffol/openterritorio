'use strict';

/**
 * Lectura de páginas de Facebook con la sesión de una cuenta secundaria.
 *
 * La cookie se lee de `FB_COOKIE` o de un archivo local; nunca se escribe aquí
 * ni se sube al repositorio. Formato: "c_user=123; xs=abc123..."
 *
 * Sin cookie disponible el módulo no hace nada: el monitor sigue con los RSS.
 * Con cookie, se pide la versión ligera y se extraen los bloques de texto de
 * cada publicación. Si Facebook responde con muro de login o checkpoint se
 * informa el motivo en vez de devolver una lista vacía sin explicación.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const UA =
  'Mozilla/5.0 (Linux; Android 11; SM-A105M) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

const ARCHIVOS = [
  process.env.FB_COOKIE_FILE,
  path.join(__dirname, '.fb_cookie'),
  path.join(os.homedir(), 'openterritorio', 'fb_cookie.txt'),
].filter(Boolean);

function leerCookie() {
  if (process.env.FB_COOKIE) return process.env.FB_COOKIE.trim();
  for (const archivo of ARCHIVOS) {
    try {
      const texto = fs.readFileSync(archivo, 'utf8').trim();
      if (texto) return texto;
    } catch {
      // probar el siguiente
    }
  }
  return '';
}

function decodificar(html) {
  return String(html || '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/[ \t]+/g, ' ')
    .trim();
}

/**
 * Saca las publicaciones de una página. mbasic pone cada post en un bloque con
 * enlace `story_fbid`; se corta el HTML por esos enlaces y se limpia el texto.
 */
function extraerPublicaciones(html, fuente) {
  const notas = [];
  const marcas = [...html.matchAll(/href="[^"]*?(?:story_fbid=|story\.php\?[^"]*?id=)(\d+)[^"]*"/g)];
  const vistos = new Set();

  for (let i = 0; i < marcas.length; i++) {
    const id = marcas[i][1];
    if (vistos.has(id)) continue;
    const inicio = marcas[i].index;
    const fin = i + 1 < marcas.length ? marcas[i + 1].index : html.length;
    if (fin - inicio < 200) continue;
    vistos.add(id);

    const bloque = html.slice(inicio, Math.min(fin, inicio + 6000));
    const texto = decodificar(bloque.replace(/<script[\s\S]*?<\/script>/gi, ' '));
    if (texto.length < 120) continue;
    notas.push({ texto, fuente, url: `https://www.facebook.com/${fuente}/posts/${id}`, id });
  }
  return notas;
}

/**
 * @returns {Promise<{ok:boolean, notas:Array, motivo?:string}>}
 */
async function leerPagina(fuente) {
  const cookie = leerCookie();
  if (!cookie) return { ok: false, notas: [], motivo: 'sin cookie de sesión (FB_COOKIE)' };

  const url = `https://mbasic.facebook.com/${fuente}`;
  let respuesta;
  try {
    respuesta = await fetch(url, {
      headers: {
        'User-Agent': UA,
        Cookie: cookie,
        'Accept-Language': 'es-MX,es;q=0.9',
      },
      redirect: 'follow',
    });
  } catch (error) {
    return { ok: false, notas: [], motivo: `error de red: ${error.message}` };
  }

  const html = await respuesta.text();
  const bajo = html.toLowerCase();
  if (bajo.includes('checkpoint') || bajo.includes('/login/?next')) {
    return { ok: false, notas: [], motivo: `sesión rechazada (HTTP ${respuesta.status}); renueva la cookie` };
  }
  if (!respuesta.ok) {
    return { ok: false, notas: [], motivo: `HTTP ${respuesta.status} (${html.length} bytes)` };
  }

  const notas = extraerPublicaciones(html, fuente);
  if (notas.length === 0) {
    return { ok: false, notas: [], motivo: `sin publicaciones reconocibles (${html.length} bytes)` };
  }
  return { ok: true, notas };
}

module.exports = { leerPagina, extraerPublicaciones, leerCookie };
