import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, join, resolve } from 'node:path';
import { Pool } from 'pg';
import { runMigrations } from '../src/infra/postgres/migrate';

async function main(): Promise<void> {
  if (process.platform !== 'win32') throw new Error('This drill exercises the Windows backup scripts.');
  const source = process.env.TEST_DATABASE_URL;
  if (!source) throw new Error('Run through scripts/with-postgres.ts; a disposable TEST_DATABASE_URL is required.');
  const url = new URL(source);
  if (!['localhost', '127.0.0.1'].includes(url.hostname) || url.username !== 'finverse' || url.password !== 'finverse_dev_only') {
    throw new Error('Refusing to run the fixture drill outside the disposable local database.');
  }
  const utilities = process.env.FINVERSE_PG_BIN;
  const age = process.env.FINVERSE_AGE_BIN;
  if (!utilities || !age || !existsSync(join(utilities, 'pg_dump.exe')) || !existsSync(join(age, 'age.exe'))) {
    throw new Error('Set FINVERSE_PG_BIN and FINVERSE_AGE_BIN to installed client utilities.');
  }
  const temporary = mkdtempSync(join(tmpdir(), 'finverse-backup-drill-'));
  const owner = new Pool({ connectionString: source });
  const restoredUrl = new URL(source); restoredUrl.pathname = '/finverse_restore_test';
  const restored = new Pool({ connectionString: restoredUrl.toString() });
  const environment = { ...process.env, Path: utilities + delimiter + age + delimiter + (process.env.Path ?? process.env.PATH ?? '') };
  delete environment.PATH;
  function command(binary: string, args: string[]): string {
    const result = spawnSync(binary, args, { env: environment, encoding: 'utf8', timeout: 120000, windowsHide: true });
    if (result.error || result.status !== 0) throw new Error('Backup drill step failed: ' + binary + '\n' + result.stderr + result.stdout);
    return result.stdout.trim();
  }
  const powershell = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  try {
    await runMigrations(owner);
    await owner.query('CREATE DATABASE finverse_restore_test');
    await owner.query('CREATE TABLE backup_restore_probe (id text PRIMARY KEY, amount bigint NOT NULL, posted_at date NOT NULL)');
    await owner.query("INSERT INTO backup_restore_probe VALUES ('expense', -12345, '2026-02-28'), ('income', 250000, '2026-03-01')");
    const identity = join(temporary, 'test-identity.txt');
    command(join(age, 'age-keygen.exe'), ['-o', identity]);
    const recipient = command(join(age, 'age-keygen.exe'), ['-y', identity]);
    const archives = join(temporary, 'backups');
    command(powershell, ['-NoProfile', '-File', resolve('../../infra/scripts/backup-postgres.ps1'),
      '-DatabaseUrl', source, '-AgeRecipient', recipient, '-Destination', archives, '-AgeBinary', join(age, 'age.exe')]);
    const archive = readdirSync(archives).find(name => name.endsWith('.dump.age'));
    if (!archive || readdirSync(archives).some(name => name.endsWith('.dump'))) throw new Error('Encrypted backup missing or plaintext left behind.');
    if (!readFileSync(join(archives, archive)).subarray(0, 24).toString().startsWith('age-encryption.org/v1')) throw new Error('Backup is not encrypted.');
    command(powershell, ['-NoProfile', '-File', resolve('../../infra/scripts/restore-drill-postgres.ps1'),
      '-Archive', join(archives, archive), '-RestoreDatabaseUrl', restoredUrl.toString(),
      '-AgeIdentity', identity, '-AgeBinary', join(age, 'age.exe')]);
    const query = "SELECT id, amount::text, posted_at::text FROM backup_restore_probe ORDER BY id";
    const expected = (await owner.query(query)).rows;
    const actual = (await restored.query(query)).rows;
    if (JSON.stringify(expected) !== JSON.stringify(actual)) throw new Error('Restored monetary values or dates differ.');
    const migrations = (await owner.query('SELECT name FROM schema_migrations ORDER BY name')).rows;
    const restoredMigrations = (await restored.query('SELECT name FROM schema_migrations ORDER BY name')).rows;
    if (JSON.stringify(migrations) !== JSON.stringify(restoredMigrations)) throw new Error('Migration history differs after restore.');
    console.log(JSON.stringify({ encryptedBackup: true, restoredRows: actual.length, migrations: migrations.length,
      exactAmountsAndDates: true, sourceUnchanged: true, plaintextRemoved: true }));
  } finally {
    await restored.end(); await owner.end();
    rmSync(temporary, { recursive: true, force: true });
  }
}
void main().catch(error => { console.error(error instanceof Error ? error.message : 'Backup drill failed'); process.exitCode = 1; });
