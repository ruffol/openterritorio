'use strict';
// Extrae publicaciones del HTML que Facebook sirve con sesión: cada historia
// viaja en un JSON embebido (`__typename: "Story"`) con creation_time, post_id
// y el texto del mensaje.
const fs = require('node:fs');

function decodificarJson(crudo) {
  try {
    return JSON.parse(`"${crudo}"`);
  } catch {
    return crudo.replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\//g, '/');
  }
}

function extraer(html, fuente) {
  const texto = String(html);
  const notas = [];
  const vistos = new Set();
  const patron = /"message":\{"text":"((?:[^"\\]|\\.)*)"/g;
  let match;
  while ((match = patron.exec(texto)) !== null) {
    const mensaje = decodificarJson(match[1]).trim();
    if (mensaje.length < 40) continue;

    // creation_time y post_id: el más cercano por delante y por detrás.
    const detras = texto.slice(Math.max(0, match.index - 6000), match.index);
    const delante = texto.slice(match.index, Math.min(texto.length, match.index + 3000));
    const tiempos = [...detras.matchAll(/"creation_time":(\d{9,11})/g)];
    const cuando = tiempos.length
      ? Number(tiempos[tiempos.length - 1][1])
      : Number((delante.match(/"creation_time":(\d{9,11})/) || [])[1] || 0);
    const postId = (delante.match(/"post_id":"(\d+)"/) || [])[1] ||
      ([...detras.matchAll(/"post_id":"(\d+)"/g)].pop() || [])[1] || '';

    const llave = postId || mensaje.slice(0, 60);
    if (vistos.has(llave)) continue;
    vistos.add(llave);
    notas.push({
      texto: mensaje,
      titulo: mensaje.slice(0, 200),
      fuente,
      url: postId ? `https://www.facebook.com/${fuente}/posts/${postId}` : `https://www.facebook.com/${fuente}`,
      publicado: cuando ? cuando * 1000 : Date.now(),
      yaCompleta: true,
    });
  }
  return notas;
}

if (require.main === module) {
  const html = fs.readFileSync(process.argv[2], 'utf8');
  const notas = extraer(html, 'afmedios');
  console.log('publicaciones:', notas.length);
  for (const n of notas.slice(0, 6)) {
    console.log('  ·', new Date(n.publicado).toISOString().slice(0, 16), '|', n.texto.replace(/\s+/g, ' ').slice(0, 90));
  }
}

module.exports = { extraer };
