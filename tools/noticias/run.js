#!/usr/bin/env node
'use strict';

/**
 * Recolector de notas de crimen y accidentes viales en Colima.
 *
 *   node tools/noticias/run.js --feed notas.json --push   # procesa y publica en el mapa
 *   node tools/noticias/run.js --demo                     # muestra qué extrae
 *
 * Entrada (`--feed`): [{ "texto": "...", "fuente": "afmedios", "url": "...", "publicado": 1795... }]
 *
 * `--push` manda cada nota nueva como evento del tablero (`POST /api/events`),
 * que es lo que la app ya dibuja en el mapa. Sin `--push` solo escribe la base.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { analizar, hora, recortar, TIPOS } = require('./parse');
const { analizarNota } = require('./evaluar');
const gazetteer = require('./gazetteer');
const llm = require('./llm');
const { NoticiasDB } = require('./db');

const BASE = (process.env.OPENTERITORIO_URL || 'https://tienda.tlalchichi.xyz').replace(/\/+$/, '');
const TOKEN = process.env.OPENTERITORIO_TOKEN || '';

// Muestras reales del estilo de las páginas vigiladas, para probar sin red.
const DEMO = [
  {
    fuente: 'afmedios',
    texto:
      'La Fiscalía General del Estado informó que la tarde de este martes se localizó el cuerpo sin vida de un hombre a un costado de la carretera Colima-Manzanillo, a la altura de la comunidad de Cuyutlán. Personal del SEMEFO acudió al sitio alrededor de las 16:40 horas para realizar el levantamiento correspondiente.',
  },
  {
    fuente: 'colimanoticias',
    texto:
      'Un joven motociclista resultó con lesiones graves luego de chocar contra una camioneta sobre la avenida Gonzalo de Sandoval, en la colonia La Esperanza, la noche de este lunes. Paramédicos de la Cruz Roja lo trasladaron al Hospital General.',
  },
  {
    fuente: 'colima_en_la_noticia',
    texto:
      'Reportan balacera en la colonia Solidaridad, en Villa de Álvarez; vecinos escucharon detonaciones de arma de fuego la madrugada de hoy. Hasta el momento no se reportan personas lesionadas.',
  },
  {
    fuente: 'afmedios',
    texto:
      'Se invita a la población al simulacro de prevención de accidentes que se realizará en el centro de Tecomán; habrá recomendaciones de protección civil y lluvias pronosticadas.',
  },
  {
    fuente: 'colimanoticias',
    texto:
      'Un accidente automovilístico se registró sobre el libramiento carretero a la altura de la colonia El Diezmo, donde una camioneta volcó; el conductor fue trasladado a un hospital de Colima.',
  },
  {
    fuente: 'afmedios',
    texto:
      'Localizan cuerpo sin vida de una mujer en un terreno baldío de la comunidad de Suchitlán, municipio de Comala, la mañana de este viernes. La Fiscalía ya investiga el hecho como homicidio doloso.',
  },
];

function leerFeed(ruta) {
  const datos = JSON.parse(fs.readFileSync(ruta, 'utf8'));
  return Array.isArray(datos) ? datos : datos.notas || [];
}

/** Horas que el evento se queda en el mapa (por defecto 24). */
const TTL_HORAS = Number(process.env.NOTICIAS_TTL_HORAS || 24);

async function publicarEvento(nota) {
  if (!TOKEN) throw new Error('falta OPENTERITORIO_TOKEN para publicar en el mapa');
  const url = `${BASE}/api/events`;
  const respuesta = await fetch(url, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      lat: nota.lat,
      lon: nota.lon,
      category_id: nota.categoria,
      short_note: nota.etiqueta,
      ttl_horas: TTL_HORAS,
      // Cita para el detalle del marcador y los medios que la publicaron.
      texto: (nota.texto || '').slice(0, 600),
      fuentes: nota.fuentes && nota.fuentes.length > 0 ? nota.fuentes : [nota.fuente],
      imagen: nota.imagen || '',
      enlace: nota.url || '',
      // La app dibuja un halo en vez de un pin cuando la ubicación es solo el
      // municipio: un punto exacto en el centro de Colima engaña.
      precision: nota.precision_lugar || '',
    }),
  });
  if (!respuesta.ok) {
    throw new Error(`el backend rechazó el evento (HTTP ${respuesta.status})`);
  }
  return respuesta.json();
}

