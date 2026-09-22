import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, statSync } from 'node:fs';
const tracked = execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
const additions = execFileSync('git', ['ls-files', '--others', '--exclude-standard', '-z'], { encoding: 'utf8' })
  .split('\0').filter(p => /^(apps\/api\/(src|test|scripts)\/|apps\/mobile\/(lib|test)\/|infra\/scripts\/)/.test(p));
const rules = {
  dynamic_execution: /\beval\s*\(|new\s+Function\s*\(/,
  disabled_tls_verification: /rejectUnauthorized\s*:\s*false|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*['"]?0/,
  html_injection_boundary: /innerHTML|dangerouslySetInnerHTML|document\.write/,
  raw_error_logging: /(?:logger\.(?:error|warn)|console\.(?:error|log))\(.*(?:error|err)\b/,
  currency_scale_boundary: /(?:\/|\*)\s*100\b/,
  unfinished_marker: /\bTODO\b|\bFIXME\b|\bHACK\b/,
  private_key_marker: /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  possible_cloud_key: /\bAKIA[A-Z0-9]{16}\b|\bghp_[a-zA-Z0-9]{30,}/,
  sql_interpolation_boundary: /\$\{/,
};
const files = [];
for (const path of [...new Set([...tracked, ...additions])].sort()) {
  if (path === 'docs/daily-use-review-coverage.json') continue;
  const size = statSync(path).size;
  if (/\.(?:tgz|gz|zip|png|jpg|jpeg|webp|ico|pdf|ttf|woff2?|keystore|jks)$/i.test(path) || size > 5_000_000) {
    files.push({ path, bytes: size, method: 'not-text-reviewed', reason: 'binary, archive, or oversized artifact' });
    continue;
  }
  const buffer = readFileSync(path);
  if (buffer.includes(0)) {
    files.push({ path, bytes: size, method: 'not-text-reviewed', reason: 'binary or non-UTF8 text' });
    continue;
  }
  const text = buffer.toString('utf8');
  const hits = [];
  text.split(/\r?\n/).forEach((line, index) => {
    for (const [rule, pattern] of Object.entries(rules)) {
      if (pattern.test(line) && (rule !== 'sql_interpolation_boundary' || /query|SELECT|WHERE|VALUES|SET |INSERT|UPDATE/.test(line))) {
        hits.push({ line: index + 1, rule });
      }
    }
  });
  files.push({ path, bytes: size, sha256: createHash('sha256').update(buffer).digest('hex'),
    lines: text.split(/\r?\n/).length, method: 'automated-text-scan', hits });
}
writeFileSync('docs/daily-use-review-coverage.json', JSON.stringify({
  generatedAt: new Date().toISOString(),
  scope: 'Tracked repository files and new application changes. Automated scanning is not a line-by-line manual security review. Match locations are leads, not confirmed vulnerabilities. No matched secret values are recorded.',
  files,
}, null, 2) + '\n');
console.log(JSON.stringify({
  files: files.length, scanned: files.filter(f => f.method === 'automated-text-scan').length,
  uninspected: files.filter(f => f.method !== 'automated-text-scan').map(f => f.path),
  productionLeads: files.filter(f => /apps\/api\/src|apps\/mobile\/lib|infra\/scripts/.test(f.path) && f.hits?.length)
    .map(f => ({ path: f.path, hits: f.hits.filter(h => !['sql_interpolation_boundary', 'currency_scale_boundary'].includes(h.rule)) }))
    .filter(f => f.hits.length),
}, null, 2));
