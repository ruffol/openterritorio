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
// Notas que hablan de crimen pero no SON un suceso: estadísticas, balances,
// convenios, foros. Llenaban el mapa de puntos que no corresponden a un hecho.
const INSTITUCIONAL =
  /tasa|estad[ií]stica|cifras|balance anual|observatorio|fortalece|firma convenio|capacita|capacitaci[oó]n|diplomado|foro|panel|conferencia|entrega (?:apoyos|obras)|informe de gobierno|presupuesto|diputad|legislatur|sesi[oó]n del congreso|pron[oó]stico|prevenci[oó]n del delito|operativo (?:de|en) (?:vigilancia|seguridad) (?:en|para) (?:la )?(?:feria|evento)/i;

// El canal y el portal publican notas de todo el país. Si el titular nombra otro
// estado y no menciona uno de Colima, no va al mapa de Colima.
const OTRO_ESTADO =
  /jalisco|guadalajara|zapotl[aá]n|ciudad guzm[aá]n|iztapalapa|ciudad de m[eé]xico|cdmx|mazatl[aá]n|sinaloa|michoac[aá]n|guanajuato|nayarit|puebla|oaxaca|veracruz|tijuana|monterrey/i;
const DE_COLIMA =
  /colima|manzanillo|tecom[aá]n|villa de [aá]lvarez|comala|coquimatl[aá]n|cuauht[eé]moc|ixtlahuac[aá]n|minatitl[aá]n|armer[ií]a|cu[ú]yutl[aá]n|suchitl[aá]n|pe[aá]a blanca|el trapiche/i;

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
  const lugarExtra = opciones.lugarExtra || null;
  // El titular manda para decidir el tipo de suceso; el lugar y la hora salen
  // de todo el texto. Si no hay titular, se usa el texto completo.
  const tTipo = opciones.titular ? nrm(opciones.titular) : '';
  const descartar = (motivo) => (explicar ? { motivo } : null);
  const texto = String(entrada.texto || '').replace(/\s+/g, ' ').trim();
  if (texto.length < 40) return descartar('texto muy corto');
  const t = nrm(texto);

  if (contar(RUIDO, t) >= 2) return descartar('ruido (prevención, clima, deportes, cultura)');

  // El titular manda para decidir de qué se trata; si no hay titular, todo el
  // texto. Así un cuerpo que menciona un accidente de otra nota no nos engaña.
  const base = tTipo || t;

  if (INSTITUCIONAL.test(base)) return descartar('nota de contexto (cifras, convenios, foros), no un suceso');
  if (OTRO_ESTADO.test(base) && !DE_COLIMA.test(base)) return descartar('la nota es de otro estado');

  let mejor = null;
  for (const familia of TIPOS) {
    if (contar(familia.descarte, base) > 0) continue;
    const aciertos = contar(familia.peso, base);
    if (aciertos === 0) continue;
    const score = aciertos + (familia.tipo === 'Accidente vial' ? 0.5 : 0);
    if (!mejor || score > mejor.score) mejor = { ...familia, score, aciertos };
  }
  if (!mejor) return descartar('sin tipo de suceso');

  // "Accidente" suelto sin contexto vial no basta.
  if (mejor.tipo === 'Accidente vial' && mejor.aciertos < 2 && !/vial|automovil|vehiculo|moto|camion|choque|volcadur/.test(base)) {
    return descartar('menciona accidente sin contexto vial');
  }

  // Si el llamador ya resolvió el lugar (Nominatim), manda ese.
  const lugar = lugarExtra || gazetteer.ubicar(texto);
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

/**
 * Nombre del lugar tal como se menciona, respetando mayúsculas: sirve para
 * geocodificarlo cuando el gacetero no lo conoce.
 *
 * Casos que cubre (con ejemplos reales de las notas de Colima):
 *   "sobre el libramiento Griselda Álvarez"      -> "Libramiento Griselda Álvarez"
 *   "en la colonia El Diezmo"                    -> "El Diezmo"
 *   "en Tapeixtles"                              -> "Tapeixtles"
 *   "a la altura de la glorieta de El Naranjo"   -> "glorieta El Naranjo"
 */
