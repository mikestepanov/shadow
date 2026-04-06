import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { runLane } from "./lane-run.js";

const DEFAULT_QUEUE_PATH = resolve(process.cwd(), "var/opencode-queue.json");

function queuePath(options = {}) {
  return options.queuePath || process.env.OPENCODE_QUEUE_PATH || DEFAULT_QUEUE_PATH;
}

async function ensureParent(filePath) {
  await mkdir(dirname(filePath), { recursive: true });
}

async function loadQueue(filePath) {
  try {
    const raw = await readFile(filePath, "utf8");
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    if (error && typeof error === "object" && error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
}

async function saveQueue(filePath, queue) {
  await ensureParent(filePath);
  await writeFile(filePath, `${JSON.stringify(queue, null, 2)}\n`, "utf8");
}

function createJob(mode, repo, options = {}) {
  const now = Date.now();
  return {
    id: `job_${now}_${Math.random().toString(36).slice(2, 10)}`,
    mode,
    repo,
    title: options.title || null,
    sessionId: options.sessionId || null,
    createdAt: now,
    nextRunAt: now,
    attempts: 0,
    lastResult: null,
  };
}

function retryDelayMs(attempts) {
  return Math.min(60000, 5000 * Math.max(1, attempts));
}

export async function enqueueLane(mode, repo, options = {}) {
  const filePath = queuePath(options);
  const queue = await loadQueue(filePath);
  const job = createJob(mode, repo, options);
  queue.push(job);
  await saveQueue(filePath, queue);
  return {
    ok: true,
    queuePath: filePath,
    job,
    queued: queue.length,
  };
}

export async function runQueue(options = {}) {
  const filePath = queuePath(options);
  const queue = await loadQueue(filePath);
  const now = Date.now();
  const remaining = [];
  const results = [];

  for (const job of queue) {
    if (Number(job.nextRunAt || 0) > now) {
      remaining.push(job);
      continue;
    }

    const runOptions = {
      ...(job.title ? { title: job.title } : {}),
      ...(job.sessionId ? { sessionId: job.sessionId } : {}),
    };

    const result = await runLane(job.mode, job.repo, runOptions);
    results.push({ jobId: job.id, result });

    if (result.deferred) {
      remaining.push({
        ...job,
        attempts: Number(job.attempts || 0) + 1,
        nextRunAt: Date.now() + retryDelayMs(Number(job.attempts || 0) + 1),
        lastResult: result,
      });
      continue;
    }
  }

  await saveQueue(filePath, remaining);
  return {
    ok: true,
    queuePath: filePath,
    processed: results.length,
    remaining: remaining.length,
    results,
  };
}
