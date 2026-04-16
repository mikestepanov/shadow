import { execFile, spawn } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { promisify } from "node:util";
import { getSessionById, listSessionMessages, listSessions, promptSessionAsync, sessionExists } from "./client.js";
import { getLaneConfig } from "./lanes.js";
import { resolveOpencodeVarPath, resolveRepoPath } from "./paths.js";

const execFileAsync = promisify(execFile);
const MANUAL_SESSIONS_PATH = resolveOpencodeVarPath("manual-sessions.json");
const OPENCODE_BIN = "/run/current-system/sw/bin/opencode";
const STALE_BUSY_MS = Number(process.env.OPENCODE_STALE_BUSY_MS || 90 * 60 * 1000);

const MANUAL_CONFIG = {
  nixelo: {
    title: "nixelo",
    dir: resolveRepoPath("..", "nixelo"),
    timerUnit: "manual-terminal-nixelo.timer",
    prciCronId: "c1ac22ab-b891-4b8f-bbdb-ea9fe9d0825c",
    todoFile: "todos-hot/README.md",
    autoGateFile: resolveRepoPath("auto-nixelo-enabled.json"),
  },
  starthub: {
    title: "starthub",
    dir: resolveRepoPath("..", "StartHub"),
    timerUnit: "manual-terminal-starthub.timer",
    prciCronId: "4e8a1a98-a905-4f77-9373-9332f7e46e77",
    todoFile: "todos/planning/postgres-migration.md",
    autoGateFile: null,
  },
};

function toSessionArray(value) {
  return Array.isArray(value) ? value : [];
}

function sessionUpdatedAt(session) {
  return Number(session?.time?.updated || session?.time?.created || 0);
}

function titleMatches(session, query) {
  if (typeof query !== "string" || query.trim() === "") {
    return false;
  }
  const title = typeof session?.title === "string" ? session.title : "";
  return title.toLowerCase().includes(query.trim().toLowerCase());
}

async function ensureParent(filePath) {
  await mkdir(dirname(filePath), { recursive: true });
}

