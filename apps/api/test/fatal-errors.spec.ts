import { spawnSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';

describe('fatal process errors', () => {
  it.each(['throw new Error("private-financial-value")', 'Promise.reject(new Error("private-financial-value"))'])('exits nonzero even when reporting is disabled: %s', (failure) => {
    const result = spawnSync(process.execPath, ['-r', 'ts-node/register', '-e',
      'require("./src/infra/observability/fatal-errors").installFatalErrorHandlers({enabled:false,dsn:null}); setInterval(()=>{},1000); setTimeout(()=>{' + failure + '},0);'
    ], { encoding: 'utf8', timeout: 10_000 });
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('FINVERSE is stopping');
    expect(result.stderr).not.toContain('private-financial-value');
  });
});
