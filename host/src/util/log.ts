const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 } as const;
type Level = keyof typeof LEVELS;
const min = LEVELS[(process.env.OPA_LOG as Level) ?? 'info'] ?? 20;

function out(level: Level, scope: string, args: unknown[]) {
  if (LEVELS[level] < min) return;
  const ts = new Date().toISOString().slice(11, 23);
  (level === 'error' || level === 'warn' ? console.error : console.log)(`${ts} ${level.padEnd(5)} [${scope}]`, ...args);
}

export const log = {
  debug: (scope: string, ...a: unknown[]) => out('debug', scope, a),
  info: (scope: string, ...a: unknown[]) => out('info', scope, a),
  warn: (scope: string, ...a: unknown[]) => out('warn', scope, a),
  error: (scope: string, ...a: unknown[]) => out('error', scope, a),
};

export const now = () => Date.now();
export const uid = (p = '') => p + crypto.randomUUID().replace(/-/g, '').slice(0, 16);
