#!/usr/bin/env node
'use strict';

/**
 * Despliega el backend sin cable: empaqueta `server/` y lo manda a
 * `POST /api/admin/deploy`. El servidor valida el tarball (sha256 + sintaxis),
 * deja el sello y el servicio vigilante de Termux aplica y reinicia; si el
 * backend no arranca, ese vigilante restaura `app/src.bak` solo.
 *
 * Uso:
 *   node tools/deploy-remote.js [--url https://...] [--token XXX] [--skip-tests]
 *
 * Variables: OPENTERITORIO_TOKEN, OPENTERITORIO_URL.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..');

// bsdtar de Windows en lugar del GNU de git-bash (que confunde "C:" con un host).
const TAR = process.platform === 'win32' && fs.existsSync('C:/Windows/System32/tar.exe')
  ? 'C:/Windows/System32/tar.exe'
  : 'tar';

function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index > -1 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const base = arg('url', process.env.OPENTERITORIO_URL || 'https://tienda.tlalchichi.xyz').replace(/\/+$/, '');
const token = arg('token', process.env.OPENTERITORIO_TOKEN || '');
const skipTests = process.argv.includes('--skip-tests');

function die(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

function sh(cmd, args, opts = {}) {
  const out = spawnSync(cmd, args, { encoding: 'utf8', ...opts });
  if (out.status !== 0) {
    die(`${cmd} falló: ${(out.stderr || out.stdout || '').slice(0, 400)}`);
  }
  return out.stdout || '';
}

async function main() {
  if (!token) die('falta el token (OPENTERITORIO_TOKEN o --token)');

  if (!skipTests) {
    console.log('pruebas del servidor…');
    sh('npm', ['test'], { cwd: path.join(ROOT, 'server'), shell: process.platform === 'win32' });
  }

  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'ot-stage-'));
  const app = path.join(stage, 'app');
  fs.mkdirSync(app, { recursive: true });

  // Solo lo que cambia: código, estáticos, manifiesto y el vigilante.
  // node_modules se queda como está en el teléfono (si cambian dependencias,
  // hay que desplegar una vez con cable).
  for (const item of ['src', 'public']) {
    const from = path.join(ROOT, 'server', item);
    if (fs.existsSync(from)) fs.cpSync(from, path.join(app, item), { recursive: true });
  }
  fs.copyFileSync(path.join(ROOT, 'server', 'package.json'), path.join(app, 'package.json'));

  // Monitor de notas: solo el código (la cookie y la base se quedan fuera).
  const noticiasSrc = path.join(ROOT, 'tools', 'noticias');
  if (fs.existsSync(noticiasSrc)) {
    const destino = path.join(app, 'noticias');
    fs.mkdirSync(destino, { recursive: true });
    for (const archivo of fs.readdirSync(noticiasSrc)) {
      if (!archivo.endsWith('.js')) continue;
      fs.copyFileSync(path.join(noticiasSrc, archivo), path.join(destino, archivo));
    }
  }
  const watch = path.join(ROOT, 'termux', 'watch.sh');
  if (fs.existsSync(watch)) {
    fs.mkdirSync(path.join(stage, 'termux'), { recursive: true });
    fs.copyFileSync(watch, path.join(stage, 'termux', 'watch.sh'));
  }
  // Gacetero del INEGI para ubicar las notas en el teléfono (0.07 MB).
  const gacetero = path.join(ROOT, 'app', 'assets', 'vector', 'localidades.json.gz');
  if (fs.existsSync(gacetero)) {
    fs.mkdirSync(path.join(app, 'assets', 'vector'), { recursive: true });
    fs.copyFileSync(gacetero, path.join(app, 'assets', 'vector', 'localidades.json.gz'));
  }

  // Servicios de runit (el vigilante los instala al aplicar el despliegue).
  const servicios = path.join(ROOT, 'termux', 'service');
  if (fs.existsSync(servicios)) {
    fs.cpSync(servicios, path.join(stage, 'termux', 'service'), { recursive: true });
  }

  const tarball = path.join(stage, 'openterritorio.tar.gz');
  sh(TAR, ['-czf', tarball, '-C', stage, '.']);
  const data = fs.readFileSync(tarball);
  const sha256 = crypto.createHash('sha256').update(data).digest('hex');

  const gitHash = (() => {
    const r = spawnSync('git', ['-C', ROOT, 'rev-parse', '--short', 'HEAD'], { encoding: 'utf8' });
    return r.status === 0 ? r.stdout.trim() : 'nogit';
  })();
  const version = `${new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14)}-${gitHash}`;

  console.log(`tarball ${(data.length / 1024).toFixed(0)} KB  sha256=${sha256.slice(0, 16)}…  version=${version}`);

  const url = `${base}/api/admin/deploy?sha256=${sha256}&version=${encodeURIComponent(version)}`;
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + token,
      'Content-Type': 'application/gzip',
    },
    body: data,
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) die(`el servidor rechazó el despliegue: HTTP ${response.status} ${JSON.stringify(body)}`);
  console.log(`aceptado: ${body.mensaje || 'aplicando'}`);

  // Esperar a que el servicio reinicie con el código nuevo.
  const enviadoEn = Date.now();
  const deadline = enviadoEn + 150_000;
  let ultimo = '';
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 3000));
    try {
      const info = await fetch(`${base}/api/admin/version`, {
        headers: { Authorization: 'Bearer ' + token },
      }).then((r) => (r.ok ? r.json() : null));
      if (!info) {
        ultimo = 'sin respuesta (reiniciando)';
        continue;
      }
      // Vale cuando el proceso arrancó después del envío: así se confirma el
      // reinicio, no solo que el servidor aceptó el archivo.
      const arrancado = Date.parse(info.booted_at || 0);
      if (arrancado > enviadoEn && info.deployed === null) {
        console.log(`listo: el backend reinició con ${body.version} (pid ${info.pid}, ${info.uptime_s}s de vida)`);
        fs.rmSync(stage, { recursive: true, force: true });
        return;
      }
      if (info.deployed && info.deployed.stamp === body.stamp) {
        console.log(`listo: el backend corre con ${info.deployed.version} (pid ${info.pid}, ${info.uptime_s}s de vida)`);
        fs.rmSync(stage, { recursive: true, force: true });
        return;
      }
      ultimo = `vivo con ${info.deployed ? info.deployed.version : 'versión anterior'}`;
    } catch (error) {
      ultimo = `sin conexión: ${error.message}`;
    }
  }
  fs.rmSync(stage, { recursive: true, force: true });
  die(`no confirmó el despliegue en 2 min (último estado: ${ultimo}); revisa /api/admin/version`);
}

main().catch((error) => die(error && error.stack ? error.stack : String(error)));
