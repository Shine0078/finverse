import type { CrashReportingConfig } from '../../config';
import { reportCrash } from './crash-reporter';

/** A fatal error must restart the process; a failed reporter cannot prevent it. */
export function installFatalErrorHandlers(config: CrashReportingConfig): void {
  let stopping = false;
  const fatal = (error: unknown, context: string): void => {
    if (stopping) return;
    stopping = true;
    process.stderr.write(JSON.stringify({ level: 'fatal', event: context, message: 'FINVERSE is stopping after a fatal error.' }) + '\n');
    const deadline = setTimeout(() => process.exit(1), 5_000);
    deadline.unref();
    void reportCrash(config, error, context).finally(() => process.exit(1));
  };
  process.once('uncaughtException', (error) => fatal(error, 'uncaughtException'));
  process.once('unhandledRejection', (error) => fatal(error, 'unhandledRejection'));
}
