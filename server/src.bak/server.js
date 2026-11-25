'use strict';

const { createRuntime } = require('./app');

async function main() {
  const rt = createRuntime();
  await rt.start();

  const shutdown = async (signal) => {
    rt.log.info('shutdown requested', { signal });
    try {
      await rt.close();
      process.exit(0);
    } catch (err) {
      rt.log.error('shutdown error', { err: err.message });
      process.exit(1);
    }
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('unhandledRejection', (err) => {
    rt.log.error('unhandledRejection', { err: String((err && err.stack) || err) });
  });
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