function lugarMencionado(texto) {
  const crudo = String(texto || '').replace(/\s+/g, ' ');

  // 1. Vías y referencias con marcador explícito (lo más común en accidentes).
  const vias = [
    /\b(libramiento|bulevar|boulevard|blvd\.?|avenida|av\.|calzada|perif[eé]rico|autopista|carretera|prolongaci[oó]n|glorieta|puente|retorno)\s+((?:de\s+|del\s+|la\s+|el\s+|las\s+|los\s+)?[A-ZÁÉÍÓÚÑ][\wáéíóúñ.]*(?:\s+(?:de|del|la|las|los|y)?\s*[A-ZÁÉÍÓÚÑ][\wáéíóúñ.]*){0,4})/,
  ];
  for (const re of vias) {
    const m = crudo.match(re);
    if (m) {
      const nombre = `${m[1]} ${m[2]}`.replace(/\s+/g, ' ').trim();
      if (nombre.length >= 8) return nombre;
    }
  }

  // 2. Colonias, comunidades y ranchos.
  const marcas = [
    /\b(?:colonia|fraccionamiento|unidad habitacional|barrio|andador|privada|residencial)\s+(?:de\s+|la\s+|el\s+|las\s+|los\s+)?([A-ZÁÉÍÓÚÑ][\wáéíóúñ.]*(?:\s+[A-ZÁÉÍÓÚÑ][\wáéíóúñ.]*){0,3})/,
    /\b(?:comunidad|poblado|ejido|rancho|localidad|delegaci[oó]n|predio)\s+(?:de\s+|la\s+|el\s+|las\s+|los\s+)?([A-ZÁÉÍÓÚÑ][\wáéíóúñ.]*(?:\s+[A-ZÁÉÍÓÚÑ][\wáéíóúñ.]*){0,3})/,
    /\ba la altura de\s+(?:la\s+|el\s+|las\s+|los\s+)?([A-ZÁÉÍÓÚÑ][\wáéíóúñ.]*(?:\s+[A-ZÁÉÍÓÚÑ][\wáéíóúñ.]*){0,3})/,
    // "en Tapeixtles", "en Suchitlán": una sola palabra propia con mayúscula.
    /\b(?:en|sobre|frente a|frente al|cerca de| rumbo a)\s+([A-ZÁÉÍÓÚÑ][a-záéíóúñ]{4,}(?:\s+[A-ZÁÉÍÓÚÑ][a-záéíóúñ]{2,})?)\b/,
  ];
  const municipios = new Set([
    'colima', 'villa de alvarez', 'manzanillo', 'tecoman', 'comala', 'coquimatlan',
    'cuauhtemoc', 'ixtlahuacan', 'minatitlan', 'armeria', 'jalisco', 'mexico',
  ]);
  for (const re of marcas) {
    const m = crudo.match(re);
    if (!m) continue;
    const intento = m[1].replace(/\s+/g, ' ').trim();
    if (intento.length < 4) continue;
    if (municipios.has(nrm(intento))) continue; // "en Colima" es el municipio, no una colonia
    return intento;
  }

  // 3. Último recurso: la versión sin mayúsculas (textos que llegan en minúsculas).
  const limpio = ` ${nrm(texto)} `;
  for (const re of [
    /(?:colonia|fraccionamiento|unidad habitacional|barrio)\s+(?:de\s+|la\s+|el\s+|las\s+|los\s+)?([a-z0-9 ]{4,40})/,
    /(?:comunidad|poblado|ejido|rancho|localidad|delegacion)\s+(?:de\s+|la\s+|el\s+|las\s+|los\s+)?([a-z0-9 ]{4,40})/,
  ]) {
    const m = limpio.match(re);
    if (!m) continue;
    const palabras = m[1].trim().split(' ');
    for (let n = Math.min(palabras.length, 4); n >= 1; n--) {
      const intento = palabras.slice(0, n).join(' ').trim();
      if (intento.length >= 4) return intento;
    }
  }
  return '';
}

/** Municipio mencionado en el texto, si lo hay. */
function municipioMencionado(texto) {
  const limpio = nrm(texto);
  const nombres = ['villa de alvarez', 'colima', 'manzanillo', 'tecoman', 'comala', 'coquimatlan', 'cuauhtemoc', 'ixtlahuacan', 'minatitlan', 'armeria'];
  for (const nombre of nombres) {
    if (limpio.includes(nombre)) return nombre;
  }
  return '';
}

module.exports = { analizar, hora, recortar, TIPOS, lugarMencionado, municipioMencionado };
