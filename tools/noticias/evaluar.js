#!/usr/bin/env node
'use strict';

/**
 * Analiza una nota y, cuando el texto nombra una colonia o referencia que el
 * gacetero no conoce, la geocodifica contra OpenStreetMap antes de rendirse.
 *
 * Vive aparte porque lo usan tanto el monitor (run.js) como el informe
 * (reporte.js), y así los dos miden exactamente lo mismo.
 */

const { analizar, lugarMencionado, municipioMencionado } = require('./parse');
const gazetteer = require('./gazetteer');

async function analizarNota(entrada) {
  const conDetalle = analizar(entrada, { explicar: true });
  const texto = String(entrada.texto || '');

  // Caso 1: descartada por no saber dónde fue.
  if (conDetalle && conDetalle.motivo) {
    const motivo = conDetalle.motivo;
    if (!/lugar|Colima\/Villa/i.test(motivo)) return { motivo };
    const nombre = lugarMencionado(texto);
    if (!nombre) return { motivo };
    const lugar = await gazetteer.geocodificar(nombre, municipioMencionado(texto));
    if (!lugar) return { motivo };
    const rescatada = analizar(entrada, { lugarExtra: lugar });
    return rescatada ? { nota: rescatada, rescatada: true } : { motivo };
  }

  // Caso 2: hay nota pero cayó al centro del municipio; si el texto nombra una
  // colonia, se geocodifica para no dejar el pin en el centro.
  const gruesa =
    conDetalle?.precision_lugar === 'municipio (aprox)' ||
    conDetalle?.precision_lugar === 'texto';
  if (gruesa) {
    const nombre = lugarMencionado(texto);
    if (nombre) {
      const lugar = await gazetteer.geocodificar(nombre, municipioMencionado(texto));
      if (lugar) {
        const fina = analizar(entrada, { lugarExtra: lugar });
        if (fina) return { nota: fina, rescatada: true };
      }
    }
  }

  return { nota: conDetalle };
}

module.exports = { analizarNota };
