import {
  Inject,
  Injectable,
  Logger,
  type OnModuleDestroy,
  type OnModuleInit,
} from '@nestjs/common';

import { loadConfig } from '../../config';
import {
  STATEMENT_IMPORT_STORE,
  type StatementImportStore,
} from '../../ports';
import { StatementImportService } from './statement-import.service';

/**
 * Durable statement analysis worker.
 *
 * Every instance may run this loop. PostgreSQL claim uses SKIP LOCKED and a
 * stale lease, so a crashed instance leaves work for another instance without
 * requiring process-local state or a privileged database connection.
 */
@Injectable()
export class StatementImportWorker implements OnModuleInit, OnModuleDestroy {
  private static readonly INTERVAL_MS = 10_000;
  private readonly logger = new Logger(StatementImportWorker.name);
  private timer?: NodeJS.Timeout;
  private running = false;
  private stopped = false;

  constructor(
    @Inject(STATEMENT_IMPORT_STORE) private readonly imports: StatementImportStore,
    private readonly service: StatementImportService,
  ) {}

  onModuleInit(): void {
    if (!loadConfig().statementImportAsync || process.env.NODE_ENV === 'test' || process.env.VITEST) return;
    void this.runOnce();
    this.timer = setInterval(() => void this.runOnce(), StatementImportWorker.INTERVAL_MS);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    this.stopped = true;
    if (this.timer) clearInterval(this.timer);
  }

  /** Exposed for integration tests and dedicated worker invocations. */
  async runOnce(): Promise<number> {
    if (this.running || this.stopped) return 0;
    this.running = true;
    try {
      let claimed = 0;
      for (; claimed < 25 && !this.stopped; claimed += 1) {
        // Claim only when processing can start, avoiding leases expiring in OCR queues.
        const [job] = await this.imports.claim(1);
        if (!job) break;
        try {
          await this.service.processQueued(job);
        } catch {
          // processQueued is defensive and records parser failures itself. A
          // store or infrastructure failure is logged without source content;
          // the lease will expire and another worker can retry it.
          this.logger.warn(`Statement job ${job.id} was not completed; its lease permits retry.`);
        }
      }
      if (claimed === 25 && !this.stopped) setImmediate(() => void this.runOnce());
      return claimed;
    } catch {
      this.logger.warn('Statement queue claim failed; it will be retried.');
      return 0;
    } finally {
      this.running = false;
    }
  }
}