async function loadManualSessionStore() {
  try {
    const raw = await readFile(MANUAL_SESSIONS_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (error) {
    if (error && typeof error === "object" && error.code === "ENOENT") {
      return {};
    }
    if (error instanceof SyntaxError) {
      return {};
    }
    throw error;
  }
}

async function saveManualSessionStore(store) {
  await ensureParent(MANUAL_SESSIONS_PATH);
  const tempPath = `${MANUAL_SESSIONS_PATH}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tempPath, `${JSON.stringify(store, null, 2)}\n`, "utf8");
  await rename(tempPath, MANUAL_SESSIONS_PATH);
}

function manualConfig(repo) {
  return MANUAL_CONFIG[repo] || null;
}

function parseJsonLines(raw) {
  return String(raw || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

async function createAttachedSession(repo, config) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      OPENCODE_BIN,
      [
        "run",
        "--attach",
        "http://127.0.0.1:4096",
        "--title",
        config.title,
        "--dir",
        config.dir,
        "--continue",
        "--format",
        "json",
        "true",
      ],
      {
        cwd: config.dir,
        env: process.env,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );

    let resolved = false;
    let stdout = "";
    let stderr = "";

    const finish = (sessionId) => {
      if (resolved) {
        return;
      }
      resolved = true;
      child.kill("SIGTERM");
      resolve(sessionId);
    };

    const fail = (error) => {
      if (resolved) {
        return;
      }
      resolved = true;
      child.kill("SIGTERM");
      reject(error);
    };

    const inspect = () => {
      const events = parseJsonLines(stdout);
      const sessionId = events.find((event) => typeof event?.sessionID === "string")?.sessionID || null;
      if (sessionId) {
        finish(sessionId);
      }
    };

    const timer = setTimeout(() => {
      const events = parseJsonLines(stdout);
      const sessionId = events.find((event) => typeof event?.sessionID === "string")?.sessionID || null;
      if (sessionId) {
        finish(sessionId);
        return;
      }
      fail(new Error(`Timed out creating OpenCode session for ${repo}${stderr ? `: ${stderr.trim()}` : ""}`));
    }, 15000);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      inspect();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", (error) => {
      clearTimeout(timer);
      fail(error);
    });

    child.on("close", () => {
      clearTimeout(timer);
      if (resolved) {
        return;
      }
      const events = parseJsonLines(stdout);
      const sessionId = events.find((event) => typeof event?.sessionID === "string")?.sessionID || null;
      if (sessionId) {
        resolve(sessionId);
        return;
      }
      reject(new Error(`Failed to create OpenCode session for ${repo}${stderr ? `: ${stderr.trim()}` : ""}`));
    });
  });
}

async function dispatchAttachedPrompt(sessionId, config, prompt) {
  try {
    await promptSessionAsync(sessionId, {
      parts: [{ type: "text", text: prompt }],
    });

    const maxWait = 120000;
    const start = Date.now();
    while (Date.now() - start < maxWait) {
      await new Promise((r) => setTimeout(r, 3000));
      const messages = await listSessionMessages(sessionId, { limit: 1 });
      if (Array.isArray(messages) && messages[0]) {
        const msg = messages[0];
        const role = msg?.info?.role;
        const finish = msg?.info?.finish;
        const parts = Array.isArray(msg?.parts) ? msg.parts : [];
        
        const runningTools = parts.filter((p) => p?.state?.status === "running");
        if (runningTools.length > 0) {
          const toolTimes = runningTools.map((t) => t?.state?.time?.start || 0).filter(Number.isFinite);
          if (toolTimes.length > 0) {
            const oldestTool = Math.min(...toolTimes);
            if (Date.now() - oldestTool > 180000) {
              return { ok: true, sessionId, accepted: true, stale: true, recovered: true };
            }
          }
        }
        
        const hasRunning = parts.some((p) => p?.state?.status === "running");
        if (role === "assistant" && (finish === "stop" || finish === "error")) {
          return { ok: true, sessionId, completed: true };
        }
        if (!hasRunning && role === "assistant") {
          return { ok: true, sessionId, completed: true };
        }
      }
    }

    return { ok: true, sessionId, accepted: true, waited: true };
  } catch (err) {
    return {
      ok: false,
      sessionId,
      accepted: false,
      error: String(err),
    };
  }
}

async function readTodoStats(config) {
  const todoPath = `${config.dir}/${config.todoFile}`;
  let todoRaw = "";
  try {
    todoRaw = await readFile(todoPath, "utf8");
  } catch {
    return { todoPath, exists: false, checklistItems: 0, openItems: 0 };
  }

  const filesToCheck = [todoPath];
  const todoDir = dirname(todoPath);
  const links = [...todoRaw.matchAll(/\]\((\.?\/?[^)]+\.md)\)/g)].map((match) => match[1]);
  for (const linked of links) {
    const resolved = linked.startsWith("/") ? linked : `${todoDir}/${linked.replace(/^\.\//, "")}`;
    try {
      await readFile(resolved, "utf8");
      filesToCheck.push(resolved);
    } catch {
      // ignore missing linked files
    }
  }

  let openItems = 0;
  let checklistItems = 0;
  for (const filePath of filesToCheck) {
    const raw = await readFile(filePath, "utf8");
    openItems += (raw.match(/^\s*- \[ \]/gm) || []).length;
    checklistItems += (raw.match(/^\s*- \[[ xX]\]/gm) || []).length;
  }

  return { todoPath, exists: true, checklistItems, openItems };
}

async function autoGateEnabled(config) {
  if (!config.autoGateFile) {
    return true;
  }
  try {
    const raw = await readFile(config.autoGateFile, "utf8");
    const parsed = JSON.parse(raw);
    return Boolean(parsed?.enabled);
  } catch {
    return false;
  }
}

function latestMessageState(message) {
  if (!message || typeof message !== "object") {
    return "unknown";
  }
  const role = message?.info?.role;
  const finish = message?.info?.finish;
  const parts = Array.isArray(message?.parts) ? message.parts : [];
  
  const runningTools = parts.filter((p) => p?.state?.status === "running");
  if (runningTools.length > 0) {
    const toolTimes = runningTools.map((t) => t?.state?.time?.start || 0).filter(Number.isFinite);
    if (toolTimes.length > 0) {
      const oldestTool = Math.min(...toolTimes);
      if (Date.now() - oldestTool > 300000) {
        return "stale";
      }
    }
  }
  
  if (role === "assistant") {
    if (finish === "stop") {
      return "idle";
    }
    if (parts.some((part) => part?.type === "step-finish" && part?.reason === "stop")) {
      return "idle";
    }
    if (parts.some((part) => part?.type === "step-start" || part?.type === "reasoning")) {
      return "busy";
    }
  }
  if (role === "user") {
    const hasAssistantResponse = parts.some((part) => part?.type === "step-start");
    return hasAssistantResponse ? "busy" : "waiting";
  }
  return "unknown";
}

function latestMessageCreatedAt(message) {
  return Number(message?.info?.time?.created || message?.time?.created || 0);
}

function isStaleBusyMessage(message, state) {
  if (state !== "busy") {
    return false;
  }

  const createdAt = latestMessageCreatedAt(message);
  if (!Number.isFinite(createdAt) || createdAt <= 0) {
    return false;
  }

  if (Date.now() - createdAt < STALE_BUSY_MS) {
    return false;
  }

  const role = message?.info?.role;
  const finish = message?.info?.finish;
  const parts = Array.isArray(message?.parts) ? message.parts : [];

  if (role === "user") {
    return true;
  }

  if (role === "assistant") {
    if (finish === "stop") {
      return false;
    }
    if (parts.some((part) => part?.type === "step-finish" && part?.reason === "stop")) {
      return false;
    }
    return true;
  }

  return false;
}

async function latestSessionSnapshot(sessionId) {
  try {
    const messages = await listSessionMessages(sessionId, { limit: 1 });
    const message = Array.isArray(messages) ? messages[0] : null;
    const state = latestMessageState(message);
    return {
      state,
      message,
      createdAt: latestMessageCreatedAt(message),
      staleBusy: isStaleBusyMessage(message, state),
    };
  } catch {
    return {
      state: "unknown",
      message: null,
      createdAt: 0,
      staleBusy: false,
    };
  }
}

async function telegramNotify(text) {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (typeof token !== "string" || token.trim() === "") {
    return;
  }
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      chat_id: "780599199",
      text,
    }),
  }).catch(() => {});
}

