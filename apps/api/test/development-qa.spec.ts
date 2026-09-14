import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

process.env.STORE = 'memory';
process.env.JWT_SECRET ??= 'test-secret-at-least-32-characters-long-for-hs256';

describe('local development QA account', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const { AppModule } = await import('../src/app.module');
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = moduleRef.createNestApplication();
    await app.init();
  });

  afterAll(async () => app?.close());

  it('is recreated with stable credentials and deterministic data', async () => {
    const { loadConfig } = await import('../src/config');
    const {
      DEVELOPMENT_QA_EMAIL,
      DEVELOPMENT_QA_PASSWORD,
      ensureDevelopmentQaAccount,
    } = await import('../src/seed/development-qa');
    const { AuthService } = await import('../src/modules/auth/auth.service');
    const { LedgerService } = await import('../src/modules/ledger/ledger.service');

    const first = await ensureDevelopmentQaAccount(app, loadConfig(), true);
    const second = await ensureDevelopmentQaAccount(app, loadConfig(), true);
    expect(second).toBe(first);

    const login = await app.get(AuthService).login(
      DEVELOPMENT_QA_EMAIL,
      DEVELOPMENT_QA_PASSWORD,
      { ipAddress: '127.0.0.1', userAgent: 'qa-test' },
    );
    expect('tokens' in login).toBe(true);
    expect(await app.get(LedgerService).listAccounts(first!)).not.toHaveLength(0);
  });

  it('stays disabled when the development gate is off', async () => {
    const { loadConfig } = await import('../src/config');
    const { ensureDevelopmentQaAccount } = await import('../src/seed/development-qa');
    expect(await ensureDevelopmentQaAccount(app, loadConfig(), false)).toBeNull();
  });
});