/**
 * Pasada con modelo de lenguaje: decide qué es suceso, qué tipo, si repite otra
 * nota y cuál es el lugar. Las coordenadas siempre salen de OpenStreetMap.
 * Devuelve null si el modelo no está configurado o falla (se usa el regex).
 */
async function analizarConModelo(entradas, db) {
  if (!llm.disponible()) return null;

  const recientes = db
    .recientes(12)
    .slice(0, 25)
    .map((n) => n.etiqueta || n.texto || '')
    .filter(Boolean);

  const ordenadas = entradas
    .filter((e) => String(e.texto || '').length > 40)
    .sort((a, b) => (Number(b.publicado) || 0) - (Number(a.publicado) || 0))
    .slice(0, 25);

  const salida = [];
  for (const lote of llm.lotes(ordenadas, 12)) {
    const veredictos = await llm.analizarLote(
      lote.map((n) => ({ titulo: n.titulo, texto: n.texto, fuente: n.fuente })),
      { recientes },
    );
    if (!veredictos) return null; // el modelo falló: que decida el regex

    for (const veredicto of veredictos) {
      const entrada = lote[Number(veredicto.i)];
      if (!entrada) continue;
      const texto = String(entrada.texto || '');

      if (veredicto.es_suceso !== true) {
        salida.push({
          estado: 'descartada',
          motivo: veredicto.motivo || 'el modelo no lo considera un suceso',
          texto: texto.slice(0, 60),
        });
        continue;
      }
      if (veredicto.es_duplicado_de !== null && veredicto.es_duplicado_de !== undefined) {
        salida.push({ estado: 'repetida', motivo: 'el modelo la marca como la misma nota', texto: texto.slice(0, 60) });
        continue;
      }

      const tipo = Object.prototype.hasOwnProperty.call(llm.TIPOS, veredicto.tipo)
        ? veredicto.tipo
        : null;
      if (!tipo) {
        salida.push({ estado: 'descartada', motivo: 'tipo no reconocido por el modelo', texto: texto.slice(0, 60) });
        continue;
      }

      const municipio = gazetteer.normalizar(String(veredicto.municipio || ''));
      const nombreLugar = String(veredicto.lugar || '').trim();
      let lugar = null;
      if (nombreLugar.length >= 4) {
        lugar = await gazetteer.geocodificar(nombreLugar, municipio);
      }
      if (!lugar && gazetteer.MUNICIPIOS[municipio]) {
        // Sin lugar verificable pero el municipio es de Colima: se marca como
        // aproximado y la app lo pinta con halo, no con un pin exacto.
        const [lat, lon] = gazetteer.MUNICIPIOS[municipio];
        lugar = { lat, lon, nombre: gazetteer.titulo(municipio), tipo: 'municipio', precision: 'municipio (aprox)' };
      }
      if (!lugar) {
        salida.push({ estado: 'descartada', motivo: 'sin lugar reconocible', texto: texto.slice(0, 60) });
        continue;
      }

      const porMunicipio = lugar.tipo === 'municipio';
      const tiempo = hora(texto, entrada.publicado);
      const donde = porMunicipio ? gazetteer.titulo(municipio || lugar.nombre) : lugar.nombre;
      const huella = crypto.createHash('sha256').update(`${texto}`.slice(0, 400)).digest('hex').slice(0, 16);

      salida.push({
        estado: 'analizada',
        nota: {
          id: huella,
          tipo,
          categoria: llm.TIPOS[tipo],
          texto,
          fuente: entrada.fuente || entrada.url || 'desconocida',
          url: entrada.url || '',
          publicado: entrada.publicado || Date.now(),
          lugar: donde,
          municipio: gazetteer.municipioDe(lugar.lat, lugar.lon),
          lat: Number(lugar.lat.toFixed(6)),
          lon: Number(lugar.lon.toFixed(6)),
          precision_lugar: porMunicipio ? 'municipio (aprox)' : lugar.precision,
          fecha_hecho: tiempo.fecha.toISOString(),
          precision_hora: tiempo.precision,
          etiqueta: recortar(`${tipo} · ${donde}${porMunicipio ? ' (aprox)' : ''}`, 64),
          imagen: entrada.imagen || '',
          modelo: llm.MODELO,
        },
        rescatada: Boolean(nombreLugar) && !porMunicipio,
      });
    }
  }
  return salida;
}

