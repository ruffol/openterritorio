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
 * Extrae publicaciones del HTML que Facebook sirve con sesión iniciada (www/m):
 * cada post lleva `data-utime` (hora exacta) y bloques `dir="auto"` con el texto.
 */
function extraerDeHtmlConSesion(html, fuente) {
  const notas = [];
  const marcas = [...html.matchAll(/data-utime="(\d{9,11})"/g)];
  const vistos = new Set();
  for (let i = 0; i < marcas.length; i += 1) {
    const cuando = Number(marcas[i][1]);
    const inicio = marcas[i].index;
    const fin = i + 1 < marcas.length ? marcas[i + 1].index : Math.min(html.length, inicio + 8000);
    const bloque = html.slice(inicio, fin);
    const id = (bloque.match(/\/posts\/(\d+)/) || [])[1] || String(cuando);
    if (vistos.has(id)) continue;

    const textos = [...bloque.matchAll(/<div[^>]*dir="auto"[^>]*>([\s\S]*?)<\/div>/g)]
      .map((m) => decodificar(m[1]))
      .filter((t) => t.length > 30);
    const texto = textos.join(' ').trim();
    if (texto.length < 60) continue;
    vistos.add(id);
    notas.push({
      texto,
      titulo: texto.slice(0, 200),
      fuente,
      url: `https://www.facebook.com/${fuente}/posts/${id}`,
      publicado: cuando * 1000,
      yaCompleta: true,
    });
  }
  return notas;
}

const HOSTS = (fuente) => [
  { nombre: 'mbasic', url: `https://mbasic.facebook.com/${fuente}`, extraer: extraerPublicaciones, ua: UA },
  {
    nombre: 'm',
    url: `https://m.facebook.com/${fuente}?v=timeline&locale=es_LA`,
    extraer: extraerDeHtmlConSesion,
    ua: 'Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Mobile Safari/537.36',
  },
  {
    nombre: 'www',
    url: `https://www.facebook.com/${fuente}/posts/?locale=es_LA`,
    extraer: extraerDeHtmlConSesion,
    ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
  },
];

/**
 * Intenta las tres versiones del sitio en orden y devuelve la primera que traiga
 * publicaciones, con el diagnóstico de cada intento.
 * @returns {Promise<{ok:boolean, notas:Array, motivo?:string, intentos:Array}>}
 */
async function leerPagina(fuente) {
  const cookie = leerCookie();
  if (!cookie) {
    return { ok: false, notas: [], motivo: 'sin cookie de sesión (FB_COOKIE)', intentos: [] };
  }

  const intentos = [];
  for (const host of HOSTS(fuente)) {
    let respuesta;
    try {
      respuesta = await fetch(host.url, {
        headers: {
          'User-Agent': host.ua,
          Cookie: cookie,
          'Accept-Language': 'es-MX,es;q=0.9',
          Accept: 'text/html,application/xhtml+xml',
        },
        redirect: 'follow',
        signal: AbortSignal.timeout(25000),
      });
    } catch (error) {
      intentos.push({ host: host.nombre, error: error.message });
      continue;
    }

    const html = await respuesta.text();
    const bajo = html.toLowerCase();
    if (bajo.includes('checkpoint') || bajo.includes('/login/?next')) {
      intentos.push({ host: host.nombre, motivo: 'muro de login o checkpoint', bytes: html.length });
      continue;
    }
    const notas = host.extraer(html, fuente);
    intentos.push({ host: host.nombre, status: respuesta.status, bytes: html.length, notas: notas.length });
    if (notas.length > 0) return { ok: true, notas, intentos };
  }

  return {
    ok: false,
    notas: [],
    motivo: intentos.map((i) => `${i.host}: ${i.motivo || i.error || `${i.notas || 0} notas de ${i.bytes} bytes`}`).join(' · '),
    intentos,
  };
}

module.exports = { leerPagina, extraerPublicaciones, extraerDeHtmlConSesion, leerCookie };

// Prueba rápida de la cookie:  node fb.js --probar afmedios
if (require.main === module) {
  (async () => {
    const argv = process.argv.slice(2);
    const pagina = argv[argv.indexOf('--probar') + 1] || 'afmedios';
    const cookie = leerCookie();
    if (!cookie) {
      console.error('sin cookie: guarda "c_user=...; xs=...; datr=...; sb=..." en .fb_cookie');
      process.exit(1);
    }
    const r = await leerPagina(pagina);
    console.log(r.ok ? `${pagina}: ${r.notas.length} publicaciones` : `${pagina}: fallo`);
    for (const intento of r.intentos) console.log('  ', JSON.stringify(intento));
    if (r.ok) for (const n of r.notas.slice(0, 5)) console.log('   ·', n.texto.replace(/\s+/g, ' ').slice(0, 120));
  })();
}
