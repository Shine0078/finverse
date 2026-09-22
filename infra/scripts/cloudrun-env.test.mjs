import test from 'node:test';
import assert from 'node:assert/strict';
import { parseEnv, prepareEnv } from './cloudrun-env.mjs';

const sha = 'a'.repeat(40);
const env = {
  NODE_ENV: 'production', STORE: 'postgres', MIGRATE_ON_BOOT: 'false',
  DATABASE_URL: 'postgresql://owner:test@db.invalid/finverse',
  DATABASE_APP_URL: 'postgresql://finverse_app:test@db.invalid/finverse',
  JWT_SECRET: 'test-only-value', MFA_ENCRYPTION_KEY: 'test-only-value',
  STATEMENT_IMPORT_ENCRYPTION_KEY: 'test-only-value', CORS_ORIGINS: 'https://app.invalid',
  SMTP_HOST: 'smtp.invalid', SMTP_USER: 'test', SMTP_PASSWORD: 'test',
  EMAIL_FROM: 'test@app.invalid', LEGAL_TERMS_VERSION: 'v1', LEGAL_TERMS_URL: 'https://app.invalid/terms',
  LEGAL_PRIVACY_VERSION: 'v1', LEGAL_PRIVACY_URL: 'https://app.invalid/privacy',
};
test('manual finance can deploy while bank linking stays disabled', () => {
  const prepared = prepareEnv(env, sha);
  assert.equal(prepared.banking, false);
  assert.equal(prepared.runtime.STATEMENT_IMPORT_ASYNC, 'true');
});
test('owner credentials never reach runtime and migration gets no unrelated secrets', () => {
  const prepared = prepareEnv({ ...env, GIT_SHA: 'old' }, sha);
  assert.equal(Object.hasOwn(prepared.runtime, 'DATABASE_URL'), false);
  assert.equal(prepared.runtime.GIT_SHA, sha);
  assert.deepEqual(Object.keys(prepared.migration).sort(), ['DATABASE_APP_URL', 'DATABASE_URL']);
});
test('rejects partial bank credentials and shared database roles', () => {
  assert.throws(() => prepareEnv({ ...env, PLAID_CLIENT_ID: 'test-id' }, sha), /PLAID_SECRET/);
  assert.throws(() => prepareEnv({ ...env, DATABASE_APP_URL: env.DATABASE_URL }, sha), /distinct/);
});
test('rejects indented owner keys, duplicate keys and multiline YAML', () => {
  for (const input of ['  DATABASE_URL: "private"', 'A: "one"\nA: "two"', 'A: |\n  private']) {
    assert.throws(() => parseEnv(input));
  }
});
test('parses documented quoted values without evaluating aliases or comments', () => {
  assert.deepEqual({ ...parseEnv('# comment\nA: "true"\nB: \'can\'\'t\'\nC: 587') }, { A: 'true', B: "can't", C: '587' });
  assert.throws(() => parseEnv('A: &secret private\nB: *secret'));
});
test('rejects unsafe JSON value types and placeholders before cloud mutation', () => {
  assert.throws(() => parseEnv('{"A":true}'));
  assert.throws(() => prepareEnv({ ...env, SMTP_PASSWORD: 'REPLACE_WITH_SECRET' }, sha), /SMTP_PASSWORD/);
  assert.throws(() => prepareEnv({ ...env, DATABASE_APP_URL: 'postgresql://app:test@other.invalid/finverse' }, sha), /same direct database/);
});
