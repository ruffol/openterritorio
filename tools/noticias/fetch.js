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
const fb = require('./fb');

const FUENTES = [
  // afmedios entra por su API de WordPress (cuerpo completo, mejor que el RSS).
  { nombre: 'noticiasmanzanillo', url: 'https://noticiasmanzanillo.com/feed/' },
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
  {
    nombre: 'gnews-manzanillo',
    url: 'https://news.google.com/rss/search?q=Manzanillo+Colima+homicidio+OR+accidente&hl=es-419&gl=MX&ceid=MX:es-419',
  },
  {
    nombre: 'gnews-crimen-col',
    url: 'https://news.google.com/rss/search?q=%22Colima%22+(asesinato+OR+balacera+OR+volcadura+OR+atropellado)+when:2d&hl=es-419&gl=MX&ceid=MX:es-419',
  },
];

// Canales públicos de Telegram (t.me/s/<canal>): HTML estático, sin token ni
// API. Traen el texto, la hora exacta, la foto en alta y el enlace a la nota.
const TELEGRAM = ['afmedios', 'diariodecolima', 'noticiascolima'];

// Medios con WordPress: su API entrega el texto completo sin abrir el sitio.
const WORDPRESS = [
  { nombre: 'afmedios', url: 'https://www.afmedios.com' },
  { nombre: 'elpulsodecolima', url: 'https://elpulsodecolima.com' },
];

// Medios cuyo RSS está atrasado o no existe: se les lee el sitemap, que los
// medios actualizan al instante para Google y es texto ligero.
const SITEMAPS = [
  { nombre: 'colimanoticias', url: 'https://www.colimanoticias.com/sitemap.xml' },
  { nombre: 'meganoticias', url: 'https://meganoticias.mx/sitemap.xml', filtro: /colima/i },
  { nombre: 'elpulsodecolima', url: 'https://elpulsodecolima.com/sitemap.xml' },
];

// Portales que no publican RSS: se toman los titulares de su portada.
const PORTADAS = [
  { nombre: 'elpulsodecolima', url: 'https://elpulsodecolima.com/' },
  { nombre: 'meganoticias', url: 'https://meganoticias.mx/' },
  { nombre: 'diariodecolima', url: 'https://diariodecolima.com/' },
  // colima360.mx ya no existe: 1.1.1.1 y 8.8.8.8 devuelven NXDOMAIN desde
  // cualquier red, así que no es bloqueo de la operadora. Si reaparece con otro
  // dominio, se agrega aquí (o su canal de Telegram en TELEGRAM).
];

const UA = 'openterritorio/1.0 (monitor de notas de Colima; srtlalchichi@gmail.com)';

// Páginas vigiladas (se leen solo con FB_COOKIE configurada).
const PAGINAS_FB = ['afmedios', 'colimanoticias', '61578915771491'];

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

// Titulares de una portada que huelen a crimen o accidente.
const TITULAR = /<a[^>]+href="([^"]+)"[^>]*>([\s\S]{25,200}?)<\/a>/g;

async function leerPortada(fuente) {
  const respuesta = await fetch(fuente.url, {
    headers: { 'User-Agent': UA },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  });
  if (!respuesta.ok) throw new Error(`HTTP ${respuesta.status}`);
  const html = await respuesta.text();

  const notas = [];
  const vistas = new Set();
  for (const m of html.matchAll(TITULAR)) {
    const enlace = m[1];
    const titulo = decodificar(m[2]);
    if (titulo.length < 25 || vistas.has(titulo)) continue;
    if (!/homicid|ejecutad|asesinat|balacer|cadaver|cuerpo sin vida|acribillad|sicari|choque|volcadur|atropell|accidente|motociclis|asalto|robo|herido|lesionad|detenid|fallecid/i.test(titulo)) continue;
    vistas.add(titulo);
    notas.push({
      texto: titulo,
      fuente: fuente.nombre,
      url: new URL(enlace, fuente.url).toString(),
      publicado: Date.now(),
    });
    if (notas.length >= 8) break;
  }
  return notas;
}

/**
 * Lee un sitemap (o un índice) y devuelve las URLs recientes cuyo titular huela
 * a crimen o accidente. Usa `<news:title>` cuando el medio lo publica y, si no,
 * el slug del enlace.
 */
