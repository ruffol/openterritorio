'use strict';

/**
 * Vigía del túnel de Cloudflare.
 *
 * Cuando el teléfono cambia de red, `cloudflared` puede quedarse caído y el
 * dominio responde 530 (Cloudflare no encuentra el origen). El backend ya está
 * supervisado por runit, así que revisa cada minuto el estado del servicio del
 * túnel y lo levanta si no está corriendo. Cuesta un `sv status` por minuto.
 */

const { spawnSync } = require('node:child_process');

function crearVigiaTunel({ log, servicio = 'cloudflared', intervaloMs = 60_000 }) {
  let timer = null;
  let primera = null;
  const estado = { revisiones: 0, reinicios: 0, ultima: null, ultimoEstado: null };

  function correr(args) {
    const resultado = spawnSync('sv', args, { encoding: 'utf8' });
    if (resultado.error) return null; // no hay runit aquí (PC de desarrollo)
    return `${resultado.stdout || ''}${resultado.stderr || ''}`.trim();
  }

  function revisar() {
    const salida = correr(['status', servicio]);
    if (salida === null) return;

    estado.revisiones += 1;
    estado.ultima = new Date().toISOString();
    estado.ultimoEstado = salida.split('\n')[0].slice(0, 120);

    // runit responde "run: <servicio>: (pid …) …" cuando está vivo.
    if (/^\s*run:/m.test(salida)) return;

    const resultado = correr(['up', servicio]);
    estado.reinicios += 1;
    log.warn('túnel levantado por el vigía', {
      servicio,
      antes: estado.ultimoEstado,
      despues: (resultado || '').slice(0, 120),
    });
  }

  return {
    arrancar() {
      primera = setTimeout(revisar, 15_000);
      timer = setInterval(revisar, intervaloMs);
      primera.unref?.();
      timer.unref?.();
      log.info('vigía del túnel activo', { servicio, cada_s: Math.round(intervaloMs / 1000) });
    },
    detener() {
      if (primera) clearTimeout(primera);
      if (timer) clearInterval(timer);
    },
    revisarAhora: revisar,
    estado: () => ({ ...estado }),
  };
}

module.exports = { crearVigiaTunel };
