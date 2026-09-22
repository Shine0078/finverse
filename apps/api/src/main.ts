// First, and it has to be: loadConfig() is memoised and runs when the module
// graph below is initialised, so a .env read any later would be ignored.
import './env';
import 'reflect-metadata';

import { Logger, RequestMethod, ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import compression from 'compression';
import type { NextFunction, Request, Response } from 'express';
import { existsSync, readFileSync } from 'node:fs';
import { extname, join } from 'node:path';

import { AppModule } from './app.module';
import { loadConfig, shouldServeDevelopmentDashboard } from './config';
import { installHttpControls } from './infra/http/controls';
import { checkWebBundleBaseHref } from './infra/http/web-bundle';
import { assertRestrictedRuntimeRole, parseAppRole, provisionAppRole } from './infra/postgres/app-role';
import { closePool, getAppPool, getPool } from './infra/postgres/pool';
import { runMigrations } from './infra/postgres/migrate';
import { installFatalErrorHandlers } from './infra/observability/fatal-errors';
import {
  DEVELOPMENT_QA_EMAIL,
  ensureDevelopmentQaAccount,
} from './seed/development-qa';

const config = loadConfig();
const PORT = config.port;

async function bootstrap(): Promise<void> {
  const logger = new Logger('bootstrap');
  const developmentDashboard = shouldServeDevelopmentDashboard(config);

  // Migrations run before the app starts so that no request can ever hit a
  // half-migrated schema. In production this belongs in the deploy pipeline —
  // set MIGRATE_ON_BOOT=false there, since two instances starting together
  // would otherwise race.
  if (config.store === 'postgres' && config.migrateOnBoot) {
    const admin = getPool(config.databaseUrl);
    const applied = await runMigrations(admin);
    logger.log(
      applied.length === 0 ? 'Schema up to date.' : `Applied migrations: ${applied.join(', ')}`,
    );

    // After the migrations, because the grants cover the tables they create.
    if (config.appDatabaseUrl) {
      await provisionAppRole(admin, config.appDatabaseUrl);
      logger.log(`Runtime role ${parseAppRole(config.appDatabaseUrl).role} provisioned.`);
    }
  }

  if (config.isProduction && config.store === 'postgres') {
    const runtime = getAppPool(config.appDatabaseUrl);
    const role = await assertRestrictedRuntimeRole(runtime);
    logger.log(`Runtime role ${role} is restricted and subject to RLS.`);
  }

  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    logger: ['log', 'warn', 'error'],
    rawBody: true,
  });

  // Statement uploads are base64-wrapped JSON so the mobile/web client uses one
  // authenticated path across platforms. Keep the parser bounded; the service
  // applies the stricter decoded 10 MB limit before any processing.
  app.useBodyParser('json', { limit: '14mb' });

  installHttpControls(app, config);
  app.setGlobalPrefix('api', {
    exclude: [
      'healthz',
      { path: '.well-known/apple-app-site-association', method: RequestMethod.GET },
      { path: 'apple-app-site-association', method: RequestMethod.GET },
      { path: '.well-known/assetlinks.json', method: RequestMethod.GET },
    ],
  });
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));

  const qaUserId = await ensureDevelopmentQaAccount(
    app,
    config,
    developmentDashboard,
  );
  if (qaUserId) logger.log(`Local QA account ready: ${DEVELOPMENT_QA_EMAIL}`);

  // Development may allow all origins; production configuration fails closed
  // unless CORS_ORIGINS contains an explicit allowlist.
  app.enableCors({ origin: config.corsOrigins, credentials: true });

  // The compiled Flutter app is several megabytes of JavaScript and a
  // WebAssembly renderer, and served raw that is a blank screen for tens of
  // seconds on a phone — indistinguishable from a crash. Compression cuts it
  // by roughly four times.
  //
  // Scoped to the static bundle rather than applied globally: compressing API
  // responses that mix secrets with attacker-influenced content is the setup
  // for BREACH, and the bundle is where all the bytes actually are.
  app.use(['/app', '/dev'], compression());

  // The developer dashboard is mounted only for the in-memory development
  // adapter. It fabricates a sample ledger from the mock aggregator, so a
  // persistent deployment must never expose it just because NODE_ENV was
  // omitted or mistyped.
  if (developmentDashboard) {
    app.useStaticAssets(join(__dirname, '..', 'public'), { prefix: '/dev' });
  }

  // The Flutter app, compiled for the web, served from the same origin as the
  // API it talks to. Same-origin means no CORS to configure and no second host
  // to run, and it is what makes the phone-installable PWA a single URL.
  //
  // Optional by design: the directory only exists after `flutter build web`,
  // and the API must still boot without it. See docs/11-run-on-your-phone.md.
  const webAppDir =
    process.env.WEB_APP_DIR?.trim() ||
    join(__dirname, '..', '..', 'mobile', 'build', 'web');
  const webAppBuilt = existsSync(join(webAppDir, 'index.html'));

  if (webAppBuilt) {
    // A bundle built for a different base path serves 200s for index.html and
    // 404s for every asset it then asks for, so the page renders nothing at all
    // and the server still looks healthy. See web-bundle.ts for why this check
    // exists and why it warns rather than refusing to boot.
    const bundle = checkWebBundleBaseHref(
      readFileSync(join(webAppDir, 'index.html'), 'utf8'),
      '/app/',
    );
    if (!bundle.ok) logger.error(bundle.reason);

    // A changing financial web bundle must be revalidated before use, but the
    // multi-megabyte renderer may still be conditionally reused when unchanged.
    // `web/flutter_service_worker.js` is a migration-only worker for clients
    // on an older Flutter bootstrap: it clears its own caches and unregisters.
    // New builds never register a service worker.
    app.use('/app', (request: Request, response: Response, next: NextFunction) => {
      response.setHeader('cache-control', 'no-cache');
      next();
    });
    app.useStaticAssets(webAppDir, { prefix: '/app' });

    // Flutter routes client-side, so a deep link or a hard refresh inside the
    // app asks the server for a path that does not exist on disk. Hand those
    // back index.html and let the app resolve them.
    app.use('/app', (request: Request, response: Response, next: NextFunction) => {
      if (request.method !== 'GET' || extname(request.path)) return next();
      response.sendFile(join(webAppDir, 'index.html'));
    });
  }

  // The root sends you to the real app when one is built. Only development
  // falls back to the mock-data dashboard; production fails closed if its
  // frontend bundle is missing.
  app.use((request: Request, response: Response, next: NextFunction) => {
    if (request.path !== '/') return next();
    if (webAppBuilt) return response.redirect('/app/');
    if (developmentDashboard) return response.redirect('/dev/');
    return response.status(404).send('FINVERSE web app is not deployed.');
  });

  // Drain in-flight requests and close the pool on SIGTERM/SIGINT, so a
  // restart doesn't sever open connections mid-transaction.
  app.enableShutdownHooks();
  const shutdown = async (): Promise<void> => {
    await app.close();
    await closePool();
  };
  process.once('SIGTERM', () => void shutdown());
  process.once('SIGINT', () => void shutdown());

  await app.listen(PORT, '0.0.0.0');

  logger.log(`FINVERSE API listening on http://localhost:${PORT}`);
  logger.log(`Store      ${config.store}`);
  logger.log(`Health     http://localhost:${PORT}/healthz`);
  if (developmentDashboard) {
    logger.log(`Dev tools  http://localhost:${PORT}/dev/  (sample data lives here)`);
  }
  if (webAppBuilt) {
    logger.log(`App        http://localhost:${PORT}/app/`);
  } else {
    logger.warn('No web build found — run `flutter build web` to serve the app at /app/.');
  }
}

installFatalErrorHandlers(config.crashReporting);

void bootstrap();