async function setSystemdTimer(unit, enable) {
  await execFileAsync("systemctl", ["--user", enable ? "enable" : "disable", "--now", unit], {
    env: process.env,
  }).catch(() => {});
}

async function setOpencodeCron(cronId, enable) {
  await execFileAsync("node", [resolveRepoPath("opencode", "src", "index.js"), "cron", enable ? "enable" : "disable", cronId], {
    cwd: resolveRepoPath(),
    env: process.env,
  }).catch(() => {});
}

export async function getLiveSessionForRepo(repo) {
  const store = await loadManualSessionStore();
  const existing = store[repo];
  if (existing?.sessionId) {
    try {
      const session = await getSessionById(existing.sessionId);
      if (session) {
        return session;
      }
    } catch {
    }
  }
  
  const config = manualConfig(repo);
  if (!config) return null;
  
  const sessions = await listSessions({ all: true });
  const sessionList = Array.isArray(sessions) ? sessions : [];
  
  for (const session of sessionList) {
    const dir = session?.directory || "";
    const title = session?.title || "";
    const titleLower = title.toLowerCase();
    const queryLower = config.title.toLowerCase();
    if (dir === config.dir || titleLower === queryLower || titleLower.startsWith(queryLower)) {
      return session;
    }
  }
  return null;
}

export async function ensureManualSession(repo) {
  const config = manualConfig(repo);
  if (!config) {
    return { ok: false, error: `Unknown manual repo ${repo}` };
  }

  const liveSession = await getLiveSessionForRepo(repo);
  if (liveSession) {
    const store = await loadManualSessionStore();
    store[repo] = {
      sessionId: liveSession.id,
      title: config.title,
      directory: config.dir,
      updatedAt: Date.now(),
    };
    await saveManualSessionStore(store);
    return {
      ok: true,
      repo,
      sessionId: liveSession.id,
      created: false,
      title: config.title,
      directory: config.dir,
    };
  }

  const store = await loadManualSessionStore();
  const existing = store[repo];
  if (typeof existing?.sessionId === "string") {
    const stillAlive = await getLiveSessionForRepo(repo);
    if (stillAlive) {
      return {
        ok: true,
        repo,
        sessionId: stillAlive.id,
        created: false,
        title: config.title,
        directory: config.dir,
      };
    }
  }

  const sessionId = await createAttachedSession(repo, config);
  store[repo] = {
    sessionId,
    title: config.title,
    directory: config.dir,
    updatedAt: Date.now(),
  };
  await saveManualSessionStore(store);

  return {
    ok: true,
    repo,
    sessionId,
    created: true,
    title: config.title,
    directory: config.dir,
  };
}

