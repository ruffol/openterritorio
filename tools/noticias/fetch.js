#!/usr/bin/env node
'use strict';

/**
 * Descarga las notas de los medios de Colima y las deja en un JSON listo
 * para `run.js`.
 *
 *   node tools/noticias/fetch.js --out notas.json [--horas 24]
 *
 * Fuentes: los RSS de los propios medios (funcionan sin cuenta ni login) y
 * búsquedas de Google Noticias acotadas a Colima. Las páginas de Facebook no
 * se pueden leer sin sesión desde Termux — mbasic responde 400 y los puentes
 * RSS públicos están bloqueados — así que el mismo contenido se toma del sitio
 * del medio, que publica lo mismo y sí entrega RSS.
 */

const fs = require('node:fs');

const FUENTES = [
  { nombre: 'afmedios', url: 'https://afmedios.com/feed/' },
  { nombre: 'colimanoticias', url: 'https://www.colimanoticias.com/feed/' },
  {
    nombre: 'gnews-homicidio',
    url: 'https://news.google.com/rss/search?q=Colima+homicidio+OR+ejecutado+OR+balacera&hl=es-419&gl=MX&ceid=MX:es-419',
  },
  {
    nombre: 'gnews-accidente',
    url: 'https://news.google.com/rss/search?q=Colima+choque+OR+volcadura+OR+atropellado&hl=es-419&gl=MX&ceid=MX:es-419',
  },
  {
    nombre: 'gnews-crimen',
    url: 'https://news.google.com/rss/search?q=Colima+cuerpo+sin+vida+OR+asesinato+OR+robo&hl=es-419&gl=MX&ceid=MX:es-419',
  },
];

const UA = 'openterritorio/1.0 (monitor de notas de Colima; srtlalchichi@gmail.com)';

function decodificar(texto) {
  return String(texto || '')
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .replace(/\s+/g, ' ')
    .trim();
}

function campo(item, etiqueta) {
  const m = item.match(new RegExp(`<${etiqueta}[^>]*>([\\s\\S]*?)</${etiqueta}>`));
  return m ? decodificar(m[1]) : '';
}

function leerRSS(xml, fuente) {
  const notas = [];
  const items = xml.match(/<item[\s\S]*?<\/item>/g) || [];
  for (const item of items) {
    const titulo = campo(item, 'title');
    const descripcion = campo(item, 'description');
    const fecha = campo(item, 'pubDate');
    const enlace = campo(item, 'link');
    const texto = [titulo, descripcion].filter(Boolean).join('. ').trim();
    if (!texto) continue;
    notas.push({
      texto,
      fuente: fuente.nombre,
      url: enlace,
      publicado: fecha ? Date.parse(fecha) : Date.now(),
    });
  }
  return notas;
}

async function descargar(fuente) {
  const respuesta = await fetch(fuente.url, {
    headers: { 'User-Agent': UA, Accept: 'application/rss+xml, application/xml, text/xml' },
    redirect: 'follow',
  });
  if (!respuesta.ok) throw new Error(`HTTP ${respuesta.status}`);
  return leerRSS(await respuesta.text(), fuente);
}

// Titulares que merecen abrir la nota completa (ahí vienen la colonia y la hora).
const SOSPECHOSO = /homicid|ejecutad|asesinat|balacer|cadaver|cuerpo sin vida|acribillad|sicari|choque|volcadur|atropell|accidente|motociclis|asalto|robo|herido|lesionad|detenid|fallecid/i;

async function cuerpoDe(url) {
  if (!url || !/^https?:/.test(url)) return '';
  try {
    const respuesta = await fetch(url, {
      headers: { 'User-Agent': UA },
      redirect: 'follow',
      signal: AbortSignal.timeout(15000),
    });
    if (!respuesta.ok) return '';
    const html = await respuesta.text();
    // Se queda con el texto visible de los párrafos.
    const parrafos = html.match(/<p[^>]*>([\s\S]*?)<\/p>/g) || [];
    return parrafos
      .map((p) => decodificar(p))
      .filter((t) => t.length > 40)
      .slice(0, 8)
      .join(' ')
      .slice(0, 2500);
  } catch {
    return '';
  }
}

function unicasSinDedup(notas) {
  const vistas = new Set();
  const salida = [];
  for (const nota of notas) {
    const llave = nota.texto.toLowerCase().replace(/[^a-z0-9 ]/g, '').slice(0, 120);
    if (vistas.has(llave)) continue;
    vistas.add(llave);
    salida.push(nota);
  }
  return salida;
}

async function main() {
  const argv = process.argv.slice(2);
  const salida = argv.includes('--out') ? argv[argv.indexOf('--out') + 1] : 'notas.json';
  const horas = argv.includes('--horas') ? Number(argv[argv.indexOf('--horas') + 1]) : 72;
  const desde = Date.now() - horas * 3600_000;

  const todas = [];
  const errores = [];
  await Promise.all(
    FUENTES.map(async (fuente) => {
      try {
        const notas = await descargar(fuente);
        const recientes = notas.filter((n) => !Number.isNaN(n.publicado) && n.publicado >= desde);
        todas.push(...recientes);
        console.log(`${fuente.nombre}: ${recientes.length}/${notas.length} notas de las últimas ${horas} h`);
      } catch (error) {
        errores.push(`${fuente.nombre}: ${error.message}`);
        console.log(`${fuente.nombre}: error ${error.message}`);
      }
    }),
  );

  // Los agregadores solo dan el titular: para las notas que huelen a crimen o
  // accidente se abre el artículo, que es donde vienen la colonia y la hora.
  const candidatas = unicasSinDedup(todas).filter((n) => SOSPECHOSO.test(n.texto));
  let abiertas = 0;
  const lote = 5;
  for (let i = 0; i < candidatas.length; i += lote) {
    const grupo = candidatas.slice(i, i + lote);
    await Promise.all(
      grupo.map(async (nota) => {
        const cuerpo = await cuerpoDe(nota.url);
        if (cuerpo) {
          nota.detalle = cuerpo;
          abiertas++;
        }
      }),
    );
  }

  // Deduplicado por texto: los agregadores repiten la misma nota.
  const vistas = new Set();
  const unicas = [];
  for (const nota of unicasSinDedup(todas)) {
    const texto = nota.detalle ? `${nota.texto}. ${nota.detalle}` : nota.texto;
    const llave = texto.toLowerCase().replace(/[^a-z0-9 ]/g, '').slice(0, 120);
    if (vistas.has(llave)) continue;
    vistas.add(llave);
    unicas.push({ ...nota, texto });
  }

  fs.writeFileSync(salida, JSON.stringify({ generado: new Date().toISOString(), notas: unicas }, null, 2));
  console.log(`artículos abiertos: ${abiertas}`);
  console.log(`guardadas ${unicas.length} notas en ${salida}${errores.length ? ` | ${errores.length} fuentes con error` : ''}`);
}

main().catch((error) => {
  console.error('error:', error.message);
  process.exit(1);
});
