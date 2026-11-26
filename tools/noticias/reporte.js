#!/usr/bin/env node
'use strict';

/**
 * Informe del monitor de noticias: qué entra, qué se descarta y por qué.
 *
 *   node tools/noticias/reporte.js --out docs/informe-noticias.html
 *
 * Hace la misma pasada que el monitor (sin publicar) y deja un HTML con el
 * embudo completo, el estado de cada fuente y los sucesos que sí pasaron el
 * filtro. El PDF se genera abriendo ese HTML y guardándolo como PDF.
 */

const fs = require('node:fs');
const path = require('node:path');
const { analizar } = require('./parse');
const { analizarNota } = require('./evaluar');
const {
  FUENTES,
  PORTADAS,
  SITEMAPS,
  TELEGRAM,
  WORDPRESS,
  descargar,
  leerPortada,
  leerSitemap,
  leerTelegram,
  leerWordPress,
  cuerpoDe,
} = require('./fetch');
const { NoticiasDB } = require('./db');

const SOSPECHOSO = /homicid|ejecutad|asesinat|balacer|cadaver|cuerpo sin vida|acribillad|sicari|choque|volcadur|atropell|accidente|motociclis|asalto|robo|herido|lesionad|detenid|fallecid/i;

function esc(texto) {
  return String(texto == null ? '' : texto)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function fmtFecha(ms) {
  if (!ms || Number.isNaN(ms)) return '—';
  return new Date(ms).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' });
}

async function recolectar(horas) {
  const desde = Date.now() - horas * 3600_000;
  const fuentes = [];
  const todas = [];

  await Promise.all(
    FUENTES.map(async (fuente) => {
      try {
        const notas = await descargar(fuente);
        const recientes = notas.filter((n) => !Number.isNaN(n.publicado) && n.publicado >= desde);
        const masNueva = notas.reduce((max, n) => Math.max(max, n.publicado || 0), 0);
        fuentes.push({
          nombre: fuente.nombre,
          tipo: 'RSS',
          url: fuente.url,
          estado: 'ok',
          items: notas.length,
          recientes: recientes.length,
          masNueva,
        });
        todas.push(...recientes);
      } catch (error) {
        fuentes.push({
          nombre: fuente.nombre,
          tipo: 'RSS',
          url: fuente.url,
          estado: `error: ${error.message}`,
          items: 0,
          recientes: 0,
          masNueva: 0,
        });
      }
    }),
  );

  await Promise.all(
    TELEGRAM.map(async (canal) => {
      try {
        const notas = await leerTelegram(canal, horas);
        fuentes.push({
          nombre: `tg:${canal}`,
          tipo: 'telegram',
          url: `https://t.me/s/${canal}`,
          estado: notas.length ? 'ok' : 'sin mensajes de Colima',
          items: notas.length,
          recientes: notas.length,
          masNueva: notas.reduce((m, n) => Math.max(m, n.publicado || 0), 0),
        });
        todas.push(...notas);
      } catch (error) {
        fuentes.push({ nombre: `tg:${canal}`, tipo: 'telegram', url: `https://t.me/s/${canal}`,
          estado: `error: ${error.message}`, items: 0, recientes: 0, masNueva: 0 });
      }
    }),
  );

  await Promise.all(
    WORDPRESS.map(async (medio) => {
      try {
        const notas = await leerWordPress(medio, horas);
        fuentes.push({
          nombre: `${medio.nombre} (wp)`,
          tipo: 'wordpress',
          url: medio.url,
          estado: 'ok',
          items: notas.length,
          recientes: notas.length,
          masNueva: notas.reduce((m, n) => Math.max(m, n.publicado || 0), 0),
        });
        todas.push(...notas);
      } catch (error) {
        fuentes.push({ nombre: `${medio.nombre} (wp)`, tipo: 'wordpress', url: medio.url,
          estado: `error: ${error.message}`, items: 0, recientes: 0, masNueva: 0 });
      }
    }),
  );

  await Promise.all(
    SITEMAPS.map(async (fuente) => {
      try {
        const notas = await leerSitemap(fuente, horas);
        fuentes.push({
          nombre: `${fuente.nombre} (sitemap)`,
          tipo: 'sitemap',
          url: fuente.url,
          estado: notas.length > 0 ? 'ok' : 'sin notas nuevas',
          items: notas.length,
          recientes: notas.length,
          masNueva: notas.reduce((max, n) => Math.max(max, n.publicado || 0), 0),
        });
        todas.push(...notas);
      } catch (error) {
        fuentes.push({
          nombre: `${fuente.nombre} (sitemap)`,
          tipo: 'sitemap',
          url: fuente.url,
          estado: `error: ${error.message}`,
          items: 0,
          recientes: 0,
          masNueva: 0,
        });
      }
    }),
  );

  await Promise.all(
    PORTADAS.map(async (portal) => {
      try {
        const notas = await leerPortada(portal);
        fuentes.push({
          nombre: portal.nombre,
          tipo: 'portada',
          url: portal.url,
          estado: 'ok',
          items: notas.length,
          recientes: notas.length,
          masNueva: Date.now(),
        });
        todas.push(...notas);
      } catch (error) {
        fuentes.push({
          nombre: portal.nombre,
          tipo: 'portada',
          url: portal.url,
          estado: `sin portada (${error.message})`,
          items: 0,
          recientes: 0,
          masNueva: 0,
        });
      }
    }),
  );

  // Deduplicado por texto.
  const vistas = new Set();
  const unicas = [];
  for (const nota of todas) {
    const llave = nota.texto.toLowerCase().replace(/[^a-z0-9 ]/g, '').slice(0, 120);
    if (vistas.has(llave)) continue;
    vistas.add(llave);
    unicas.push(nota);
  }

  // Se abren las notas que huelen a suceso, como en la operación real.
  const sospechosas = unicas.filter((n) => SOSPECHOSO.test(n.texto));
  let abiertas = 0;
  for (let i = 0; i < sospechosas.length; i += 5) {
    await Promise.all(
      sospechosas.filter((n) => !n.yaCompleta).slice(i, i + 5).map(async (nota) => {
        const cuerpo = await cuerpoDe(nota.url);
        if (cuerpo.texto) {
          nota.detalle = cuerpo.texto;
          abiertas += 1;
        }
        if (cuerpo.imagen) nota.imagen = cuerpo.imagen;
      }),
    );
  }

  return { fuentes, todas, unicas, sospechosas, abiertas };
}

/** Estado del monitor que corre en el teléfono (si hay token). */
async function estadoTelefono() {
  const base = (process.env.OPENTERITORIO_URL || 'https://tienda.tlalchichi.xyz').replace(/\/+$/, '');
  const token = process.env.OPENTERITORIO_TOKEN || '';
  if (!token) return null;
  try {
    const respuesta = await fetch(`${base}/api/admin/monitor`, {
      headers: { Authorization: 'Bearer ' + token, 'User-Agent': 'openterritorio-reporte/1.0' },
      signal: AbortSignal.timeout(15000),
    });
    if (!respuesta.ok) return null;
    return await respuesta.json();
  } catch {
    return null;
  }
}

async function main() {
  const argv = process.argv.slice(2);
  const out = argv.includes('--out') ? argv[argv.indexOf('--out') + 1] : 'docs/informe-noticias.html';
  const horas = argv.includes('--horas') ? Number(argv[argv.indexOf('--horas') + 1]) : 72;

  console.log(`recolectando (ventana ${horas} h)…`);
  const telefono = await estadoTelefono();
  const { fuentes, todas, unicas, sospechosas, abiertas } = await recolectar(horas);

  const db = new NoticiasDB(path.join(__dirname, 'noticias.json'));
  const motivos = new Map();
  const eventos = [];

  let rescatadas = 0;
  for (const nota of unicas) {
    const texto = nota.detalle ? `${nota.texto}. ${nota.detalle}` : nota.texto;
    const { nota: resultado, motivo, rescatada } = await analizarNota({ ...nota, texto });
    if (motivo) {
      motivos.set(motivo, (motivos.get(motivo) || 0) + 1);
    } else if (resultado) {
      if (rescatada) rescatadas += 1;
      eventos.push({ ...resultado, fuente: nota.fuente, url: nota.url, imagen: nota.imagen || '' });
    }
  }

  // La base que importa es la del teléfono (el JSON local solo existe si se
  // ejecutó aquí); se prefiere el dato de producción.
  const guardadas = telefono?.resultado?.guardadas ?? db.notas.length;
  const conImagen = db.notas.filter((n) => n.imagen).length;
  const porTipo = {};
  for (const n of db.notas) porTipo[n.tipo] = (porTipo[n.tipo] || 0) + 1;

  const ahora = new Date().toLocaleString('es-MX', { dateStyle: 'long', timeStyle: 'short' });
  const embudo = [
    ['Notas recogidas de las fuentes', todas.length],
    ['Notas únicas (sin repetir entre medios)', unicas.length],
    ['Candidatas por palabra clave', sospechosas.length],
    ['Artículos abiertos para leer el cuerpo', abiertas],
    ['Sucesos con tipo + lugar (van al mapa)', eventos.length],
    ['  de ellos ubicados por geocodificación OSM', rescatadas],
  ];
  const base = Math.max(1, todas.length);

  const filasFuentes = fuentes
    .sort((a, b) => b.recientes - a.recientes)
    .map((f) => {
      const estado = f.estado === 'ok' ? '<span class="ok">ok</span>' : `<span class="bad">${esc(f.estado)}</span>`;
      return `<tr><td>${esc(f.nombre)}</td><td>${f.tipo}</td><td>${estado}</td><td class="num">${f.items}</td>
        <td class="num">${f.recientes}</td><td class="num">${fmtFecha(f.masNueva)}</td></tr>`;
    })
    .join('');

  const filasMotivos = [...motivos.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([motivo, n]) => `<tr><td>${esc(motivo)}</td><td class="num">${n}</td>
      <td class="num">${((n / Math.max(1, unicas.length)) * 100).toFixed(0)} %</td></tr>`)
    .join('');

  const filasEventos = eventos.length
    ? eventos
        .map(
          (e) => `<tr><td>${esc(e.tipo)}</td><td>${esc(e.lugar)}</td>
            <td class="num">${e.lat.toFixed(4)}, ${e.lon.toFixed(4)}</td>
            <td>${esc(new Date(e.fecha_hecho).toLocaleString('es-MX', { dateStyle: 'short', timeStyle: 'short' }))}</td>
            <td>${esc(e.precision_hora)} · ${esc(e.precision_lugar)}</td><td>${esc(e.fuente)}</td></tr>`,
        )
        .join('')
    : '<tr><td colspan="6" class="vacio">Ningún suceso pasó el filtro en esta ventana.</td></tr>';

  const html = `<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<title>Informe del monitor de noticias</title>
<style>
  @page { size: A4; margin: 14mm; }
  body { font-family: "Segoe UI", Roboto, sans-serif; color:#16202b; font-size: 10.5px; line-height:1.45; }
  h1 { font-size: 19px; margin: 0 0 2px; }
  h2 { font-size: 13px; margin: 20px 0 6px; padding-bottom:3px; border-bottom:1px solid #d8e0e8; color:#0f4c81; }
  .sub { color:#5b6b7c; font-size:10px; margin-bottom:14px; }
  .kpis { display:flex; gap:8px; margin:12px 0 4px; }
  .kpi { flex:1; border:1px solid #dde5ec; border-radius:6px; padding:8px 10px; background:#f7fafc; }
  .kpi b { display:block; font-size:19px; color:#0f4c81; }
  .kpi span { color:#5b6b7c; font-size:9px; text-transform:uppercase; letter-spacing:.4px; }
  table { width:100%; border-collapse:collapse; margin-top:4px; }
  th { text-align:left; font-size:9px; text-transform:uppercase; letter-spacing:.4px; color:#5b6b7c;
       border-bottom:1px solid #cfd9e3; padding:4px 5px; }
  td { padding:4px 5px; border-bottom:1px solid #eef2f6; vertical-align:top; }
  td.num, th.num { text-align:right; }
  .ok { color:#1a7f4b; font-weight:600; } .bad { color:#b3261e; }
  .vacio { color:#5b6b7c; font-style:italic; }
  .barra { display:flex; align-items:center; gap:8px; margin:3px 0; }
  .barra .et { width:290px; } .barra .med { height:9px; border-radius:3px; background:#0f4c81; }
  .barra .n { color:#5b6b7c; }
  ul { margin:4px 0 0 16px; padding:0; } li { margin-bottom:3px; }
  .nota { background:#f7fafc; border-left:3px solid #0f4c81; padding:7px 10px; margin-top:6px; border-radius:3px; }
  .pie { margin-top:18px; color:#5b6b7c; font-size:9px; border-top:1px solid #e3e9ef; padding-top:6px; }
</style></head><body>
<h1>Monitor de noticias — cómo se obtienen y qué se está perdiendo</h1>
<div class="sub">Generado el ${esc(ahora)} · ventana analizada: últimas ${horas} horas · datos reales de una pasada completa</div>

<div class="kpis">
  <div class="kpi"><b>${todas.length}</b><span>notas recogidas</span></div>
  <div class="kpi"><b>${unicas.length}</b><span>notas únicas</span></div>
  <div class="kpi"><b>${sospechosas.length}</b><span>candidatas</span></div>
  <div class="kpi"><b>${eventos.length}</b><span>sucesos al mapa</span></div>
  <div class="kpi"><b>${guardadas}</b><span>en la base</span></div>
</div>

<h2>1. De dónde salen las noticias</h2>
<p>El monitor corre dentro del backend cada 15 minutos y hace cinco pasos:</p>
<ul>
  <li><b>Recolección:</b> RSS de los medios de Colima y búsquedas de Google Noticias acotadas al estado.</li>
  <li><b>Portadas:</b> en los medios sin RSS se leen los titulares de la portada y solo se siguen los que mencionan crimen o accidente.</li>
  <li><b>Apertura:</b> de cada candidata se descarga el artículo completo, porque el titular casi nunca dice dónde ni a qué hora.</li>
  <li><b>Clasificación y ubicación:</b> tabla de palabras por tipo de suceso y gacetero de 3 896 localidades del INEGI (más las 10 cabeceras municipales).</li>
  <li><b>Publicación:</b> el suceso se guarda con dos candados anti-repetición y se manda al mapa como evento con caducidad de 24 h, con cita, foto y enlace.</li>
</ul>
<p><b>Facebook no es una fuente utilizable:</b> con la sesión iniciada, <code>mbasic</code> devuelve una cáscara que arma el contenido con JavaScript y <code>www</code>/<code>m</code> responden 400. Por eso el contenido equivalente se toma del sitio del propio medio.</p>

<h2>2. Estado de cada fuente (últimas ${horas} h)</h2>
<table><thead><tr><th>Fuente</th><th>Tipo</th><th>Estado</th><th class="num">Ítems</th><th class="num">En ventana</th><th class="num">Más reciente</th></tr></thead>
<tbody>${filasFuentes}</tbody></table>

<h2>3. Embudo: dónde se pierden las notas</h2>
${embudo
  .map(
    ([etiqueta, n]) => `<div class="barra"><div class="et">${esc(etiqueta)}</div>
      <div class="med" style="width:${Math.max(2, (n / base) * 300)}px"></div>
      <div class="n">${n}</div></div>`,
  )
  .join('')}

<h2>4. Por qué se descarta cada nota</h2>
<table><thead><tr><th>Motivo</th><th class="num">Notas</th><th class="num">% de las únicas</th></tr></thead>
<tbody>${filasMotivos || '<tr><td colspan="3" class="vacio">Sin descartes en esta ventana.</td></tr>'}</tbody></table>
<div class="nota">La regla más costosa es <b>«solo dice Colima/Villa»</b>: una nota que cuenta un homicidio «en Colima» sin colonia ni vía no se marca, para no llenar la capital de puntos falsos. Es la decisión que más cobertura resta y la que conviene revisar.</div>

<h2>5. Sucesos que sí pasaron el filtro</h2>
<table><thead><tr><th>Tipo</th><th>Lugar</th><th class="num">Coordenadas</th><th>Hora del hecho</th><th>Precisión</th><th>Fuente</th></tr></thead>
<tbody>${filasEventos}</tbody></table>

<h2>6. Cómo va en el teléfono (producción)</h2>
${
  telefono
    ? `<p>El monitor corre dentro del backend, cada ${Math.round((telefono.intervaloS || 900) / 60)} min ·
         ejecuciones: <b>${telefono.ejecuciones ?? 0}</b> · errores: <b>${telefono.errores ?? 0}</b> ·
         última: ${esc(telefono.ultima ? new Date(telefono.ultima).toLocaleString('es-MX') : '—')}</p>
       <p>Última pasada: procesadas ${telefono.resultado?.procesadas ?? 0} ·
         nuevas ${telefono.resultado?.nuevas ?? 0} · descartadas ${telefono.resultado?.descartadas ?? 0} ·
         acumuladas ${telefono.resultado?.guardadas ?? 0}</p>
       <pre style="background:#f2f6fa;padding:8px;border-radius:4px;font-size:8.5px;white-space:pre-wrap;max-height:120px;overflow:hidden">${esc(
         String(telefono.log || '').split('\n').slice(-6).join('\n'),
       )}</pre>`
    : '<p class="vacio">Sin datos del teléfono: ejecuta el informe con OPENTERITORIO_TOKEN definido.</p>'
}

<h2>7. Base acumulada</h2>
<p>${guardadas} notas guardadas · ${conImagen} con foto · por tipo: ${
    Object.entries(porTipo).map(([t, n]) => `${esc(t)} ${n}`).join(' · ') || 'sin registros'
  }</p>

<h2>8. Qué conviene mejorar (en orden de impacto)</h2>
<ul>
  <li><b>Más medios con RSS propio.</b> Hoy solo dos alimentan de verdad; el resto aporta poco o está caído. Cada medio nuevo suma notas que los demás no publican.</li>
  <li><b>Leer el cuerpo de todas las notas que mencionen crimen</b>, no solo las del titular: el lugar y la hora están en el texto.</li>
  <li><b>Marcador municipal con aviso</b> (ya implementado como «(aprox)») y, si se acepta, un radio de incertidumbre en vez de un punto.</li>
  <li><b>Ampliar el gacetero</b> con colonias y fraccionamientos (OpenStreetMap), que es justo lo que hoy obliga a descartar notas de la capital.</li>
  <li><b>Deduplicar entre medios por texto del cuerpo</b>, no por los primeros 120 caracteres del titular.</li>
  <li><b>Alertar cuando una fuente deja de responder</b>: un feed caído se nota hoy solo al revisar el informe.</li>
</ul>

<div class="pie">Informe generado por tools/noticias/reporte.js · datos obtenidos en vivo en el momento de la ejecución.</div>
</body></html>`;

  fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
  fs.writeFileSync(out, html, 'utf8');
  console.log(
    JSON.stringify(
      {
        todas: todas.length,
        unicas: unicas.length,
        sospechosas: sospechosas.length,
        abiertas,
        eventos: eventos.length,
        motivos: Object.fromEntries(motivos),
        fuentes: fuentes.map((f) => ({ nombre: f.nombre, estado: f.estado, recientes: f.recientes })),
        html: path.resolve(out),
      },
      null,
      2,
    ),
  );
}

main().catch((error) => {
  console.error('error:', error.message);
  process.exit(1);
});
