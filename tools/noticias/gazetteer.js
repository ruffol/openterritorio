'use strict';

/**
 * Gacetero de Colima: nombres de lugar -> coordenadas.
 *
 * Sale de los datos del INEGI que ya están en la app (3 896 localidades con
 * población y coordenadas) más las cabeceras de los 10 municipios. Sirve para
 * ubicar una nota periodística sin llamar a ningún servicio de geocodificación.
 */

const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const ROOT = path.resolve(__dirname, '..', '..');
const LOCALIDADES = path.join(ROOT, 'app', 'assets', 'vector', 'localidades.json.gz');

// Cabeceras municipales (centro de la mancha urbana).
const MUNICIPIOS = {
  colima: [19.2433, -103.7247],
  'villa de alvarez': [19.2647, -103.7444],
  comala: [19.3237, -103.76],
  coquimatlan: [19.2064, -103.8086],
  cuauhtemoc: [19.3286, -103.6069],
  ixtlahuacan: [18.9964, -103.7333],
  manzanillo: [19.1138, -104.3267],
  minatitlan: [19.3833, -104.05],
  tecoman: [18.9108, -103.8747],
  armeria: [18.9383, -103.9642],
};

const ALIAS = {
  'la capital': 'colima',
  'capital del estado': 'colima',
  'la villa': 'villa de alvarez',
  manzanillo: 'manzanillo',
  'el puerto': 'manzanillo',
  tecoman: 'tecoman',
  armeria: 'armeria',
  comala: 'comala',
  coquimatlan: 'coquimatlan',
  cuauhtemoc: 'cuauhtemoc',
  ixtlahuacan: 'ixtlahuacan',
  minatitlan: 'minatitlan',
  'villa de alvarez': 'villa de alvarez',
  'zona metropolitana': 'colima',
  'zona metropolitana de colima': 'colima',
  'zona conurbada': 'colima',
};

