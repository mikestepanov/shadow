import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { promisify } from "node:util";
import { enqueueLane } from "./queue.js";
import { safeRunCommand } from "./safe-command.js";
import { safeSendPrompt } from "./safe-send.js";
import { resolveRepoPath } from "./paths.js";

const execFileAsync = promisify(execFile);

const DEFAULT_CRON_PATH = resolveRepoPath("opencode", "var", "opencode-cron.json");
const LEGACY_CRON_PATH = resolveRepoPath("..", ".openclaw", "cron", "jobs.json");
const DEFAULT_TIMEZONE = "America/Chicago";
const SCHEDULE_LABELS = {
  60_000: "every 1m",
  120_000: "every 2m",
  180_000: "every 3m",
  300_000: "every 5m",
  600_000: "every 10m",
  900_000: "every 15m",
  1_200_000: "every 20m",
  1_800_000: "every 30m",
  3_600_000: "every 1h",
};
const WEEKDAY_INDEX = {
  sun: 0,
  mon: 1,
  tue: 2,
  wed: 3,
  thu: 4,
  fri: 5,
  sat: 6,
};
const CRON_FIELD_RANGES = [
  { min: 0, max: 59 },
  { min: 0, max: 23 },
  { min: 1, max: 31 },
  { min: 1, max: 12 },
  { min: 0, max: 6 },
];

function cronPath(options = {}) {
  return options.cronPath || process.env.OPENCODE_CRON_PATH || DEFAULT_CRON_PATH;
}

