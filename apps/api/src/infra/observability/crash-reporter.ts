import { Logger } from '@nestjs/common';

import type { CrashReportingConfig } from '../../config';

const logger = new Logger('CrashReporter');

const SECRET_PATTERN =
  /Bearer\s+[A-Za-z0-9._\-+=/]+|[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}|\b\d{6,}\b/gi;

export function redactCrashText(value: string, max = 400): string {
  const cleaned = value.replace(SECRET_PATTERN, '[redacted]');
  return cleaned.length > max ? cleaned.slice(0, max) : cleaned;
}

export async function reportCrash(
  config: CrashReportingConfig,
  error: unknown,
  context = 'uncaught',
): Promise<void> {
  if (!config.enabled || !config.dsn) return;

  const message = redactCrashText(
    error instanceof Error ? error.message : String(error),
  );
  const stack = error instanceof Error && error.stack ? redactCrashText(error.stack, 800) : undefined;

  try {
    const parsed = new URL(config.dsn);
    const projectId = parsed.pathname.replace(/^\//, '').split('/')[0];
    const publicKey = parsed.username;
    if (!projectId || !publicKey) return;

    const envelopeUrl = `${parsed.protocol}//${parsed.host}/api/${projectId}/store/?sentry_key=${encodeURIComponent(publicKey)}&sentry_version=7`;
    await fetch(envelopeUrl, {
      method: 'POST',
      signal: AbortSignal.timeout(3_000),
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        message,
        platform: 'node',
        logger: 'finverse',
        tags: { context },
        extra: stack ? { stack } : undefined,
      }),
    });
  } catch (sendError) {
    logger.warn('Crash report delivery failed.');
  }
}