// Dos pasadas a la vez (la del reloj y una forzada a mano) duplicaban el mismo
// suceso en el mapa. Un candado con el pid lo impide.
const LOCK = path.join(os.tmpdir(), 'openterritorio-noticias.lock');

function tomarCandado() {
  try {
    const previo = JSON.parse(fs.readFileSync(LOCK, 'utf8'));
    const reciente = Date.now() - Number(previo.ts || 0) < 15 * 60_000;
    let vivo = false;
    try {
      process.kill(Number(previo.pid), 0);
      vivo = true;
    } catch {
      vivo = false;
    }
    if (reciente && vivo) return false;
  } catch {
    // sin candado previo
  }
  fs.writeFileSync(LOCK, JSON.stringify({ pid: process.pid, ts: Date.now() }));
  return true;
}

function soltarCandado() {
  try {
    fs.unlinkSync(LOCK);
  } catch {
    // ya no estaba
  }
}

async function main() {
  if (process.argv.includes('--push') && !tomarCandado()) {
    console.log(JSON.stringify({ resumen: [], aviso: 'ya hay una pasada en curso' }));
    return;
  }
  try {
    await pasada();
  } finally {
    if (process.argv.includes('--push')) soltarCandado();
  }
}

async function pasada() {
  const argv = process.argv.slice(2);
  const modoDemo = argv.includes('--demo');
  const push = argv.includes('--push');
  const idx = argv.indexOf('--feed');
  const feed = idx > -1 ? argv[idx + 1] : null;
  const dbArg = argv.indexOf('--db');

  if (!modoDemo && !feed) {
    console.error('uso: run.js --demo | --feed notas.json [--push] [--db noticias.json]');
    process.exit(1);
  }

  const db = new NoticiasDB(dbArg > -1 ? argv[dbArg + 1] : path.join(__dirname, 'noticias.json'));
  const entradas = modoDemo ? DEMO : leerFeed(feed);

  const resumen = [];

  const registrar = async (nota, rescatada) => {
    const { estado, nota: guardada } = db.agregar(nota);
    let publicado = null;
    // Se publica la primera vez y, una sola vez más, si la nota guardada no
    // llevaba el detalle completo (texto, imagen, enlace).
    const faltaDetalle =
      (estado === 'repetida' || estado === 'duplicada') && !guardada.publicadaConDetalle;
    if (push && (estado === 'nueva' || faltaDetalle)) {
      guardada.imagen = guardada.imagen || nota.imagen || '';
      publicado = await publicarEvento(guardada);
      guardada.publicadaConDetalle = true;
      guardada.evento = publicado.packet_id;
      db.guardar();
    }
    resumen.push({
      estado,
      rescatada: rescatada === true,
      tipo: nota.tipo,
      lugar: nota.lugar,
      municipio: nota.municipio,
      lat: nota.lat,
      lon: nota.lon,
      hora: new Date(nota.fecha_hecho).toLocaleString('es-MX', {
        dateStyle: 'short',
        timeStyle: 'short',
      }),
      precision: nota.precision_lugar || nota.precision_hora,
      etiqueta: nota.etiqueta,
      evento: publicado ? publicado.packet_id : null,
    });
  };

  // Con modelo de lenguaje si hay llave; si no (o si falla), regex de siempre.
  const conModelo = await analizarConModelo(entradas, db);
  if (conModelo) {
    for (const item of conModelo) {
      if (!item.nota) {
        resumen.push({ estado: 'descartada', motivo: item.motivo, texto: item.texto });
        continue;
      }
      await registrar(item.nota, item.rescatada);
    }
  } else {
    for (const entrada of entradas) {
      const { nota, motivo, rescatada } = await analizarNota(entrada);
      if (!nota) {
        resumen.push({ estado: 'descartada', motivo, texto: String(entrada.texto || '').slice(0, 60) });
        continue;
      }
      await registrar(nota, rescatada);
    }
  }

  console.log(JSON.stringify({ resumen, db: db.resumen() }, null, 2));
}

main().catch((error) => {
  console.error('error:', error.message);
  process.exit(1);
});