function nowMs() {
  return Date.now();
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function makeId() {
  return `job_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeState(state) {
  if (!isObject(state)) {
    return { lastStatus: "never", consecutiveErrors: 0 };
  }
  return {
    lastRunAtMs: typeof state.lastRunAtMs === "number" ? state.lastRunAtMs : undefined,
    lastRunStatus: typeof state.lastRunStatus === "string" ? state.lastRunStatus : undefined,
    lastStatus: typeof state.lastStatus === "string" ? state.lastStatus : "never",
    lastDurationMs: typeof state.lastDurationMs === "number" ? state.lastDurationMs : undefined,
    consecutiveErrors: typeof state.consecutiveErrors === "number" ? state.consecutiveErrors : 0,
    nextRunAtMs: typeof state.nextRunAtMs === "number" ? state.nextRunAtMs : undefined,
    lastError: typeof state.lastError === "string" ? state.lastError : undefined,
    lastErrorReason: typeof state.lastErrorReason === "string" ? state.lastErrorReason : undefined,
    runningAtMs: typeof state.runningAtMs === "number" ? state.runningAtMs : undefined,
  };
}

function defaultJobs() {
  return [
    {
      id: "0347a94f-872c-4d3a-a583-81fb6758461d",
      name: "Heartbeat",
      enabled: true,
      schedule: { kind: "every", everyMs: 600_000, anchorMs: 1774864592360 },
      action: {
        kind: "shell",
        command: "bash ./scripts/watcher.sh",
        cwd: resolveRepoPath(),
      },
      state: { lastStatus: "never", consecutiveErrors: 0 },
    },
    {
      id: "c1ac22ab-b891-4b8f-bbdb-ea9fe9d0825c",
      name: "pr-ci-nixelo",
      enabled: false,
      schedule: { kind: "every", everyMs: 300_000, anchorMs: 1772823696502 },
      action: { kind: "lane", mode: "prci", repo: "nixelo", title: "nixelo" },
      state: { lastStatus: "never", consecutiveErrors: 0 },
    },
    {
      id: "4e8a1a98-a905-4f77-9373-9332f7e46e77",
      name: "pr-ci-starthub",
      enabled: false,
      schedule: { kind: "every", everyMs: 300_000, anchorMs: 1772823697437 },
      action: { kind: "lane", mode: "prci", repo: "starthub", title: "starthub" },
      state: { lastStatus: "never", consecutiveErrors: 0 },
    },
    {
      id: "fe8d3a4d-0d8b-4583-9079-36064e1617cf",
      name: "Morning Sub-Agent Report",
      enabled: false,
      schedule: { kind: "cron", expr: "0 9 * * *", tz: DEFAULT_TIMEZONE },
      action: { kind: "prompt", title: "shadow", text: "[Cron Trigger] Generate Morning Report" },
      state: { lastStatus: "never", consecutiveErrors: 0 },
    },
    {
      id: "a841fdb2-3f9b-489d-aeb7-0b61c711cd4a",
      name: "Nightly Sub-Agent Report",
      enabled: false,
      schedule: { kind: "cron", expr: "0 20 * * *", tz: DEFAULT_TIMEZONE },
      action: { kind: "prompt", title: "shadow", text: "[Cron Trigger] Generate Nightly Report" },
      state: { lastStatus: "never", consecutiveErrors: 0 },
    },
  ];
}

function mergeSchedule(defaultSchedule, legacyJob) {
  if (!isObject(legacyJob?.schedule)) {
    return clone(defaultSchedule);
  }
  const schedule = legacyJob.schedule;
  if (schedule.kind === "every" && typeof schedule.everyMs === "number") {
    return {
      kind: "every",
      everyMs: schedule.everyMs,
      anchorMs:
        typeof schedule.anchorMs === "number"
          ? schedule.anchorMs
          : typeof defaultSchedule.anchorMs === "number"
            ? defaultSchedule.anchorMs
            : nowMs(),
    };
  }
  if (schedule.kind === "cron" && typeof schedule.expr === "string") {
    return {
      kind: "cron",
      expr: schedule.expr,
      tz: typeof schedule.tz === "string" ? schedule.tz : DEFAULT_TIMEZONE,
    };
  }
  return clone(defaultSchedule);
}

function mergeAction(defaultAction, legacyJob) {
  if (!isObject(legacyJob?.payload)) {
    return clone(defaultAction);
  }
  const merged = clone(defaultAction);
  if (typeof legacyJob.payload.model === "string") {
    merged.model = legacyJob.payload.model;
  }
  if (typeof legacyJob.payload.timeoutSeconds === "number") {
    merged.timeoutSeconds = legacyJob.payload.timeoutSeconds;
  }
  return merged;
}

async function loadLegacyJobs() {
  try {
    const raw = await readFile(LEGACY_CRON_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed?.jobs) ? parsed.jobs : [];
  } catch {
    return [];
  }
}

function parseHumanInterval(raw) {
  const match = /^(\d+)([mh])$/.exec(raw.trim());
  if (!match) {
    throw new Error(`Unsupported interval '${raw}'`);
  }
  const value = Number(match[1]);
  return match[2] === "h" ? value * 60 * 60 * 1000 : value * 60 * 1000;
}

function normalizeCronFieldValue(raw, fieldIndex) {
  const value = raw.toLowerCase();
  if (fieldIndex === 4 && Object.prototype.hasOwnProperty.call(WEEKDAY_INDEX, value)) {
    return WEEKDAY_INDEX[value];
  }
  return Number(value);
}

function parseCronField(rawField, fieldIndex) {
  if (rawField === "*") {
    return { any: true };
  }
  const range = CRON_FIELD_RANGES[fieldIndex];
  const values = rawField.split(",").map((part) => {
    const value = normalizeCronFieldValue(part.trim(), fieldIndex);
    if (!Number.isInteger(value) || value < range.min || value > range.max) {
      throw new Error(`Unsupported cron field '${rawField}'`);
    }
    return value;
  });
  return { any: false, values };
}

function parseCronExpression(expr) {
  const parts = expr.trim().split(/\s+/);
  if (parts.length !== 5) {
    throw new Error(`Unsupported cron expression '${expr}'`);
  }
  return parts.map((part, index) => parseCronField(part, index));
}

function getTzParts(timestamp, timeZone) {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "numeric",
    day: "numeric",
    weekday: "short",
    hour: "numeric",
    minute: "numeric",
    hour12: false,
  });
  const values = {};
  for (const part of formatter.formatToParts(new Date(timestamp))) {
    if (part.type !== "literal") {
      values[part.type] = part.value;
    }
  }
  return {
    minute: Number(values.minute),
    hour: Number(values.hour),
    dayOfMonth: Number(values.day),
    month: Number(values.month),
    dayOfWeek: WEEKDAY_INDEX[String(values.weekday || "").slice(0, 3).toLowerCase()],
  };
}

function cronMatches(fields, parts) {
  const values = [parts.minute, parts.hour, parts.dayOfMonth, parts.month, parts.dayOfWeek];
  return fields.every((field, index) => field.any || field.values.includes(values[index]));
}

function nextCronRunAt(schedule, fromMs) {
  const tz = typeof schedule.tz === "string" ? schedule.tz : DEFAULT_TIMEZONE;
  const fields = parseCronExpression(schedule.expr);
  let cursor = Math.floor(fromMs / 60_000) * 60_000 + 60_000;
  const limit = cursor + 14 * 24 * 60 * 60 * 1000;
  while (cursor <= limit) {
    if (cronMatches(fields, getTzParts(cursor, tz))) {
      return cursor;
    }
    cursor += 60_000;
  }
  throw new Error(`No next run found for cron '${schedule.expr}'`);
}

function nextEveryRunAt(schedule, fromMs) {
  const everyMs = Number(schedule.everyMs);
  const anchorMs = Number(schedule.anchorMs || fromMs);
  if (!Number.isFinite(everyMs) || everyMs <= 0) {
    throw new Error("Invalid every schedule");
  }
  if (anchorMs > fromMs) {
    return anchorMs;
  }
  const elapsed = fromMs - anchorMs;
  return anchorMs + (Math.floor(elapsed / everyMs) + 1) * everyMs;
}

function computeNextRunAt(job, fromMs) {
  if (!isObject(job.schedule)) {
    return undefined;
  }
  if (job.schedule.kind === "every") {
    return nextEveryRunAt(job.schedule, fromMs);
  }
  if (job.schedule.kind === "cron") {
    return nextCronRunAt(job.schedule, fromMs);
  }
  return undefined;
}

async function ensureParent(filePath) {
  await mkdir(dirname(filePath), { recursive: true });
}

async function saveStore(filePath, store) {
  await ensureParent(filePath);
  await writeFile(filePath, `${JSON.stringify(store, null, 2)}\n`, "utf8");
}

async function buildInitialStore() {
  const createdAtMs = nowMs();
  const legacyJobs = await loadLegacyJobs();
  const legacyByName = new Map(
    legacyJobs
      .filter((job) => typeof job?.name === "string")
      .map((job) => [job.name, job]),
  );
  const jobs = defaultJobs().map((job) => {
    const legacy = legacyByName.get(job.name);
    const merged = {
      id: typeof legacy?.id === "string" ? legacy.id : job.id,
      name: job.name,
      enabled: typeof legacy?.enabled === "boolean" ? legacy.enabled : job.enabled,
      createdAtMs: typeof legacy?.createdAtMs === "number" ? legacy.createdAtMs : createdAtMs,
      updatedAtMs: typeof legacy?.updatedAtMs === "number" ? legacy.updatedAtMs : createdAtMs,
      schedule: mergeSchedule(job.schedule, legacy),
      action: mergeAction(job.action, legacy),
      state: normalizeState(legacy?.state || job.state),
    };
    if (merged.enabled && typeof merged.state.nextRunAtMs !== "number") {
      merged.state.nextRunAtMs = computeNextRunAt(merged, createdAtMs);
    }
    return merged;
  });
  return { version: 1, jobs };
}

function normalizeJob(job, createdAtMs) {
  return {
    id: typeof job?.id === "string" ? job.id : makeId(),
    name: typeof job?.name === "string" ? job.name : "Unnamed job",
    enabled: Boolean(job?.enabled),
    createdAtMs: typeof job?.createdAtMs === "number" ? job.createdAtMs : createdAtMs,
    updatedAtMs: typeof job?.updatedAtMs === "number" ? job.updatedAtMs : createdAtMs,
    schedule: clone(job?.schedule || {}),
    action: clone(job?.action || {}),
    state: normalizeState(job?.state),
  };
}

function presentJob(job) {
  const scheduleText =
    job.schedule?.kind === "every"
      ? SCHEDULE_LABELS[job.schedule.everyMs] || `every ${Math.round(job.schedule.everyMs / 1000)}s`
      : job.schedule?.kind === "cron"
        ? `cron ${job.schedule.expr}${job.schedule.tz ? ` ${job.schedule.tz}` : ""}`
        : "unknown";
  const status = job.state?.runningAtMs
    ? "running"
    : !job.enabled
      ? "disabled"
      : job.state?.lastStatus || "enabled";
  return {
    ...clone(job),
    scheduleText,
    status,
  };
}

function findJob(store, identifier) {
  return store.jobs.find((job) => job.id === identifier || job.name === identifier) || null;
}

async function executeShell(action) {
  const result = await execFileAsync("bash", ["-lc", action.command], {
    cwd: action.cwd || resolveRepoPath(),
    maxBuffer: 1024 * 1024,
  });
  return {
    ok: true,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
  };
}

async function executeAction(job) {
  const action = job.action;
  if (!isObject(action) || typeof action.kind !== "string") {
    return { ok: false, error: `Job ${job.name} has no valid action` };
  }
  if (action.kind === "lane") {
    return enqueueLane(action.mode || "", action.repo || "", {
      ...(typeof action.title === "string" ? { title: action.title } : {}),
      ...(typeof action.sessionId === "string" ? { sessionId: action.sessionId } : {}),
    });
  }
  if (action.kind === "prompt") {
    return safeSendPrompt(action.text || "", {
      ...(typeof action.title === "string" ? { title: action.title } : {}),
      ...(typeof action.sessionId === "string" ? { sessionId: action.sessionId } : {}),
      ...(typeof action.model === "string" ? { model: action.model } : {}),
    });
  }
  if (action.kind === "command") {
    return safeRunCommand(action.command || "", Array.isArray(action.arguments) ? action.arguments : [], {
      ...(typeof action.title === "string" ? { title: action.title } : {}),
      ...(typeof action.sessionId === "string" ? { sessionId: action.sessionId } : {}),
      ...(typeof action.model === "string" ? { model: action.model } : {}),
    });
  }
  if (action.kind === "shell") {
    return executeShell(action);
  }
  return { ok: false, error: `Unsupported action kind ${action.kind}` };
}

async function runJob(job, scheduledAt) {
  const startedAt = nowMs();
  job.state = {
    ...normalizeState(job.state),
    runningAtMs: startedAt,
  };
  try {
    const result = await executeAction(job);
    const finishedAt = nowMs();
    const success = Boolean(result?.ok);
    const previous = normalizeState(job.state);
    job.updatedAtMs = finishedAt;
    job.state = {
      ...previous,
      runningAtMs: undefined,
      lastRunAtMs: finishedAt,
      lastRunStatus: success ? "ok" : "error",
      lastStatus: success ? "ok" : "error",
      lastDurationMs: finishedAt - startedAt,
      consecutiveErrors: success ? 0 : previous.consecutiveErrors + 1,
      lastError: success ? undefined : result?.error || "Unknown cron error",
      lastErrorReason: success ? undefined : result?.state || "execution_failed",
      nextRunAtMs: job.enabled ? computeNextRunAt(job, scheduledAt) : undefined,
    };
    return { ok: success, result };
  } catch (error) {
    const finishedAt = nowMs();
    const previous = normalizeState(job.state);
    job.updatedAtMs = finishedAt;
    job.state = {
      ...previous,
      runningAtMs: undefined,
      lastRunAtMs: finishedAt,
      lastRunStatus: "error",
      lastStatus: "error",
      lastDurationMs: finishedAt - startedAt,
      consecutiveErrors: previous.consecutiveErrors + 1,
      lastError: error instanceof Error ? error.message : String(error),
      lastErrorReason: "execution_failed",
      nextRunAtMs: job.enabled ? computeNextRunAt(job, scheduledAt) : undefined,
    };
    return {
      ok: false,
      result: {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      },
    };
  }
}

export async function loadCronStore(options = {}) {
  const filePath = cronPath(options);
  try {
    const raw = await readFile(filePath, "utf8");
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed?.jobs)) {
      return {
        filePath,
        store: {
          version: 1,
          jobs: parsed.jobs.map((job) => normalizeJob(job, nowMs())),
        },
      };
    }
  } catch (error) {
    if (!error || typeof error !== "object" || error.code !== "ENOENT") {
      throw error;
    }
  }
  const store = await buildInitialStore();
  await saveStore(filePath, store);
  return { filePath, store };
}

export async function listCronJobs(options = {}) {
  const { filePath, store } = await loadCronStore(options);
  return {
    ok: true,
    filePath,
    jobs: store.jobs.map((job) => presentJob(job)),
  };
}

export function formatCronList(result) {
  const header = "ID                                   NAME                     SCHEDULE                       STATUS    ENABLED";
  const lines = (result.jobs || []).map((job) => {
    const id = String(job.id || "").padEnd(36, " ");
    const name = String(job.name || "").padEnd(24, " ");
    const schedule = String(job.scheduleText || "unknown").padEnd(30, " ");
    const status = String(job.status || "unknown").padEnd(8, " ");
    return `${id}  ${name}  ${schedule}  ${status}  ${job.enabled ? "enabled" : "disabled"}`;
  });
  return [header, ...lines].join("\n");
}

export async function setCronEnabled(identifier, enabled, options = {}) {
  const { filePath, store } = await loadCronStore(options);
  const job = findJob(store, identifier);
  if (!job) {
    return { ok: false, error: `Cron job not found: ${identifier}` };
  }
  const timestamp = nowMs();
  const previous = normalizeState(job.state);
  job.enabled = enabled;
  job.updatedAtMs = timestamp;
  job.state = {
    ...previous,
    lastStatus: enabled ? previous.lastStatus || "enabled" : "disabled",
    nextRunAtMs: enabled ? computeNextRunAt(job, timestamp) : undefined,
    runningAtMs: undefined,
  };
  await saveStore(filePath, store);
  return { ok: true, filePath, job: presentJob(job) };
}

export async function editCronJob(identifier, updates, options = {}) {
  const { filePath, store } = await loadCronStore(options);
  const job = findJob(store, identifier);
  if (!job) {
    return { ok: false, error: `Cron job not found: ${identifier}` };
  }
  if (typeof updates.every === "string") {
    job.schedule = {
      kind: "every",
      everyMs: parseHumanInterval(updates.every),
      anchorMs: nowMs(),
    };
  }
  if (typeof updates.model === "string" && isObject(job.action)) {
    job.action.model = updates.model;
  }
  const timestamp = nowMs();
  job.updatedAtMs = timestamp;
  job.state = {
    ...normalizeState(job.state),
    nextRunAtMs: job.enabled ? computeNextRunAt(job, timestamp) : undefined,
  };
  await saveStore(filePath, store);
  return { ok: true, filePath, job: presentJob(job) };
}

export async function runCronJob(identifier, options = {}) {
  const { filePath, store } = await loadCronStore(options);
  const job = findJob(store, identifier);
  if (!job) {
    return { ok: false, error: `Cron job not found: ${identifier}` };
  }
  const result = await runJob(job, nowMs());
  await saveStore(filePath, store);
  return { ok: result.ok, filePath, job: presentJob(job), result: result.result };
}

export async function runDueCronJobs(options = {}) {
  const { filePath, store } = await loadCronStore(options);
  const scheduledAt = nowMs();
  const results = [];
  for (const job of store.jobs) {
    if (!job.enabled) {
      continue;
    }
    const nextRunAtMs =
      typeof job.state?.nextRunAtMs === "number" ? job.state.nextRunAtMs : computeNextRunAt(job, scheduledAt);
    if (typeof nextRunAtMs === "number" && nextRunAtMs <= scheduledAt) {
      const result = await runJob(job, scheduledAt);
      results.push({ jobId: job.id, ok: result.ok, result: result.result });
    } else if (typeof job.state?.nextRunAtMs !== "number") {
      job.state = {
        ...normalizeState(job.state),
        nextRunAtMs,
      };
    }
  }
  await saveStore(filePath, store);
  return { ok: true, filePath, due: results.length, results };
}