async function leerSitemap(fuente, horas, profundidad = 0) {
  const respuesta = await fetch(fuente.url, {
    headers: { 'User-Agent': UA, Accept: 'application/xml, text/xml' },
    redirect: 'follow',
    signal: AbortSignal.timeout(20000),
  });
  if (!respuesta.ok) throw new Error(`HTTP ${respuesta.status}`);
  const xml = await respuesta.text();
  const desde = Date.now() - horas * 3600_000;

  // Índice de sitemaps: se eligen los hijos de notas/posts y se abren hasta 4.
  if (/<sitemapindex/i.test(xml) && profundidad < 2) {
    const hijos = [...xml.matchAll(/<sitemap>[\s\S]*?<\/sitemap>/g)]
      .map((bloque) => {
        const loc = (bloque[0].match(/<loc>([^<]+)</) || [])[1];
        const numero = Number((loc || '').match(/-(\d+)\.xml/)?.[1] || 0);
        return {
          loc,
          numero,
          lastmod: Date.parse((bloque[0].match(/<lastmod>([^<]+)</) || [])[1] || 0) || 0,
        };
      })
      .filter((h) => h.loc);
    // Primero los que huelen a notas; si no hay, los más recientes.
    // Ojo: "wp-sitemap-taxonomies-post_tag" también contiene "post"; las
    // taxonomías (etiquetas, categorías, autores) no traen notas.
    const deNotas = hijos.filter(
      (h) => /posts?-post|wp-sitemap-posts|noticia|news|articulo|entrada/i.test(h.loc) &&
        !/taxonom|post_tag|post-format|category|author/i.test(h.loc),
    );
    // Los sitemaps numerados van de lo más viejo a lo más nuevo (post-1 =
    // 2013, post-8 = hoy), así que el número manda cuando falta lastmod.
    const elegidos = (deNotas.length ? deNotas : hijos)
      .sort((a, b) => b.lastmod - a.lastmod || b.numero - a.numero)
      .slice(0, 4);

    const notas = [];
    for (const hijo of elegidos) {
      try {
        const parcial = await leerSitemap({ nombre: fuente.nombre, url: hijo.loc, filtro: fuente.filtro }, horas, profundidad + 1);
        notas.push(...parcial);
      } catch {
        // un hijo caído no tumba el resto
      }
    }
    return notas;
  }

  const notas = [];
  const entradas = xml.match(/<url>[\s\S]*?<\/url>/g) || [];
  for (const entrada of entradas) {
    const loc = (entrada.match(/<loc>([^<]+)</) || [])[1];
    if (!loc) continue;
    const lastmod = (entrada.match(/<lastmod>([^<]+)</) || [])[1];
    const fechaNota =
      (entrada.match(/<news:publication_date>([^<]+)</) || [])[1] || lastmod;
    const cuando = fechaNota ? Date.parse(fechaNota) : 0;
    if (cuando && cuando < desde) continue;

    // Titular real si el medio publica el news sitemap; si no, el slug.
    const tituloNews = (entrada.match(/<news:title>([^<]+)</) || [])[1];
    const slug = decodeURIComponent((loc.split('/').filter(Boolean).pop() || '').replace(/[-_]/g, ' '));
    const titular = decodificar(tituloNews || slug);

    if (fuente.filtro && !fuente.filtro.test(`${loc} ${titular}`)) continue;
    if (!/homicid|ejecutad|asesinat|balacer|cadaver|cuerpo sin vida|acribillad|sicari|choque|volcadur|atropell|accidente|motociclis|asalto|robo |herido|lesionad|detenid|fallecid|localizan|vinculad/i.test(titular)) {
      continue;
    }
    notas.push({ texto: titular, fuente: fuente.nombre, url: loc, publicado: cuando || Date.now() });
    if (notas.length >= 12) break;
  }
  return notas;
}

const MUNICIPIOS_COLIMA = /colima|manzanillo|tecom[aá]n|villa de [aá]lvarez|comala|coquimatl[aá]n|cuauht[eé]moc|ixtlahuac[aá]n|minatitl[aá]n|armer[ií]a|cu[ú]yutl[aá]n|suchitl[aá]n/i;

