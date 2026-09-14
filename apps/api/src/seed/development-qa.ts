import type { INestApplicationContext } from '@nestjs/common';

import type { AppConfig } from '../config';
import {
  PASSWORD_HASHER,
  USER_STORE,
  type PasswordHasher,
  type UserStore,
} from '../ports/auth';
import { AuthService } from '../modules/auth/auth.service';
import { LedgerService } from '../modules/ledger/ledger.service';

/** Stable credentials for the local, disposable in-memory development server. */
export const DEVELOPMENT_QA_EMAIL = 'demo@finverse.local';
export const DEVELOPMENT_QA_PASSWORD = 'Finverse local testing 2026!';

/**
 * Recreate the same populated QA account whenever the in-memory server starts.
 *
 * The caller must pass the already-derived development-dashboard gate. Keeping
 * the condition explicit makes it impossible for a production or persistent
 * database deployment to acquire a known password by accident.
 */
export async function ensureDevelopmentQaAccount(
  app: INestApplicationContext,
  config: AppConfig,
  enabled: boolean,
): Promise<string | null> {
  if (!enabled || config.isProduction || config.store !== 'memory') return null;

  const users = app.get<UserStore>(USER_STORE);
  const existing = await users.findByEmail(DEVELOPMENT_QA_EMAIL);
  let userId: string;

  if (existing) {
    const hasher = app.get<PasswordHasher>(PASSWORD_HASHER);
    await users.updatePasswordHash(
      existing.id,
      await hasher.hash(DEVELOPMENT_QA_PASSWORD),
    );
    if (existing.status !== 'active') await users.setStatus(existing.id, 'active');
    userId = existing.id;
  } else {
    const legal = config.legal;
    const registered = await app.get(AuthService).register(
      DEVELOPMENT_QA_EMAIL,
      DEVELOPMENT_QA_PASSWORD,
      'FINVERSE Demo',
      {
        acceptedTerms: legal.registrationRequired,
        termsVersion: legal.terms?.version ?? null,
        acceptedPrivacyNotice: legal.registrationRequired,
        privacyVersion: legal.privacyNotice?.version ?? null,
      },
      { ipAddress: null, userAgent: 'FINVERSE local QA seed' },
    );
    userId = registered.user.id;
  }

  await users.markEmailVerified(userId, new Date());
  await app.get(LedgerService).sync(userId);
  return userId;
}
