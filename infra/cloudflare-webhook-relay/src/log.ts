type LogLevel = "info" | "warn" | "error";

interface LogEntry {
  level: LogLevel;
  msg: string;
  ts: string;
  [key: string]: unknown;
}

function emit(level: LogLevel, msg: string, ctx: Record<string, unknown> = {}): void {
  const entry: LogEntry = { level, msg, ts: new Date().toISOString(), ...ctx };
  const s = JSON.stringify(entry);
  if (level === "error") {
    console.error(s);
  } else if (level === "warn") {
    console.warn(s);
  } else {
    console.log(s);
  }
}

export const log = {
  info: (msg: string, ctx?: Record<string, unknown>) => emit("info", msg, ctx),
  warn: (msg: string, ctx?: Record<string, unknown>) => emit("warn", msg, ctx),
  error: (msg: string, ctx?: Record<string, unknown>) => emit("error", msg, ctx),
};
