'use strict';

/**
 * Planificador del monitor de notas dentro del propio backend.
 *
 * Cada `intervalMs` ejecuta la tubería (fetch + run) como proceso hijo, con el
 * token y la URL de este mismo servidor, y guarda el resultado en memoria y en
 * `logs/noticias.log`. Va aquí y no en un servicio aparte porque el backend ya
 * está supervisado por runit: así el monitor arranca con él y su estado se
 * consulta por HTTP, sin necesidad de tocar el teléfono.
 */

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

function crearMonitor({ appRoot, baseUrl, token, intervalMs = 15 * 60_000, log }) {
  const logDir = path.join(appRoot, 'logs');
  const logFile = path.join(logDir, 'noticias.log');
  const carpeta = path.join(appRoot, 'app', 'noticias');
  const estado = {
    habilitado: true,
    intervaloS: Math.round(intervalMs / 1000),
    ultima: null,
    corriendo: false,
    ejecuciones: 0,
    errores: 0,
    resultado: null,
  };

  let timer = null;
  let primera = null;

  function anotar(texto) {
    try {
      fs.mkdirSync(logDir, { recursive: true });
      fs.appendFileSync(logFile, `${new Date().toISOString()} ${texto}\n`);
    } catch {
      // sin disco lleno de logs no se cae el servidor
    }
  }

  function correrPaso(script, args) {
    return new Promise((resolve) => {
      const hijo = spawn(process.execPath, [path.join(carpeta, script), ...args], {
        cwd: appRoot,
        env: {
          ...process.env,
          OPENTERITORIO_URL: baseUrl,
          OPENTERITORIO_TOKEN: token,
        },
      });
      let salida = '';
      let errores = '';
      hijo.stdout.on('data', (d) => {
        salida += d.toString();
      });
      hijo.stderr.on('data', (d) => {
        errores += d.toString();
      });
      // El resumen va por stdout; los avisos (por ejemplo, "sin gacetero") por
      // stderr, y mezclarlos rompía el JSON.
      hijo.on('exit', (code) => resolve({ code, salida, errores }));
      hijo.on('error', (error) => resolve({ code: -1, salida: '', errores: error.message }));
    });
  }

  async function ciclo() {
    if (estado.corriendo) return;
    estado.corriendo = true;
    const notas = path.join(appRoot, 'notas.json');
    const db = path.join(appRoot, 'noticias.json');
    try {
      const fetch = await correrPaso('fetch.js', ['--out', notas, '--horas', '24']);
      anotar(`fetch exit=${fetch.code} ${fetch.salida.trim().split('\n').slice(-3).join(' | ')} ${fetch.errores.trim()}`);

      const run = await correrPaso('run.js', ['--feed', notas, '--db', db, '--push']);
      anotar(`run exit=${run.code} ${run.salida.trim().slice(-400)}`);

      let resumen = null;
      try {
        const parsed = JSON.parse(run.salida);
        resumen = {
          procesadas: parsed.resumen?.length ?? 0,
          nuevas: parsed.resumen?.filter((r) => r.estado === 'nueva').length ?? 0,
          descartadas: parsed.resumen?.filter((r) => r.estado === 'descartada').length ?? 0,
          guardadas: parsed.db?.total ?? 0,
        };
      } catch {
        resumen = { error: 'salida no legible' };
      }

      estado.resultado = resumen;
      estado.ultima = new Date().toISOString();
      estado.ejecuciones += 1;
      if (fetch.code !== 0 || run.code !== 0) estado.errores += 1;
      log.info('monitor de notas', { ...resumen, codigo: fetch.code || run.code });
    } catch (error) {
      estado.errores += 1;
      anotar(`ERROR ${error.message}`);
      log.error('monitor de notas falló', { error: error.message });
    } finally {
      estado.corriendo = false;
    }
  }

  function estadoActual() {
    let cola = '';
    try {
      const datos = fs.readFileSync(logFile, 'utf8');
      cola = datos.slice(-4000);
    } catch {
      cola = 'sin log todavía';
    }
    return { ...estado, log: cola };
  }

  return {
    arrancar() {
      // La primera pasada tarda medio minuto: deja terminar el arranque.
      primera = setTimeout(ciclo, 20_000);
      timer = setInterval(ciclo, intervalMs);
      primera.unref?.();
      timer.unref?.();
      anotar(`monitor arrancado (cada ${Math.round(intervalMs / 60000)} min)`);
    },
    detener() {
      if (primera) clearTimeout(primera);
      if (timer) clearInterval(timer);
    },
    correrAhora: ciclo,
    estado: estadoActual,
  };
}

module.exports = { crearMonitor };
