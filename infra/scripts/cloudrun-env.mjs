import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// Accept the documented flat YAML string map or JSON. Reject nesting,
// duplicate keys and YAML aliases so owner credentials cannot hide in either.
export function parseEnv(text) {
  if (text.trimStart().startsWith('{')) {
    const value = JSON.parse(text);
    if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error('Expected an environment map.');
    if (Object.values(value).some((item) => typeof item !== 'string')) throw new Error('Environment values must be strings.');
    return value;
  }
  const result = Object.create(null);
  for (const [index, line] of text.split(/\r?\n/).entries()) {
    if (!line.trim() || line.trimStart().startsWith('#')) continue;
    const match = /^([A-Z][A-Z0-9_]*):[ \t]*(.*)$/.exec(line);
    if (!match || Object.hasOwn(result, match[1])) throw new Error('Invalid or duplicate environment key on line ' + (index + 1));
    const raw = match[2].trim();
    let value;
    if (raw.startsWith('"')) {
      try { value = JSON.parse(raw); } catch { throw new Error('Invalid quoted value on line ' + (index + 1)); }
    } else if (raw.startsWith("'") && raw.endsWith("'")) {
      value = raw.slice(1, -1).replace(/''/g, "'");
    } else if (/^[A-Za-z0-9_./:@?=&%+,\-]+$/.test(raw)) {
      value = raw;
    } else {
      throw new Error('Use a quoted string value on line ' + (index + 1));
    }
    if (typeof value !== 'string' || /[\r\n]/.test(value)) throw new Error('Environment values must be single-line strings.');
    result[match[1]] = value;
  }
  return result;
}

export function prepareEnv(env, sha) {
  if (!/^[0-9a-f]{40}$/.test(sha)) throw new Error('An exact commit SHA is required.');
  const requireKeys = (keys) => {
    for (const key of keys) {
      if (!env[key]?.trim() || /REPLACE_|replace-me|placeholder\.invalid/.test(env[key])) {
        throw new Error(key + ' must be configured before deployment.');
      }
    }
  };
  requireKeys(['DATABASE_URL', 'DATABASE_APP_URL', 'JWT_SECRET', 'MFA_ENCRYPTION_KEY',
    'STATEMENT_IMPORT_ENCRYPTION_KEY', 'CORS_ORIGINS', 'SMTP_HOST', 'SMTP_USER',
    'SMTP_PASSWORD', 'EMAIL_FROM', 'LEGAL_TERMS_VERSION', 'LEGAL_TERMS_URL',
    'LEGAL_PRIVACY_VERSION', 'LEGAL_PRIVACY_URL']);
  if (env.NODE_ENV !== 'production' || env.STORE !== 'postgres' || env.MIGRATE_ON_BOOT !== 'false') {
    throw new Error('Deployment requires production, PostgreSQL, and migrations disabled on boot.');
  }
  let owner, app;
  try { owner = new URL(env.DATABASE_URL); app = new URL(env.DATABASE_APP_URL); }
  catch { throw new Error('Invalid database URL.'); }
  if (!['postgres:', 'postgresql:'].includes(owner.protocol) || !['postgres:', 'postgresql:'].includes(app.protocol) ||
      !owner.username || !app.username || decodeURIComponent(owner.username) === decodeURIComponent(app.username)) {
    throw new Error('Database owner and runtime must be distinct PostgreSQL roles.');
  }
  if (owner.hostname !== app.hostname || owner.pathname !== app.pathname || owner.port !== app.port) {
    throw new Error('Owner and runtime URLs must address the same direct database.');
  }
  const banking = Boolean(env.PLAID_CLIENT_ID || env.PLAID_SECRET);
  if (banking) {
    requireKeys(['PLAID_CLIENT_ID','PLAID_SECRET','PLAID_ENVIRONMENT','PLAID_COUNTRIES',
      'PLAID_WEBHOOK_URL','PLAID_WEB_REDIRECT_URI','BANK_TOKEN_ENCRYPTION_KEY']);
    if (env.PLAID_ENVIRONMENT !== 'production') throw new Error('Live banking requires Plaid production credentials.');
  }
  const runtime = { ...env, GIT_SHA: sha, STATEMENT_IMPORT_ASYNC: 'true' };
  delete runtime.DATABASE_URL;
  const migration = { DATABASE_URL: env.DATABASE_URL, DATABASE_APP_URL: env.DATABASE_APP_URL };
  return { runtime, migration, banking };
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    const [input, sha, runtimePath, migrationPath] = process.argv.slice(2);
    if (!input || !runtimePath || !migrationPath) throw new Error('Expected input, SHA, runtime output, and migration output.');
    const prepared = prepareEnv(parseEnv(readFileSync(input, 'utf8')), sha);
    for (const [path, values] of [[runtimePath, prepared.runtime], [migrationPath, prepared.migration]]) {
      writeFileSync(path, JSON.stringify(values), { mode: 0o600, flag: 'wx' });
    }
    console.log(prepared.banking ? 'Bank integration configured; verify live provider access after deploy.' : 'Manual finance mode; bank linking remains unavailable.');
  } catch (error) {
    console.error(error instanceof SyntaxError ? 'Invalid environment JSON.' : error.message);
    process.exitCode = 1;
  }
}
