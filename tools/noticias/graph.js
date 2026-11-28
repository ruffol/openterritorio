'use strict';

/**
 * Lectura de páginas de Facebook por la API oficial (Graph).
 *
 * A diferencia del scraping, esto no arriesga la cuenta: se usa un token de
 * aplicación con los permisos de páginas. El token se lee de FB_GRAPH_TOKEN o
 * de un archivo privado (.fb_token), nunca se escribe en el código ni se
 * registra en los logs.
 *
 * Comandos:
 *   node graph.js --probar              valida el token y lista las páginas
 *   node graph.js --volcar fb.json --horas 72
 *
 * Variables:
 *   FB_GRAPH_TOKEN   token de usuario o de página
 *   FB_GRAPH_VERSION v21.0 por omisión
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const VERSION = process.env.FB_GRAPH_VERSION || 'v21.0';
const BASE = `https://graph.facebook.com/${VERSION}`;

// Páginas vigiladas: se busca su id por nombre si el token no las lista.
const PAGINAS = [
  { nombre: 'afmedios', id: process.env.FB_PAGINA_AFMEDIOS || '' },
  { nombre: 'colimanoticias', id: process.env.FB_PAGINA_COLIMANOTICIAS || '' },
  { nombre: 'colimaenlanoticia', id: process.env.FB_PAGINA_COLIMAENLANOTICIA || '61578915771491' },
];

function token() {
  if (process.env.FB_GRAPH_TOKEN && process.env.FB_GRAPH_TOKEN.trim()) {
    return process.env.FB_GRAPH_TOKEN.trim();
  }
  const candidatos = [
    path.join(os.homedir(), 'openterritorio', '.fb_token'),
    path.join(__dirname, '.fb_token'),
  ];
  for (const archivo of candidatos) {
    try {
      const texto = fs.readFileSync(archivo, 'utf8').trim();
      if (texto) return texto;
    } catch {
      // se prueba el siguiente
    }
  }
  return '';
}

function disponible() {
  return token().length > 20;
}

async function pedir(ruta, parametros = {}, accessToken = null) {
  const url = new URL(`${BASE}/${ruta}`);
  for (const [clave, valor] of Object.entries(parametros)) {
    if (valor !== undefined && valor !== null && valor !== '') url.searchParams.set(clave, String(valor));
  }
  url.searchParams.set('access_token', accessToken || token());
  const respuesta = await fetch(url, { signal: AbortSignal.timeout(30000) });
  const datos = await respuesta.json().catch(() => ({}));
  if (!respuesta.ok || datos.error) {
    const mensaje = datos?.error?.message || `HTTP ${respuesta.status}`;
    const codigo = datos?.error?.code || respuesta.status;
    throw new Error(`${codigo}: ${mensaje}`);
  }
  return datos;
}

/** Páginas que el token puede leer, con su token de página. */
async function paginas() {
  const datos = await pedir('me/accounts', { fields: 'id,name,access_token', limit: 100 });
  return (datos.data || []).map((p) => ({ id: p.id, nombre: p.name, token: p.access_token }));
}

/**
 * Publicaciones de una página.
 * @returns {Promise<Array<{texto:string,url:string,publicado:number,imagen:string,fuente:string}>>}
 */
async function leerPagina(idPagina, opciones = {}) {
  const horas = Number(opciones.horas) || 72;
  const desde = Math.floor((Date.now() - horas * 3600_000) / 1000);
  const datos = await pedir(`${idPagina}/posts`, {
    fields: 'message,created_time,permalink_url,full_picture',
    since: desde,
    limit: Number(opciones.limite) || 100,
  }, opciones.token);

  const notas = [];
  for (const item of datos.data || []) {
    const texto = String(item.message || '').trim();
    if (texto.length < 40) continue;
    notas.push({
      titulo: texto.slice(0, 200),
      texto,
      fuente: `fb:${opciones.nombre || idPagina}`,
      url: item.permalink_url || `https://www.facebook.com/${idPagina}`,
      publicado: Date.parse(item.created_time || '') || Date.now(),
      imagen: item.full_picture || '',
      yaCompleta: true,
    });
  }
  return notas;
}

/** Todas las páginas vigiladas, tolerando que alguna falle. */
async function leerPaginassVigiladas(horas = 72) {
  if (!disponible()) return { ok: false, motivo: 'sin token (FB_GRAPH_TOKEN)', notas: [] };
  let lista = [];
  try {
    lista = await paginas();
  } catch (error) {
    return { ok: false, motivo: error.message, notas: [] };
  }
  const notas = [];
  const detalle = [];
  for (const pagina of lista) {
    const buscada = PAGINAS.find((p) => pagina.nombre.toLowerCase().includes(p.nombre));
    if (!buscada) continue;
    try {
      const suyas = await leerPagina(pagina.id, { horas, token: pagina.token, nombre: pagina.nombre });
      notas.push(...suyas);
      detalle.push({ pagina: pagina.nombre, notas: suyas.length });
    } catch (error) {
      detalle.push({ pagina: pagina.nombre, error: error.message });
    }
  }
  return { ok: true, notas, detalle };
}

module.exports = { disponible, token, paginas, leerPagina, leerPaginassVigiladas, PAGINAS, VERSION };

if (require.main === module) {
  (async () => {
    const argv = process.argv.slice(2);
    if (!disponible()) {
      console.error('falta el token: exporta FB_GRAPH_TOKEN o guárdalo en ~/openterritorio/.fb_token');
      process.exit(1);
    }
    try {
      if (argv.includes('--probar')) {
        const lista = await paginas();
        console.log(`token válido · ${lista.length} páginas disponibles`);
        for (const p of lista.slice(0, 20)) console.log(`  · ${p.nombre} (${p.id})`);
        const vigiladas = await leerPaginassVigiladas(72);
        console.log(JSON.stringify(vigiladas.detalle, null, 1));
        return;
      }
      const idx = argv.indexOf('--volcar');
      const horas = argv.includes('--horas') ? Number(argv[argv.indexOf('--horas') + 1]) : 72;
      const resultado = await leerPaginassVigiladas(horas);
      console.log(JSON.stringify(resultado.detalle, null, 1));
      if (idx > -1) {
        const destino = argv[idx + 1];
        fs.writeFileSync(destino, JSON.stringify(resultado.notas, null, 1));
        console.log(`${resultado.notas.length} publicaciones escritas en ${destino}`);
      }
    } catch (error) {
      console.error('error:', error.message);
      process.exit(1);
    }
  })();
}
