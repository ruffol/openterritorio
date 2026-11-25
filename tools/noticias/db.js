'use strict';

/**
 * Base de datos local de notas (JSON con escritura atómica).
 *
 * Dos candados contra repetir la misma nota:
 *   1. `id` = huella del texto normalizado (la misma publicación dos veces).
 *   2. `clave` = tipo + municipio + día. Varios medios publican el mismo hecho
 *      con palabras distintas; así se guarda una vez y se anotan las fuentes.
 */

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_FILE = path.join(__dirname, 'noticias.json');

class NoticiasDB {
  constructor(archivo = DEFAULT_FILE) {
    this.archivo = archivo;
    this.notas = [];
    this.porId = new Set();
    this.porClave = new Map();
    this.cargar();
  }

  cargar() {
    try {
      const datos = JSON.parse(fs.readFileSync(this.archivo, 'utf8'));
      this.notas = Array.isArray(datos.notas) ? datos.notas : [];
    } catch {
      this.notas = [];
    }
    this.reindexar();
  }

  reindexar() {
    this.porId.clear();
    this.porClave.clear();
    for (const nota of this.notas) {
      this.porId.add(nota.id);
      this.porClave.set(nota.clave, nota);
    }
  }

  /** Devuelve {estado:'nueva'|'duplicada'|'repetida', nota}. */
  agregar(nota) {
    if (this.porId.has(nota.id)) return { estado: 'duplicada', nota: this.porClave.get(nota.clave) || nota };

    const dia = nota.fecha_hecho.slice(0, 10);
    const clave = `${nota.tipo}|${nota.municipio}|${dia}`;
    const existente = this.porClave.get(clave);
    if (existente) {
      const fuentes = new Set([...(existente.fuentes || [existente.fuente]), nota.fuente]);
      existente.fuentes = [...fuentes];
      this.guardar();
      return { estado: 'repetida', nota: existente };
    }

    nota.clave = clave;
    nota.fuentes = [nota.fuente];
    nota.registrada = new Date().toISOString();
    this.notas.unshift(nota);
    this.porId.add(nota.id);
    this.porClave.set(clave, nota);
    this.guardar();
    return { estado: 'nueva', nota };
  }

  guardar() {
    const tmp = `${this.archivo}.tmp`;
    fs.mkdirSync(path.dirname(this.archivo), { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify({ actualizado: new Date().toISOString(), notas: this.notas }, null, 2));
    fs.renameSync(tmp, this.archivo); // atómico: nunca queda un JSON a medias
  }

  recientes(horas = 48) {
    const desde = Date.now() - horas * 3600_000;
    return this.notas.filter((n) => new Date(n.fecha_hecho).getTime() >= desde);
  }

  resumen() {
    const porTipo = {};
    for (const n of this.notas) porTipo[n.tipo] = (porTipo[n.tipo] || 0) + 1;
    return { total: this.notas.length, porTipo, ultima: this.notas[0]?.registrada || null };
  }
}

module.exports = { NoticiasDB };
