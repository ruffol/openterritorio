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
const path = require('node:path');
const { analizar } = require('./parse');
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
    }),
  });
  if (!respuesta.ok) {
    throw new Error(`el backend rechazó el evento (HTTP ${respuesta.status})`);
  }
  return respuesta.json();
}

async function main() {
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
  for (const entrada of entradas) {
    const nota = analizar(entrada);
    if (!nota) {
      resumen.push({ estado: 'descartada', texto: entrada.texto.slice(0, 60) });
      continue;
    }
    const { estado, nota: guardada } = db.agregar(nota);
    let publicado = null;
    if (push && estado === 'nueva') {
      publicado = await publicarEvento(guardada);
    }
    resumen.push({
      estado,
      tipo: nota.tipo,
      lugar: nota.lugar,
      municipio: nota.municipio,
      lat: nota.lat,
      lon: nota.lon,
      hora: new Date(nota.fecha_hecho).toLocaleString('es-MX', {
        dateStyle: 'short',
        timeStyle: 'short',
      }),
      precision: nota.precision_hora,
      etiqueta: nota.etiqueta,
      evento: publicado ? publicado.packet_id : null,
    });
  }

  console.log(JSON.stringify({ resumen, db: db.resumen() }, null, 2));
}

main().catch((error) => {
  console.error('error:', error.message);
  process.exit(1);
});
