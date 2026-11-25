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

module.exports = { cargar, buscar, ubicar, normalizar, municipioDe, MUNICIPIOS, titulo };
