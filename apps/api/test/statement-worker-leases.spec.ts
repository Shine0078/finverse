import { Logger } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { StatementImportWorker } from '../src/modules/imports/statement-import.worker';
import type { StatementImportStore } from '../src/ports';
import type { StatementImportService } from '../src/modules/imports/statement-import.service';

describe('statement worker lease timing', () => {
  it('claims one job only when it can begin and prevents overlapping drains', async () => {
    let complete!: () => void;
    const held = new Promise<void>(resolve => { complete = resolve; });
    const claim = vi.fn().mockResolvedValueOnce([{ id: 'one' }]).mockResolvedValueOnce([{ id: 'two' }]).mockResolvedValue([]);
    const processQueued = vi.fn().mockReturnValueOnce(held).mockResolvedValue(undefined);
    const worker = new StatementImportWorker({ claim } as unknown as StatementImportStore, { processQueued } as unknown as StatementImportService);
    const run = worker.runOnce();
    await Promise.resolve();
    expect(claim).toHaveBeenCalledTimes(1);
    expect(claim).toHaveBeenCalledWith(1);
    expect(await worker.runOnce()).toBe(0);
    complete();
    expect(await run).toBe(2);
    expect(processQueued.mock.calls.map(c => c[0].id)).toEqual(['one', 'two']);
    worker.onModuleDestroy();
    expect(await worker.runOnce()).toBe(0);
    expect(claim).toHaveBeenCalledTimes(3);
  });
  it('does not put document or connection secrets from errors in logs', async () => {
    const warn = vi.spyOn(Logger.prototype, 'warn').mockImplementation(() => {});
    try {
      const claim = vi.fn().mockRejectedValue(new Error('PRIVATE_ACCOUNT_CONTENT'));
      const worker = new StatementImportWorker({ claim } as unknown as StatementImportStore, {} as StatementImportService);
      expect(await worker.runOnce()).toBe(0);
      expect(JSON.stringify(warn.mock.calls)).not.toContain('PRIVATE_ACCOUNT_CONTENT');
    } finally { warn.mockRestore(); }
  });
});
