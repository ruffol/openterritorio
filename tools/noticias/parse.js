'use strict';

/**
 * Analiza el texto de una publicación y decide si es una nota de crimen o de
 * accidente vial, con lugar y hora aproximada.
 *
 * No usa IA ni servicios externos: reglas sobre el vocabulario real de las
 * notas de Colima. Lo que no reconoce, lo descarta (mejor no inventar un punto
 * en el mapa que poner uno falso).
 */

const crypto = require('node:crypto');
const gazetteer = require('./gazetteer');

// Vocabulario por tipo. Se cuentan aciertos y se queda el de mayor peso.
const TIPOS = [
  {
    tipo: 'Homicidio',
    categoria: 4,
    peso: [/homicid/, /ejecutad/, /asesinat/, /acribillad/, /sicari/, /cadaver/, /cuerpo sin vida/, /restos humanos/, /balacera/, /balead/, /arma de fuego/, /levantad/, /desaparecid/],
    descarte: [],
  },
  {
    tipo: 'Accidente vial',
    categoria: 2,
    peso: [/choque/, /choc[oa]/, /volcadur/, /volc[oa]/, /atropell/, /colision/, /impact[oa]/, /derrap/, /alcance/, /accidente/, /siniestro/, /automovil/, /motocicleta/, /motociclista/, /camioneta/, /trailer/, /autobus/, /vehiculo/],
    descarte: [/accidente aereo/],
  },
  {
    tipo: 'Asalto',
    categoria: 3,
    peso: [/asalto/, /asaltad/, /robo con violencia/, /atraco/, /despoj/, /cristalazo/],
    descarte: [],
  },
  {
    tipo: 'Incendio',
    categoria: 5,
    peso: [/incendio/, /siniestro total/, /bomberos/, /en llamas/, /calcinad/],
    descarte: [],
  },
  {
    tipo: 'Operativo',
    categoria: 6,
    peso: [/operativo/, /detenid/, /detención/, /detencion/, /aseguramiento/, /fiscalia/, /fiscalia general/, /guardia nacional/, /policia estatal/],
    descarte: [/operativo carretero/],
  },
];

// Palabras que descartan la nota aunque tenga vocabulario de delito
// (prevención, deportes, opinión, clima).
const RUIDO = [
  /prevencion/, /preventivo/, /simulacro/, /campaña/, /conferencia/, /foro/,
  /recomendaciones/, /pronostico/, /lluvias/, /huracan/, /sismo/, /clima/,
  /torneo/, /futbol/, /deportes?/, /concierto/, /cultura/, /aniversario/,
  /resumen semanal/, /editorial/, /columna/, /tasa mas alta/, /cifras? de/,
  /estadistica/, /balance (anual|mensual)/, /informe (anual|de gobierno)/,
  /fortalece acciones/, /invita a la/, /convoca a/, /reconocimiento/,
];

const MESES = {
  enero: 0, febrero: 1, marzo: 2, abril: 3, mayo: 4, junio: 5, julio: 6,
  agosto: 7, septiembre: 8, setiembre: 8, octubre: 9, noviembre: 10, diciembre: 11,
};

const DIAS = {
  domingo: 0, lunes: 1, martes: 2, miercoles: 3, miercoles_: 3, jueves: 4,
  viernes: 5, sabado: 6,
};

