'use strict';

/**
 * Análisis de notas con un modelo de lenguaje.
 *
 * Sustituye a las reglas de palabras clave para lo difícil: decidir si la nota
 * es un suceso real, de qué tipo, si repite otra ya publicada y, sobre todo,
 * cuál es el lugar exacto ("frente al Kiosko de la entrada a El Trapiche").
 *
 * El modelo NUNCA devuelve coordenadas: solo el nombre del lugar tal como
 * aparece en la nota. Las coordenadas salen de OpenStreetMap (geocodificar),
 * así no se puede inventar una ubicación.
 *
 * Configuración por entorno:
 *   LLM_BASE     https://opencode.ai/zen/go/v1
 *   LLM_MODELO   deepseek-v4.1-flash
 *   LLM_API_KEY  o el archivo ~/openterritorio/.llave
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const BASE = (process.env.LLM_BASE || 'https://opencode.ai/zen/go/v1').replace(/\/+$/, '');
// El gateway pide una sesión para enrutar; una por proceso basta.
const SESION = process.env.LLM_SESION || `openterritorio-${Date.now().toString(36)}`;
const MODELO = process.env.LLM_MODELO || 'deepseek-v4.1-flash';

const TIPOS = {
  Homicidio: 4,
  Asalto: 3,
  'Accidente vial': 2,
};

function llave() {
  if (process.env.LLM_API_KEY && process.env.LLM_API_KEY.trim()) {
    return process.env.LLM_API_KEY.trim();
  }
  const candidatos = [
    path.join(os.homedir(), 'openterritorio', '.llave'),
    path.join(__dirname, '.llave'),
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
  return llave().length > 0;
}

const SISTEMA = `Analizas noticias locales del estado de Colima, México, para un mapa de emergencias.

Recibirás un lote de notas. Para cada una responde SOLO con datos que estén en el texto.

Reglas:
1. es_suceso = true únicamente si la nota reporta un HECHO concreto ocurrido en Colima: homicidio/ejecución, accidente vial (choque, volcadura, atropello, motociclista), o asalto/robo con violencia.
2. es_suceso = false para: estadísticas, tasas, informes de gobierno, conferencias, foros, política, deportes, clima, prevención, operativos anunciados, detenciones de otro estado, notas nacionales o de Jalisco/Michoacán/Sinaloa.
3. tipo: exactamente uno de "Homicidio", "Accidente vial", "Asalto" o null.
4. lugar: el texto literal del lugar que da la nota (colonia, calle, libramiento, carretera, kilómetro, glorieta, frente a qué). Cópialo tal cual, sin corregir ni completar. Si la nota solo dice el municipio, pon el municipio. Si no dice ningún lugar, deja "".
5. NO inventes lugares ni coordenadas. Si dudas, deja "".
6. municipio: uno de Colima, Villa de Álvarez, Manzanillo, Tecomán, Comala, Coquimatlán, Cuauhtémoc, Ixtlahuacán, Minatitlán, Armería, o "" si no se sabe.
7. es_duplicado_de: si el mismo hecho ya aparece en otra nota del lote o en la lista de notas recientes, pon el índice de esa nota; si no, null.
8. hora_aprox: la hora o el momento que menciona la nota ("la mañana de este lunes", "21:30 horas"). "" si no lo dice.
9. motivo: si es_suceso es false, una frase corta de por qué.

Responde SOLO JSON válido con esta forma:
{"notas":[{"i":0,"es_suceso":true,"tipo":"Accidente vial","municipio":"Colima","lugar":"libramiento Griselda Álvarez","hora_aprox":"21:30 horas","es_duplicado_de":null,"motivo":""}]}`;

/**
 * Analiza un lote de notas.
 * @param {Array<{titulo?:string, texto:string, fuente?:string, publicado?:number}>} notas
 * @param {{recientes?: string[]}} opciones títulos de las últimas 12 h para deduplicar
 * @returns {Promise<Array<object>|null>} null si el modelo no está disponible o falla
 */
async function analizarLote(notas, opciones = {}) {
  if (!disponible() || notas.length === 0) return null;

  const recientes = (opciones.recientes || []).slice(0, 25);
  const entrada = notas.map((n, i) => ({
    i,
    fuente: n.fuente || '',
    titular: (n.titulo || n.texto || '').slice(0, 220),
    texto: String(n.texto || '').replace(/\s+/g, ' ').slice(0, 1400),
  }));

  const usuario = `${recientes.length ? `Sucesos ya publicados en las últimas 12 horas (para detectar repetidos):\n${recientes.map((t, k) => `${k + 1}. ${String(t).slice(0, 120)}`).join('\n')}\n\n` : ''}Notas a analizar:\n${JSON.stringify(entrada)}`;

  const cuerpo = {
    model: MODELO,
    temperature: 0,
    max_tokens: 2000,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: SISTEMA },
      { role: 'user', content: usuario },
    ],
  };

  for (let intento = 1; intento <= 2; intento += 1) {
    try {
      const respuesta = await fetch(`${BASE}/chat/completions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer ' + llave(),
          'x-opencode-session': SESION,
        },
        body: JSON.stringify(cuerpo),
        signal: AbortSignal.timeout(90000),
      });
      if (!respuesta.ok) {
        const detalle = (await respuesta.text()).slice(0, 200);
        throw new Error(`HTTP ${respuesta.status} ${detalle}`);
      }
      const datos = await respuesta.json();
      const texto = datos?.choices?.[0]?.message?.content || '';
      const limpio = String(texto).replace(/^```json\s*/i, '').replace(/```\s*$/, '').trim();
      const json = JSON.parse(limpio);
      const lista = Array.isArray(json?.notas) ? json.notas : null;
      if (!lista) throw new Error('respuesta sin "notas"');
      return lista;
    } catch (error) {
      if (intento === 2) {
        console.error(`llm: fallo el análisis (${error.message})`);
        return null;
      }
      await new Promise((r) => setTimeout(r, 1500));
    }
  }
  return null;
}

/** Parte un arreglo en lotes del tamaño pedido. */
function lotes(lista, tamano) {
  const salida = [];
  for (let i = 0; i < lista.length; i += tamano) salida.push(lista.slice(i, i + tamano));
  return salida;
}

module.exports = { analizarLote, disponible, lotes, TIPOS, MODELO, BASE, llave };
