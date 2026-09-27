export type LogLevel = "debug" | "info" | "warn" | "error" | "silent";
const ORDER: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40, silent: 99 };

export interface Logger {
  debug(msg: string, data?: unknown): void;
  info(msg: string, data?: unknown): void;
  warn(msg: string, data?: unknown): void;
  error(msg: string, data?: unknown): void;
  child(scope: string): Logger;
}

let globalLevel: LogLevel = "info";
export function setLogLevel(level: LogLevel): void {
  globalLevel = level;
}

/** Minimal scoped logger. Never called per-chunk on hot paths. */
export function createLogger(scope: string): Logger {
  const emit = (level: Exclude<LogLevel, "silent">, msg: string, data?: unknown) => {
    if (ORDER[level] < ORDER[globalLevel]) return;
    const line = `[${new Date().toISOString().slice(11, 23)}] ${level.toUpperCase().padEnd(5)} ${scope}: ${msg}`;
    const fn = level === "error" ? console.error : level === "warn" ? console.warn : console.log;
    if (data === undefined) fn(line);
    else fn(line, data);
  };
  return {
    debug: (m, d) => emit("debug", m, d),
    info: (m, d) => emit("info", m, d),
    warn: (m, d) => emit("warn", m, d),
    error: (m, d) => emit("error", m, d),
    child: (s) => createLogger(`${scope}:${s}`),
  };
}
