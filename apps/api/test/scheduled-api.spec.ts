/**
 * Scheduled obligations over real HTTP.
 *
 * The distinction under test throughout: a schedule is what the user committed
 * to, and must never be confused with what the subscription engine merely
 * detected, nor with a transaction that has actually happened.
 */

import { ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

process.env.STORE = 'memory';
process.env.JWT_SECRET ??= 'test-secret-at-least-32-characters-long-for-hs256';
process.env.THROTTLE_DISABLED = 'true';

const PASSWORD = 'correct horse battery staple';

interface Session {
  token: string;
  accountId: string;
}

describe('schedules API', () => {
  let app: INestApplication;
  let http: string;
  let today: string;

  beforeAll(async () => {
    const { AppModule } = await import('../src/app.module');
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();

    app = moduleRef.createNestApplication();
    app.setGlobalPrefix('api', { exclude: ['healthz'] });
    app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));
    await app.init();
    await app.listen(0);
    http = await app.getUrl().then((url) => url.replace('[::1]', '127.0.0.1'));
    today = new Date().toISOString().slice(0, 10);
  });

  afterAll(async () => {
    await app?.close();
  });

  let counter = 0;

  async function signedInUser(): Promise<Session> {
    counter += 1;
    const registered = await request(http)
      .post('/api/auth/register')
      .send({ email: `sch-${counter}-${Date.now()}@example.com`, password: PASSWORD })
      .expect(201);

    const token: string = registered.body.tokens.accessToken;
    await request(http).post('/api/sync').set('Authorization', `Bearer ${token}`).expect(201);

    const accounts = await request(http)
      .get('/api/accounts')
      .set('Authorization', `Bearer ${token}`)
      .expect(200);

    return { token, accountId: accounts.body[0].id };
  }

  const create = (user: Session, overrides: Record<string, unknown> = {}) =>
    request(http)
      .post('/api/schedules')
      .set('Authorization', `Bearer ${user.token}`)
      .send({
        accountId: user.accountId,
        name: 'Rent',
        amount: -218_000,
        categorySlug: 'rent',
        cadence: 'monthly',
        startDate: today,
        reminderDays: 3,
        ...overrides,
      });

  it('requires a token', async () => {
    await request(http).get('/api/schedules').expect(401);
    await request(http).get('/api/schedules/upcoming').expect(401);
  });

  describe('creating', () => {
    it('records a commitment and projects the next date', async () => {
      const user = await signedInUser();
      const created = await create(user).expect(201);

      expect(created.body.name).toBe('Rent');
      expect(created.body.nextDate).toBe(today);
      expect(created.body.amountFormatted).toBeTruthy();
      expect(created.body.archivedAt).toBeNull();
    });

    it('takes the currency from the account, not the request', async () => {
      // A schedule in a currency the account does not hold would corrupt every
      // committed-outflow total that sums them.
      const user = await signedInUser();
      const created = await create(user, { currency: 'JPY' }).expect(201);
      expect(created.body.currency).toBe('USD');
    });

    it('rejects a zero amount', async () => {
      const user = await signedInUser();
      await create(user, { amount: 0 }).expect(400);
    });

    it('rejects an unknown cadence and an unknown category', async () => {
      const user = await signedInUser();
      await create(user, { cadence: 'whenever' }).expect(400);
      await create(user, { categorySlug: 'not_a_category' }).expect(400);
    });

    it('rejects an end date before the start', async () => {
      const user = await signedInUser();
      await create(user, { startDate: '2026-06-01', endDate: '2026-05-01' }).expect(400);
    });

    it('reports every problem at once', async () => {
      const user = await signedInUser();
      const response = await create(user, { name: '', amount: 0, cadence: 'nope' }).expect(400);
      expect(response.body.problems.length).toBeGreaterThanOrEqual(3);
    });

    it('rejects an account the caller does not own', async () => {
      const user = await signedInUser();
      await request(http)
        .post('/api/schedules')
        .set('Authorization', `Bearer ${user.token}`)
        .send({
          accountId: 'acc_not_yours',
          name: 'Rent',
          amount: -1000,
          cadence: 'monthly',
          startDate: today,
        })
        .expect(404);
    });
  });

  describe('upcoming', () => {
    it('lists occurrences and the committed outflow', async () => {
      const user = await signedInUser();
      await create(user, { amount: -100_000, cadence: 'monthly' }).expect(201);

      const upcoming = await request(http)
        .get('/api/schedules/upcoming?days=90')
        .set('Authorization', `Bearer ${user.token}`)
        .expect(200);

      expect(upcoming.body.entries.length).toBeGreaterThanOrEqual(3);
      expect(upcoming.body.committedOutflow).toBeGreaterThan(0);
      expect(upcoming.body.committedOutflowFormatted).toBeTruthy();
    });

    it('excludes expected income from the committed outflow', async () => {
      // Counting salary as a commitment would understate the risk, not overstate it.
      const user = await signedInUser();
      await create(user, { amount: 500_000, categorySlug: 'salary' }).expect(201);

      const upcoming = await request(http)
        .get('/api/schedules/upcoming?days=90')
        .set('Authorization', `Bearer ${user.token}`)
        .expect(200);

      expect(upcoming.body.entries.length).toBeGreaterThan(0);
      expect(upcoming.body.committedOutflow).toBe(0);
    });

    it('rejects an out-of-range horizon', async () => {
      const user = await signedInUser();
      await request(http)
        .get('/api/schedules/upcoming?days=5000')
        .set('Authorization', `Bearer ${user.token}`)
        .expect(400);
    });

    it('returns entries in date order', async () => {
      const user = await signedInUser();
      await create(user, { name: 'Weekly', cadence: 'weekly', amount: -1_000 }).expect(201);
      await create(user, { name: 'Monthly', cadence: 'monthly', amount: -2_000 }).expect(201);

      const upcoming = await request(http)
        .get('/api/schedules/upcoming?days=60')
        .set('Authorization', `Bearer ${user.token}`)
        .expect(200);

      const dates = upcoming.body.entries.map((e: { date: string }) => e.date);
      expect([...dates].sort()).toEqual(dates);
    });
  });

  describe('updating and archiving', () => {
    it('validates the merged result, not just the patch', async () => {
      // A patch that looks fine alone can still produce an invalid schedule.
      const user = await signedInUser();
      const created = await create(user, { startDate: '2026-06-01' }).expect(201);

      await request(http)
        .patch(`/api/schedules/${created.body.id}`)
        .set('Authorization', `Bearer ${user.token}`)
        .send({ endDate: '2026-05-01' })
        .expect(400);
    });

    it('applies a valid patch', async () => {
      const user = await signedInUser();
      const created = await create(user).expect(201);

      const updated = await request(http)
        .patch(`/api/schedules/${created.body.id}`)
        .set('Authorization', `Bearer ${user.token}`)
        .send({ name: 'Rent (new landlord)', amount: -225_000 })
        .expect(200);

      expect(updated.body.name).toBe('Rent (new landlord)');
      expect(updated.body.amount).toBe(-225_000);
    });

    it('archives rather than deleting', async () => {
      const user = await signedInUser();
      const created = await create(user).expect(201);

      await request(http)
        .delete(`/api/schedules/${created.body.id}`)
        .set('Authorization', `Bearer ${user.token}`)
        .expect(204);

      const live = await request(http)
        .get('/api/schedules')
        .set('Authorization', `Bearer ${user.token}`)
        .expect(200);
      expect(live.body.count).toBe(0);

      const all = await request(http)
        .get('/api/schedules?includeArchived=true')
        .set('Authorization', `Bearer ${user.token}`)
        .expect(200);
      expect(all.body.count).toBe(1);
      expect(all.body.schedules[0].archivedAt).not.toBeNull();
    });

    it('will not archive twice', async () => {
      const user = await signedInUser();
      const created = await create(user).expect(201);

      await request(http)
        .delete(`/api/schedules/${created.body.id}`)
        .set('Authorization', `Bearer ${user.token}`)
        .expect(204);

      await request(http)
        .delete(`/api/schedules/${created.body.id}`)
        .set('Authorization', `Bearer ${user.token}`)
        .expect(404);
    });

    it('drops an archived schedule out of upcoming', async () => {
      const user = await signedInUser();
      const created = await create(user).expect(201);

      await request(http)
        .delete(`/api/schedules/${created.body.id}`)
        .set('Authorization', `Bearer ${user.token}`)
        .expect(204);

      const upcoming = await request(http)
        .get('/api/schedules/upcoming?days=90')
        .set('Authorization', `Bearer ${user.token}`)
        .expect(200);

      expect(upcoming.body.entries).toHaveLength(0);
      expect(upcoming.body.committedOutflow).toBe(0);
    });
  });

  describe('user isolation', () => {
    it('does not show one user schedules to another', async () => {
      const alice = await signedInUser();
      const bob = await signedInUser();
      await create(alice).expect(201);

      const theirs = await request(http)
        .get('/api/schedules')
        .set('Authorization', `Bearer ${bob.token}`)
        .expect(200);

      expect(theirs.body.count).toBe(0);
    });

    it('will not let one user patch or archive another schedule', async () => {
      const alice = await signedInUser();
      const bob = await signedInUser();
      const created = await create(alice).expect(201);

      await request(http)
        .patch(`/api/schedules/${created.body.id}`)
        .set('Authorization', `Bearer ${bob.token}`)
        .send({ name: 'Hijacked' })
        .expect(404);

      await request(http)
        .delete(`/api/schedules/${created.body.id}`)
        .set('Authorization', `Bearer ${bob.token}`)
        .expect(404);

      const mine = await request(http)
        .get('/api/schedules')
        .set('Authorization', `Bearer ${alice.token}`)
        .expect(200);

      expect(mine.body.schedules[0].name).toBe('Rent');
      expect(mine.body.schedules[0].archivedAt).toBeNull();
    });
  });

  it('does not create a transaction for a future obligation', async () => {
    // A commitment is not money that has moved. Writing it as a transaction
    // would put it into every balance, budget and total in the product.
    const user = await signedInUser();

    const before = await request(http)
      .get('/api/transactions?limit=1000')
      .set('Authorization', `Bearer ${user.token}`)
      .expect(200);

    await create(user).expect(201);

    const after = await request(http)
      .get('/api/transactions?limit=1000')
      .set('Authorization', `Bearer ${user.token}`)
      .expect(200);

    expect(after.body.count).toBe(before.body.count);
  });
  it('rejects changing a schedule to an account owned by another user', async () => {
    const alice = await signedInUser();
    const bob = await signedInUser();
    const bobAccount = await request(http).post('/api/accounts/manual')
      .set('Authorization', 'Bearer ' + bob.token)
      .send({ name: 'Private account', type: 'cash', currency: 'USD', balanceCurrent: 0 }).expect(201);
    expect(bobAccount.body.id).not.toBe(alice.accountId);
    const created = await create(alice).expect(201);
    await request(http).patch('/api/schedules/' + created.body.id)
      .set('Authorization', 'Bearer ' + alice.token)
      .send({ accountId: bobAccount.body.id }).expect(400);
    const listed = await request(http).get('/api/schedules')
      .set('Authorization', 'Bearer ' + alice.token).expect(200);
    expect(listed.body.schedules[0].accountId).toBe(alice.accountId);
  });

  it('rejects impossible dates and malformed names without writing a schedule', async () => {
    const user = await signedInUser();
    await create(user, { startDate: '2026-02-31' }).expect(400);
    await create(user, { name: 42 }).expect(400);
    const listed = await request(http).get('/api/schedules')
      .set('Authorization', 'Bearer ' + user.token).expect(200);
    expect(listed.body.count).toBe(0);
  });

  it('validates categories on updates and prevents archive-field injection', async () => {
    const user = await signedInUser();
    const created = await create(user).expect(201);
    await request(http).patch('/api/schedules/' + created.body.id)
      .set('Authorization', 'Bearer ' + user.token)
      .send({ categorySlug: 'nonexistent-category' }).expect(400);
    const updated = await request(http).patch('/api/schedules/' + created.body.id)
      .set('Authorization', 'Bearer ' + user.token)
      .send({ name: '  Updated rent  ', archivedAt: '2026-01-01' }).expect(200);
    expect(updated.body.name).toBe('Updated rent');
    expect(updated.body.archivedAt).toBeNull();
  });

  it('reports CAD commitments in CAD and separates mixed-currency totals', async () => {
    const user = await signedInUser();
    const account = await request(http).post('/api/accounts/manual')
      .set('Authorization', 'Bearer ' + user.token)
      .send({ name: 'CAD cash', type: 'cash', currency: 'CAD', balanceCurrent: 0 }).expect(201);
    await create(user, { accountId: account.body.id, amount: -1000 }).expect(201);
    const cad = await request(http).get('/api/schedules/upcoming?days=1')
      .set('Authorization', 'Bearer ' + user.token).expect(200);
    expect(cad.body.currency).toBe('CAD');
    expect(cad.body.committedOutflow).toBe(1000);
    await create(user, { amount: -2000 }).expect(201);
    const mixed = await request(http).get('/api/schedules/upcoming?days=1')
      .set('Authorization', 'Bearer ' + user.token).expect(200);
    expect(mixed.body.currency).toBeNull();
    expect(mixed.body.committedOutflow).toBeNull();
    expect(mixed.body.committedOutflowFormatted).toBeNull();
    expect(mixed.body.committedOutflowByCurrency).toEqual({ CAD: 1000, USD: 2000 });
  });

});