/** Lee un canal público de Telegram con el HTML de su vista previa. */
async function leerTelegram(canal, horas) {
  const respuesta = await fetch(`https://t.me/s/${canal}`, {
    headers: { 'User-Agent': 'Mozilla/5.0 (Linux; Android 12)' },
    redirect: 'follow',
    signal: AbortSignal.timeout(20000),
  });
  if (!respuesta.ok) throw new Error(`HTTP ${respuesta.status}`);
  const html = await respuesta.text();
  const desde = Date.now() - horas * 3600_000;

  const notas = [];
  const bloques = html.match(/tgme_widget_message_wrap[\s\S]*?(?=tgme_widget_message_wrap|<\/main>)/g) || [];
  for (const bloque of bloques) {
    const crudo = (bloque.match(/class="tgme_widget_message_text[^"]*"[^>]*>([\s\S]*?)<\/div>/) || [])[1];
    if (!crudo) continue;
    const texto = decodificar(crudo);
    if (texto.length < 40) continue;

    // Solo lo del estado: el canal publica también notas nacionales.
    if (!MUNICIPIOS_COLIMA.test(texto)) continue;

    const cuando = Date.parse((bloque.match(/<time[^>]+datetime="([^"]+)"/) || [])[1] || 0) || Date.now();
    if (cuando < desde) continue;

    const foto = (bloque.match(/background-image:url\('([^']+)'\)/) || [])[1] || '';
    const enlace = (bloque.match(/class="tgme_widget_message_link_preview[^"]*"[^>]+href="([^"]+)"/) || [])[1] || '';

    notas.push({
      titulo: texto.slice(0, 200),
      texto,
      fuente: `tg:${canal}`,
      url: enlace || `https://t.me/${canal}`,
      publicado: cuando,
      imagen: foto,
      yaCompleta: true, // el mensaje ya trae texto y hora: no hace falta abrir el sitio
    });
  }
  return notas;
}

/** Lee las últimas entradas de un medio con WordPress (API REST pública). */
async function leerWordPress(fuente, horas) {
  const campos = 'link,title,date,excerpt,content,jetpack_featured_media_url';
  const desdeMs = Date.now() - horas * 3600_000;
  const desde = new Date(desdeMs).toISOString();
  const hasta = new Date().toISOString();

  // Se piden por páginas de 100 con el rango de fechas: así el relleno de
  // historial trae los tres días completos y no solo las últimas 20 notas.
  const lista = [];
  for (let pagina = 1; pagina <= 5; pagina += 1) {
    const url = `${fuente.url}/wp-json/wp/v2/posts?per_page=100&page=${pagina}` +
      `&after=${encodeURIComponent(desde)}&before=${encodeURIComponent(hasta)}&_fields=${campos}`;
    const respuesta = await fetch(url, {
      headers: { 'User-Agent': UA, Accept: 'application/json' },
      signal: AbortSignal.timeout(30000),
    });
    if (respuesta.status === 400) break; // no hay más páginas
    if (!respuesta.ok) throw new Error(`HTTP ${respuesta.status}`);
    const trozo = await respuesta.json();
    if (!Array.isArray(trozo) || trozo.length === 0) break;
    lista.push(...trozo);
    if (trozo.length < 100) break;
  }
  const desdeFiltro = desdeMs;

  const notas = [];
  for (const item of Array.isArray(lista) ? lista : []) {
    const texto = decodificar(item.content?.rendered || item.excerpt?.rendered || '');
    const titulo = decodificar(item.title?.rendered || '');
    const publicado = Date.parse(item.date || '') || 0;
    if (!texto || publicado < desdeFiltro) continue;
    notas.push({
      titulo,
      texto: texto.slice(0, 2500),
      fuente: fuente.nombre,
      url: item.link || fuente.url,
      publicado,
      imagen: item.jetpack_featured_media_url || '',
      yaCompleta: true,
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

/** Imagen social de la nota (og:image / twitter:image), ya absoluta. */
function imagenDe(html, base) {
  const m =
    html.match(/<meta[^>]+property=["']og:image(?::secure_url)?["'][^>]+content=["']([^"']+)["']/i) ||
    html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i) ||
    html.match(/<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']/i);
  if (!m) return '';
  try {
    return new URL(m[1], base).toString();
  } catch {
    return '';
  }
}

async function cuerpoDe(url) {
  if (!url || !/^https?:/.test(url)) return { texto: '', imagen: '' };
  try {
    const respuesta = await fetch(url, {
      headers: { 'User-Agent': UA },
      redirect: 'follow',
      signal: AbortSignal.timeout(15000),
    });
    if (!respuesta.ok) return { texto: '', imagen: '' };
    const html = await respuesta.text();
    const parrafos = html.match(/<p[^>]*>([\s\S]*?)<\/p>/g) || [];
    const texto = parrafos
      .map((p) => decodificar(p))
      .filter((t) => t.length > 40)
      .slice(0, 8)
      .join(' ')
      .slice(0, 2500);
    return { texto, imagen: imagenDe(html, url) };
  } catch {
    return { texto: '', imagen: '' };
  }
}

// Palabras vacías: no distinguen una nota de otra.
const VACIAS = new Set(['el','la','los','las','un','una','unos','unas','de','del','al','en','y','o','que','con','por','para','su','sus','se','lo','le','les','es','fue','son','tras','sobre','este','esta','estos','estas','como','mas','más','sin','al','ante','bajo','desde','entre','hasta','hacia','según','durante','mediante','porque','cuando','donde','quien','cual','han','ha','haber','ser','sus','nos','ya','no','ni','si','sí']);

/** Conjunto de palabras significativas de un texto. */
function tokens(texto) {
  return new Set(
    decodificar(String(texto || ''))
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .toLowerCase()
      .replace(/[^a-z0-9ñ ]/g, ' ')
      .split(/\s+/)
      .filter((t) => t.length > 2 && !VACIAS.has(t)),
  );
}

/** Similitud de Jaccard entre dos conjuntos (0 a 1). */
function similitud(a, b) {
  let comunes = 0;
  for (const t of a) if (b.has(t)) comunes += 1;
  const total = a.size + b.size - comunes;
  return total === 0 ? 0 : comunes / total;
}

/**
 * Deduplica por parecido real del texto (Jaccard sobre palabras), no por los
 * primeros caracteres: "Ejecutan a hombre en la Oriental" y "Balean a sujeto
 * en Colima" describen lo mismo aunque no compartan el inicio.
 */
function unicasSinDedup(notas, umbral = 0.62) {
  const salida = [];
  const conjuntos = [];
  for (const nota of notas) {
    const t = tokens(nota.texto);
    if (t.size === 0) continue;
    let repetida = false;
    for (const previo of conjuntos) {
      if (similitud(t, previo) >= umbral) {
        repetida = true;
        break;
      }
    }
    if (repetida) continue;
    conjuntos.push(t);
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

  // Telegram: el canal publica antes que el portal y trae foto y hora exacta.
  await Promise.all(
    TELEGRAM.map(async (canal) => {
      try {
        const notas = await leerTelegram(canal, horas);
        todas.push(...notas);
        console.log(`tg:${canal}: ${notas.length} mensajes de Colima`);
      } catch (error) {
        console.log(`tg:${canal}: error ${error.message}`);
      }
    }),
  );

  // WordPress: texto completo sin descargar la página entera.
  await Promise.all(
    WORDPRESS.map(async (medio) => {
      try {
        const notas = await leerWordPress(medio, horas);
        todas.push(...notas);
        console.log(`${medio.nombre} (wordpress): ${notas.length} notas`);
      } catch (error) {
        console.log(`${medio.nombre} (wordpress): error ${error.message}`);
      }
    }),
  );

  // Sitemaps: lo que el RSS de esos medios no entrega (o entrega atrasado).
  await Promise.all(
    SITEMAPS.map(async (fuente) => {
      try {
        const notas = await leerSitemap(fuente, horas);
        todas.push(...notas);
        console.log(`${fuente.nombre} (sitemap): ${notas.length} notas candidatas`);
      } catch (error) {
        console.log(`${fuente.nombre} (sitemap): error ${error.message}`);
      }
    }),
  );

  // Portales sin RSS: solo los titulares que huelen a nota de crimen/accidente.
  await Promise.all(
    PORTADAS.map(async (portal) => {
      try {
        const notas = await leerPortada(portal);
        todas.push(...notas);
        console.log(`${portal.nombre}: ${notas.length} titulares de portada`);
      } catch (error) {
        console.log(`${portal.nombre}: sin portada (${error.message})`);
      }
    }),
  );

  // Páginas de Facebook (solo si hay cookie de sesión guardada). Si no la hay,
  // se avisa y el monitor sigue con los RSS.
  for (const pagina of PAGINAS_FB) {
    const resultado = await fb.leerPagina(pagina);
    if (!resultado.ok) {
      // Sin cookie no hay nada que leer: se calla para no llenar el log.
      if (!/sin cookie/.test(resultado.motivo)) {
        console.log(`fb:${pagina}: omitida (${resultado.motivo})`);
      }
      continue;
    }
    for (const nota of resultado.notas) {
      todas.push({ ...nota, publicado: Date.now() });
    }
    console.log(`fb:${pagina}: ${resultado.notas.length} publicaciones`);
  }

  // Los agregadores solo dan el titular: para las notas que huelen a crimen o
  // accidente se abre el artículo, que es donde vienen la colonia y la hora.
  const candidatas = unicasSinDedup(todas).filter(
    (n) => !n.yaCompleta && SOSPECHOSO.test(n.texto),
  );
  let abiertas = 0;
  const lote = 5;
  for (let i = 0; i < candidatas.length; i += lote) {
    const grupo = candidatas.slice(i, i + lote);
    await Promise.all(
      grupo.map(async (nota) => {
        const cuerpo = await cuerpoDe(nota.url);
        if (cuerpo.texto) {
          nota.detalle = cuerpo.texto;
          abiertas++;
        }
        if (cuerpo.imagen) nota.imagen = cuerpo.imagen;
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

if (require.main === module) {
  main().catch((error) => {
    console.error('error:', error.message);
    process.exit(1);
  });
}

module.exports = {
  tokens,
  similitud,
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
  decodificar,
  leerRSS,
};
