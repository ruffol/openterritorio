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

function crearVigiaTunel({
  log,
  servicio = 'cloudflared',
  intervaloMs = 60_000,
  publicUrl = '',
  enfriamientoMs = 5 * 60_000,
}) {
  let timer = null;
  let primera = null;
  let ultimoReinicio = 0;
  const estado = {
    revisiones: 0,
    reinicios: 0,
    ultima: null,
    ultimoEstado: null,
    publico: null,
  };

  /** ¿El dominio responde? Es la prueba real: el proceso puede estar vivo y
   *  el túnel muerto (pasó con el cambio de red). */
  async function publicoResponde() {
    if (!publicUrl) return null;
    try {
      const respuesta = await fetch(`${publicUrl.replace(/\/+$/, '')}/healthz`, {
        signal: AbortSignal.timeout(8000),
      });
      estado.publico = respuesta.status;
      return respuesta.ok;
    } catch (error) {
      estado.publico = `sin respuesta: ${error.name}`;
      return false;
    }
  }

  function correr(args) {
    const resultado = spawnSync('sv', args, { encoding: 'utf8' });
    if (resultado.error) return null; // no hay runit aquí (PC de desarrollo)
    return `${resultado.stdout || ''}${resultado.stderr || ''}`.trim();
  }

  async function revisar() {
    // 1) Si el dominio público no responde, se reinicia el túnel (con freno).
    const vivo = await publicoResponde();
    if (vivo === false) {
      if (Date.now() - ultimoReinicio < enfriamientoMs) {
        log.warn('túnel caído; esperando el enfriamiento antes de reiniciar');
        return;
      }
      const resultado = correr(['restart', servicio]);
      ultimoReinicio = Date.now();
      estado.reinicios += 1;
      estado.revisiones += 1;
      estado.ultima = new Date().toISOString();
      log.warn('túnel reiniciado por el vigía', {
        servicio,
        publico: estado.publico,
        resultado: (resultado || '').slice(0, 120),
      });
      return;
    }

    // 2) Si el servicio no está corriendo, se levanta.
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
      primera = setTimeout(() => revisar().catch(() => {}), 20_000);
      timer = setInterval(() => revisar().catch(() => {}), intervaloMs);
      primera.unref?.();
      timer.unref?.();
        log.info('vigía del túnel activo', {
        servicio,
        cada_s: Math.round(intervaloMs / 1000),
        publico: publicUrl || '(sin PUBLIC_URL: solo vigila el proceso)',
      });
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
