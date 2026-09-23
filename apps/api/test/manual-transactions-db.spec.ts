import { ValidationPipe, type INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appUrlFrom, OWNER_URL, startPgHarness, type PgHarness } from './pg-harness';
import { closePool } from '../src/infra/postgres/pool';

if (!OWNER_URL) {
  describe('manual transactions on PostgreSQL', () => {
    it.skip('needs TEST_DATABASE_URL — run `npm run test:db`', () => {});
  });
} else {
  const ownerUrl = OWNER_URL;
  describe('manual transactions on PostgreSQL', () => {
    let harness: PgHarness, app: INestApplication, http: string;
    let token: string, otherToken: string, accountId: string;
    const users: string[] = [];
    const email = 'manual-' + randomUUID() + '@example.com';
    const password = 'correct horse battery staple';
    const savedRequestId = randomUUID();
    const body = (overrides: Record<string, unknown> = {}) => ({
      requestId: randomUUID(), accountId, postedAt: '2026-01-05',
      description: 'Weekly groceries', categorySlug: 'groceries', amount: -1234, ...overrides,
    });
    const save = (data: Record<string, unknown>, auth = token) =>
      request(http).post('/api/transactions/manual').set('Authorization', 'Bearer ' + auth).send(data);
    async function boot() {
      const { AppModule } = await import('../src/app.module');
      const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
      app = moduleRef.createNestApplication();
      app.setGlobalPrefix('api', { exclude: ['healthz'] });
      app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));
      await app.init(); await app.listen(0);
      http = (await app.getUrl()).replace('[::1]', '127.0.0.1');
    }
    beforeAll(async () => {
      harness = await startPgHarness(ownerUrl);
      Object.assign(process.env, { STORE: 'postgres', DATABASE_URL: ownerUrl,
        DATABASE_APP_URL: appUrlFrom(ownerUrl), MIGRATE_ON_BOOT: 'false', NODE_ENV: 'test',
        JWT_SECRET: 'manual-regression-secret-at-least-32-characters', THROTTLE_DISABLED: 'true' });
      await boot();
      for (const address of [email, 'other-' + email]) {
        const response = await request(http).post('/api/auth/register').send({ email: address, password }).expect(201);
        users.push(response.body.user.id);
        if (address === email) token = response.body.tokens.accessToken;
        else otherToken = response.body.tokens.accessToken;
      }
      const account = await request(http).post('/api/accounts/manual').set('Authorization', 'Bearer ' + token)
        .send({ name: 'Cash CAD', type: 'cash', currency: 'CAD', balanceCurrent: 10000 }).expect(201);
      accountId = account.body.id;
    });
    afterAll(async () => {
      await app?.close();
      if (harness) { for (const id of users) await harness.owner.query('DELETE FROM users WHERE id=$1', [id]); await harness.close(); }
      await closePool();
    });
    it('requires authentication and rejects access to another user account', async () => {
      await request(http).post('/api/transactions/manual').send(body()).expect(401);
      await save(body(), otherToken).expect(404);
    });
    it('persists exactly one expense across simultaneous retries', async () => {
      const payload = body({ requestId: savedRequestId });
      const replies = await Promise.all(Array.from({ length: 8 }, () => save(payload).expect(201)));
      expect(new Set(replies.map(r => r.body.id)).size).toBe(1);
      expect(replies[0]!.body).toMatchObject({ amount: -1234, currency: 'CAD', categorySource: 'user_manual' });
      const rows = await harness.owner.query('SELECT amount FROM transactions WHERE user_id=$1', [users[0]]);
      expect(rows.rows).toHaveLength(1);
      await save(body({ requestId: savedRequestId, amount: -9999 })).expect(409);
      expect((await harness.owner.query('SELECT amount FROM transactions WHERE user_id=$1', [users[0]])).rows[0].amount).toBe(-1234);
    });
    it('rejects malformed dates, unsafe amounts, wrong categories, and future payments', async () => {
      for (const patch of [
        { postedAt: '2026-02-30' }, { postedAt: '2099-01-01' }, { amount: 1.2 },
        { amount: Number.MAX_SAFE_INTEGER + 1 }, { amount: 0 }, { description: {} },
        { categorySlug: 'missing' }, { categorySlug: 'groceries', amount: 1000 },
      ]) await save(body(patch)).expect(400);
      expect((await harness.owner.query('SELECT id FROM transactions WHERE user_id=$1', [users[0]])).rows).toHaveLength(1);
    });
    it('records income and produces exact financial summaries', async () => {
      await save(body({ amount: 50000, categorySlug: 'salary', description: 'January salary' })).expect(201);
      const analytics = await request(http).get('/api/analytics?period=custom&from=2026-01-05&to=2026-01-05&currency=CAD')
        .set('Authorization', 'Bearer ' + token).expect(200);
      expect(analytics.body).toMatchObject({ totalIncome: 50000, grossExpenses: 1234, savings: 48766 });
    });
    it('survives an application restart and a fresh sign-in', async () => {
      await app.close(); await boot();
      const login = await request(http).post('/api/auth/login').send({ email, password }).expect(200);
      token = login.body.tokens.accessToken;
      const ledger = await request(http).get('/api/transactions').set('Authorization', 'Bearer ' + token).expect(200);
      expect(ledger.body.transactions).toHaveLength(2);
      const search = await request(http).get('/api/transactions?search=groceries').set('Authorization', 'Bearer ' + token).expect(200);
      expect(search.body.transactions).toHaveLength(1);
      expect(search.body.transactions[0].amount).toBe(-1234);
      const other = await request(http).get('/api/transactions').set('Authorization', 'Bearer ' + otherToken).expect(200);
      expect(other.body.transactions).toHaveLength(0);
    });
  });
}