function nrm(texto) {
  return String(texto || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase();
}

function contar(patrones, texto) {
  let n = 0;
  for (const p of patrones) if (p.test(texto)) n++;
  return n;
}

/** Hora aproximada de la nota a partir de expresiones en español. */
function hora(texto, publicado) {
  const t = nrm(texto);
  const base = new Date(publicado || Date.now());

  let m = t.match(/(?:a las|alrededor de las|aprox(?:imadamente)? las)\s*(\d{1,2})[:.](\d{2})/);
  if (m) {
    const d = new Date(base);
    d.setHours(Number(m[1]), Number(m[2]), 0, 0);
    return { fecha: d, precision: 'hora exacta' };
  }
  m = t.match(/(\d{1,2})[:.](\d{2})\s*(?:hrs?|horas)/);
  if (m) {
    const d = new Date(base);
    d.setHours(Number(m[1]), Number(m[2]), 0, 0);
    return { fecha: d, precision: 'hora exacta' };
  }

  // Franjas del día.
  const franjas = [
    [/madrugada/, 3], [/manana/, 8], [/medio dia|mediodia/, 13],
    [/tarde/, 16], [/noche/, 21],
  ];
  for (const [re, h] of franjas) {
    if (re.test(t)) {
      const d = new Date(base);
      d.setHours(h, 0, 0, 0);
      return { fecha: d, precision: 'franja horaria' };
    }
  }

  // Fecha explícita: "24 de noviembre" o "24/nov/2026".
  m = t.match(/(\d{1,2})\s*(?:de\s+)?([a-z]+)(?:\s*(?:de|del)?\s*(\d{4}))?/);
  if (m && MESES[m[2]] !== undefined) {
    const d = new Date(base);
    d.setDate(Number(m[1]));
    d.setMonth(MESES[m[2]]);
    if (m[3]) d.setFullYear(Number(m[3]));
    return { fecha: d, precision: 'fecha del texto' };
  }

  // Día relativo.
  const dias = [[/anteayer/, -2], [/ayer/, -1], [/hoy/, 0]];
  for (const [re, delta] of dias) {
    if (re.test(t)) {
      const d = new Date(base);
      d.setDate(d.getDate() + delta);
      return { fecha: d, precision: 'dia relativo' };
    }
  }
  for (const [nombre, dow] of Object.entries(DIAS)) {
    if (new RegExp(`\\b${nombre}\\b`).test(t)) {
      const d = new Date(base);
      const delta = (d.getDay() - dow + 7) % 7 || 7;
      d.setDate(d.getDate() - delta);
      return { fecha: d, precision: 'dia de la semana' };
    }
  }

  return { fecha: base, precision: 'hora de publicacion' };
}

/** Recorta por bytes UTF-8 (el contrato del backend corta en 64). */
function recortar(texto, maxBytes) {
  let salida = texto;
  while (Buffer.byteLength(salida, 'utf8') > maxBytes) {
    salida = salida.slice(0, -1);
  }
  return salida;
}

/**
 * @param {{texto: string, fuente?: string, url?: string, publicado?: number}} entrada
 * @returns {null | object} nota relevante con coordenadas
 */
function analizar(entrada, opciones = {}) {
  const explicar = opciones.explicar === true;
  const descartar = (motivo) => (explicar ? { motivo } : null);
  const texto = String(entrada.texto || '').replace(/\s+/g, ' ').trim();
  if (texto.length < 40) return descartar('texto muy corto');
  const t = nrm(texto);

  if (contar(RUIDO, t) >= 2) return descartar('ruido (prevención, clima, deportes, cultura)');

  let mejor = null;
  for (const familia of TIPOS) {
    if (contar(familia.descarte, t) > 0) continue;
    const aciertos = contar(familia.peso, t);
    if (aciertos === 0) continue;
    const score = aciertos + (familia.tipo === 'Accidente vial' ? 0.5 : 0);
    if (!mejor || score > mejor.score) mejor = { ...familia, score, aciertos };
  }
  if (!mejor) return descartar('sin tipo de suceso');

  // "Accidente" suelto sin contexto vial no basta.
  if (mejor.tipo === 'Accidente vial' && mejor.aciertos < 2 && !/vial|automovil|vehiculo|moto|camion|choque|volcadur/.test(t)) {
    return descartar('menciona accidente sin contexto vial');
  }

  const lugar = gazetteer.ubicar(texto);
  if (!lugar) return descartar('sin lugar reconocible'); // sin ubicación no hay mapa

  // Solo se marca si la nota dice dónde fue (colonia, comunidad, carretera,
  // "a la altura de"). Caer al centro del municipio llenaba el mapa de puntos
  // falsos en la capital para cualquier nota que mencionara "Colima".
  // Si solo se menciona el municipio, el punto es la cabecera: se acepta pero
  // la etiqueta lo dice con "(aprox)" para que nadie lo confunda con una
  // ubicación exacta. Antes se descartaba en Colima/Villa y se perdía la nota.
  const porMunicipio = lugar.tipo === 'municipio' && lugar.precision !== 'marca explicita';

  const tiempo = hora(texto, entrada.publicado);
  const municipio = gazetteer.municipioDe(lugar.lat, lugar.lon);
  const donde = lugar.nombre;

  const huella = crypto
    .createHash('sha256')
    .update(nrm(texto).replace(/[^a-z0-9 ]/g, '').slice(0, 400))
    .digest('hex')
    .slice(0, 16);

  return {
    id: huella,
    tipo: mejor.tipo,
    categoria: mejor.categoria,
    texto,
    fuente: entrada.fuente || entrada.url || 'desconocida',
    url: entrada.url || '',
    publicado: entrada.publicado || Date.now(),
    lugar: donde,
    municipio,
    lat: Number(lugar.lat.toFixed(6)),
    lon: Number(lugar.lon.toFixed(6)),
    precision_lugar: porMunicipio ? 'municipio (aprox)' : lugar.precision,
    fecha_hecho: tiempo.fecha.toISOString(),
    precision_hora: tiempo.precision,
    etiqueta: recortar(`${mejor.tipo} · ${donde}${porMunicipio ? ' (aprox)' : ''}`, 64),
  };
}

module.exports = { analizar, hora, recortar, TIPOS };