function normalizar(texto) {
  return String(texto || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9 ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

let cache = null;

/** Mapa normalizado: "las guasimas las borregas" -> {lat, lon, nombre, habitantes} */
function cargar() {
  if (cache) return cache;
  const sitios = new Map();

  for (const [nombre, [lat, lon]] of Object.entries(MUNICIPIOS)) {
    sitios.set(nombre, { lat, lon, nombre, tipo: 'municipio', habitantes: 100000 });
  }
  for (const [alias, destino] of Object.entries(ALIAS)) {
    const destinoDatos = sitios.get(destino) || {
      lat: MUNICIPIOS[destino]?.[0],
      lon: MUNICIPIOS[destino]?.[1],
      nombre: destino,
      tipo: 'municipio',
      habitantes: 100000,
    };
    sitios.set(alias, { ...destinoDatos, alias });
  }

  try {
    const raw = zlib.gunzipSync(fs.readFileSync(LOCALIDADES));
    const datos = JSON.parse(raw.toString('utf8'));
    for (const [lon, lat, nombre, habitantes] of datos.localidades) {
      if (!nombre) continue;
      const llave = normalizar(nombre);
      if (!llave || sitios.has(llave)) continue;
      // "LAS GUASIMAS (LAS BORREGAS)" también se busca como "las guasimas".
      sitios.set(llave, { lat, lon, nombre, tipo: 'localidad', habitantes });
      const sinParentesis = llave.replace(/\(.*$/, '').trim();
      if (sinParentesis && !sitios.has(sinParentesis)) {
        sitios.set(sinParentesis, { lat, lon, nombre, tipo: 'localidad', habitantes });
      }
    }
  } catch (error) {
    // Sin el archivo del INEGI el gacetero se queda con los municipios.
    console.warn('gacetero: no se pudo leer las localidades del INEGI:', error.message);
  }

  cache = { sitios, maxLargo: Math.max(...[...sitios.keys()].map((k) => k.length)) };
  return cache;
}

/** Busca un nombre exacto en el gacetero. */
function buscar(nombre) {
  const { sitios } = cargar();
  const llave = normalizar(nombre);
  if (!llave) return null;
  const sitio = sitios.get(llave);
  if (sitio) return { ...sitio, precision: 'nombre' };

  // Contiene: "colonia la esperanza" -> "la esperanza".
  for (const [k, v] of sitios) {
    if (k.length >= 5 && llave.includes(k)) return { ...v, precision: 'contenido' };
  }
  return null;
}

// Palabras genéricas que no identifican un lugar por sí solas.
const GENERICOS = new Set([
  'la colonia', 'el colonia', 'la comunidad', 'el municipio', 'la ciudad',
  'el estado', 'la zona', 'el centro', 'la calle', 'el libramiento',
  'el fraccionamiento', 'el barrio', 'la manzana', 'el kilometro',
]);

// Construcciones donde el nombre que sigue NO es un lugar habitado.
const VIA = /\b(carretera|libramiento|autopista|periferico|circuito|avenida|av|boulevard|bulevar|calle|calzada|prolongacion|entronque|km|kilometro)\b/;

function titulo(texto) {
  return String(texto || '')
    .toLowerCase()
    .split(' ')
    .map((p) => (p.length > 2 ? p[0].toUpperCase() + p.slice(1) : p))
    .join(' ');
}

/**
 * Ubica el lugar mencionado en un texto libre.
 *
 * Prioridad: lo que va después de una marca explícita ("colonia", "comunidad
 * de", "municipio de", "a la altura de") gana sobre un nombre suelto, y nunca
 * se toma el nombre de una vía ("carretera Colima-Manzanillo" no es Manzanillo).
 */
function ubicar(texto) {
  const { sitios } = cargar();
  const limpio = ` ${normalizar(texto)} `;

  // 1) Marcas explícitas.
  const marcas = [
    [/municipio\s+de\s+([a-z0-9 ]{3,30})/, 100],
    [/(?:colonia|fraccionamiento|unidad habitacional|barrio|andador)\s+(?:de\s+|la\s+|el\s+|las\s+|los\s+)?([a-z0-9 ]{3,40})/, 90],
    [/(?:comunidad|poblado|ejido|rancho|localidad|delegacion)\s+(?:de\s+|la\s+|el\s+|las\s+|los\s+)?([a-z0-9 ]{3,40})/, 80],
    [/a la altura de\s+(?:la\s+|el\s+|las\s+|los\s+)?([a-z0-9 ]{3,40})/, 70],
  ];

  let mejor = null;
  for (const [re, peso] of marcas) {
    const m = limpio.match(re);
    if (!m) continue;
    const candidato = buscarRecortando(m[1]);
    if (candidato && (!mejor || peso > mejor.peso)) {
      // 'nombre' = el lugar existe tal cual; 'contenido' = se reconoció dentro
      // de una frase más larga (menos fiable, se marca como aproximada).
      const precision = candidato.precision === 'nombre' ? 'marca explicita' : 'marca aproximada';
      mejor = { ...candidato, peso, precision };
    }
  }
  if (mejor) return limpiar(mejor);

  // 2) Nombre suelto: se descartan los que están dentro de un nombre de vía.
  for (const [llave, sitio] of sitios) {
    if (llave.length < 5 || GENERICOS.has(llave)) continue;
    let desde = 0;
    let pos;
    while ((pos = limpio.indexOf(` ${llave} `, desde)) !== -1) {
      desde = pos + 1;
      const antes = limpio.slice(Math.max(0, pos - 30), pos);
      if (VIA.test(antes)) continue;
      const peso = llave.length * 10 - pos / 100;
      if (!mejor || peso > mejor.peso) mejor = { ...sitio, peso, precision: 'texto' };
    }
  }
  return mejor ? limpiar(mejor) : null;
}

/** Prueba recortando el final del candidato ("la esperanza en colima" -> "la esperanza"). */
function buscarRecortando(fragmento) {
  const palabras = normalizar(fragmento).split(' ').filter(Boolean);
  for (let n = Math.min(palabras.length, 5); n >= 1; n--) {
    const intento = palabras.slice(0, n).join(' ');
    if (GENERICOS.has(intento)) continue;
    const sitio = buscar(intento);
    if (sitio) return { ...sitio, llaveUsada: intento };
  }
  return null;
}

function limpiar(sitio) {
  return {
    lat: sitio.lat,
    lon: sitio.lon,
    nombre: titulo(sitio.nombre),
    tipo: sitio.tipo,
    precision: sitio.precision,
  };
}

/** Municipio al que pertenece un punto (para etiquetar la nota). */
function municipioDe(lat, lon) {
  let mejor = null;
  let menor = Infinity;
  for (const [nombre, [mlat, mlon]] of Object.entries(MUNICIPIOS)) {
    const d = (mlat - lat) ** 2 + (mlon - lon) ** 2;
    if (d < menor) {
      menor = d;
      mejor = nombre;
    }
  }
  return mejor;
}

// ---------------------------------------------------------------------------
// Geocodificación bajo demanda (Nominatim) para lo que el gacetero no conoce:
// colonias, fraccionamientos y referencias urbanas. Se consulta como máximo
// una vez por minuto por nombre y el resultado se guarda en disco.
// ---------------------------------------------------------------------------

const NOMINATIM = 'https://nominatim.openstreetmap.org/search';
const CACHE = path.join(__dirname, 'colonias-cache.json');
let cacheColonias = null;

function cargarCache() {
  if (cacheColonias) return cacheColonias;
  try {
    cacheColonias = JSON.parse(fs.readFileSync(CACHE, 'utf8'));
  } catch {
    cacheColonias = {};
  }
  return cacheColonias;
}

function guardarCache() {
  try {
    fs.writeFileSync(CACHE, JSON.stringify(cacheColonias, null, 1));
  } catch {
    // sin permisos de escritura la caché vive solo en memoria
  }
}

let ultimaConsulta = 0;

/**
 * Busca un nombre de lugar urbano en OpenStreetMap.
 * @returns {Promise<null | {lat:number, lon:number, nombre:string, tipo:string, precision:string}>}
 */
async function geocodificar(nombre, municipio) {
  const limpio = String(nombre || '').trim();
  if (limpio.length < 4) return null;

  const clave = `${normalizar(limpio)}|${normalizar(municipio || '')}`;
  const cacheActual = cargarCache();
  if (Object.prototype.hasOwnProperty.call(cacheActual, clave)) return cacheActual[clave];

  // Nominatim pide 1 petición por segundo como máximo.
  const espera = Math.max(0, 1100 - (Date.now() - ultimaConsulta));
  if (espera > 0) await new Promise((r) => setTimeout(r, espera));
  ultimaConsulta = Date.now();

  const consulta = `${limpio}, ${municipio || 'Colima'}, Colima, Mexico`;
  try {
    const url = `${NOMINATIM}?format=jsonv2&limit=5&countrycodes=mx&q=${encodeURIComponent(consulta)}`;
    const respuesta = await fetch(url, {
      headers: {
        'User-Agent': 'openterritorio/1.0 (monitor de noticias; srtlalchichi@gmail.com)',
        Accept: 'application/json',
      },
      signal: AbortSignal.timeout(20000),
    });
    if (!respuesta.ok) return null;
    const lista = await respuesta.json();
    if (!Array.isArray(lista) || lista.length === 0) {
      cacheActual[clave] = null;
      guardarCache();
      return null;
    }
    // Solo vale si cae dentro de Colima y cerca del municipio mencionado.
    const centro = MUNICIPIOS[normalizar(municipio || 'colima')];
    let elegido = null;
    for (const item of lista) {
      const lat = Number(item.lat);
      const lon = Number(item.lon);
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
      if (lat < 18.6 || lat > 19.7 || lon < -104.75 || lon > -103.4) continue;
      if (centro) {
        const d = Math.hypot((lat - centro[0]) * 111, (lon - centro[1]) * 105);
        if (d > 30) continue;
      }
      elegido = { lat, lon, nombre: titulo(limpio), tipo: 'geocodificado', precision: 'geocodificado (OSM)' };
      break;
    }
    cacheActual[clave] = elegido;
    guardarCache();
    return elegido;
  } catch {
    return null;
  }
}

module.exports = { cargar, buscar, ubicar, normalizar, municipioDe, MUNICIPIOS, titulo, geocodificar, _cache: () => cargarCache() };