export async function runManualPing(repo) {
  const config = manualConfig(repo);
  if (!config) {
    return { ok: false, error: `Unknown manual repo ${repo}` };
  }

  const session = await ensureManualSession(repo);
  if (!session.ok) {
    return session;
  }

  const todo = await readTodoStats(config);
  if (!todo.exists) {
    return {
      ok: true,
      repo,
      sessionId: session.sessionId,
      action: "skip",
      message: `NOOP:manual-missing-todo repo=${repo} path=${todo.todoPath}`,
    };
  }

  const snapshot = await latestSessionSnapshot(session.sessionId);
  const canDispatch = snapshot.state !== "busy" || snapshot.staleBusy;

  if (todo.checklistItems === 0) {
    const prompt = `Read ${config.todoFile}. Do NOT start implementation yet. First convert this TODO into markdown checkboxes (- [ ] for open items, - [x] for done items). Preserve all existing tasks/content. After converting, continue with the highest-impact open checkbox.`;
    if (!canDispatch) {
      return {
        ok: true,
        repo,
        sessionId: session.sessionId,
        action: "noop",
        message: `NOOP:manual-busy repo=${repo} session=${session.sessionId}`,
      };
    }

    await dispatchAttachedPrompt(session.sessionId, config, prompt);
    return {
      ok: true,
      repo,
      sessionId: session.sessionId,
      action: "sent",
      message: `SENT manual repo=${repo} session=${session.sessionId} msg=${prompt}`,
    };
  }

  if (todo.openItems === 0) {
    if (!(await autoGateEnabled(config))) {
      return {
        ok: true,
        repo,
        sessionId: session.sessionId,
        action: "skip",
        message: `NOOP:auto-nixelo-off repo=${repo} reason=todo-done but auto-nixelo disabled`,
      };
    }

    await setSystemdTimer(config.timerUnit, false);
    await setOpencodeCron(config.prciCronId, true);
    await telegramNotify(`🔄 ${repo}: TODO is done (${config.todoFile}). Disabled manual timer, enabled PR-CI. Transition complete.`);

    return {
      ok: true,
      repo,
      sessionId: session.sessionId,
      action: "transition",
      message: `SENT transition repo=${repo} reason=todo-done (0 open items in ${config.todoFile})`,
    };
  }

  const lane = getLaneConfig("manual", repo);
  if (!lane) {
    return { ok: false, error: `No manual lane for ${repo}` };
  }

  if (!canDispatch) {
    return {
      ok: true,
      repo,
      sessionId: session.sessionId,
      action: "noop",
      message: `NOOP:manual-busy repo=${repo} session=${session.sessionId}`,
    };
  }

  if (snapshot.staleBusy) {
    const staleMinutes = Math.floor((Date.now() - snapshot.createdAt) / 60000);
    await telegramNotify(`Recovered stale OpenCode manual session for ${repo} after ${staleMinutes}m stuck busy by dispatching a fresh attached runner.`);
  }

  await dispatchAttachedPrompt(session.sessionId, config, lane.prompt);

  return {
    ok: true,
    repo,
    sessionId: session.sessionId,
    action: "sent",
    message: `SENT manual repo=${repo} session=${session.sessionId} msg=${lane.prompt}`,
  };
}

export async function runAgentPing(repo) {
  const config = manualConfig(repo);
  if (!config) {
    return { ok: false, error: `Unknown agent repo ${repo}` };
  }

  const session = await ensureManualSession(repo);
  if (!session.ok) {
    return session;
  }

  const snapshot = await latestSessionSnapshot(session.sessionId);
  const canDispatch = snapshot.state !== "busy" || snapshot.staleBusy;

  const lane = getLaneConfig("agent", repo);
  if (!lane) {
    return { ok: false, error: `No agent lane for ${repo}` };
  }

  if (!canDispatch) {
    return {
      ok: true,
      repo,
      sessionId: session.sessionId,
      action: "noop",
      message: `NOOP:agent-busy repo=${repo} session=${session.sessionId}`,
    };
  }

  if (snapshot.staleBusy) {
    const staleMinutes = Math.floor((Date.now() - snapshot.createdAt) / 60000);
    await telegramNotify(`Recovered stale OpenCode agent session for ${repo} after ${staleMinutes}m stuck busy by dispatching a fresh attached runner.`);
  }

  await dispatchAttachedPrompt(session.sessionId, config, lane.prompt);

  return {
    ok: true,
    repo,
    sessionId: session.sessionId,
    action: "sent",
    message: `SENT agent repo=${repo} session=${session.sessionId} msg=${lane.prompt}`,
  };
}

export async function resolveTargetSession(options = {}) {
  const sessions = toSessionArray(await listSessions(options));
  if (sessions.length === 0) {
    return null;
  }

  if (options.sessionId) {
    return sessions.find((session) => session.id === options.sessionId) || null;
  }

  if (options.title) {
    const matched = sessions.filter((session) => titleMatches(session, options.title));
    if (matched.length === 0) {
      return null;
    }
    const sortedMatched = [...matched].sort((a, b) => sessionUpdatedAt(b) - sessionUpdatedAt(a));
    return sortedMatched[0] || null;
  }

  const sorted = [...sessions].sort((a, b) => sessionUpdatedAt(b) - sessionUpdatedAt(a));
  return sorted[0] || null;
}
