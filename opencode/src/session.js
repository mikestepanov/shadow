import { execFile, spawn } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { promisify } from "node:util";
import { getSessionById, listSessions } from "./client.js";
import { getRepoConfig } from "./lanes.js";
import { resolveOpencodeVarPath, resolveRepoPath } from "./paths.js";

const execFileAsync = promisify(execFile);
const MANUAL_SESSIONS_PATH = resolveOpencodeVarPath("manual-sessions.json");
const OPENCODE_BIN = "/run/current-system/sw/bin/opencode";

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
  const repoConfig = getRepoConfig(repo);
  if (!repoConfig) {
    return null;
  }

  return {
    title: repoConfig.title,
    dir: repoConfig.workdir,
  };
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

async function runLegacyManualPing(repo) {
  try {
    const { stdout } = await execFileAsync(resolveRepoPath("scripts", "manual-terminal-ping"), [repo], {
      cwd: resolveRepoPath(),
      env: process.env,
    });
    const lines = String(stdout || "")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const lastLine = lines[lines.length - 1] || "";

    if (lastLine.startsWith("SENT ")) {
      return { ok: true, action: "sent", message: lastLine };
    }
    if (lastLine.startsWith("TRANSITION ")) {
      return { ok: true, action: "transition", message: lastLine };
    }
    if (lastLine.startsWith("NOOP:") || lastLine.startsWith("SKIP ") || lastLine.startsWith("BLOCKED_HUMAN:")) {
      return { ok: true, action: "noop", message: lastLine };
    }

    return {
      ok: false,
      action: "error",
      error: `Unexpected manual ping output for ${repo}${lastLine ? `: ${lastLine}` : ""}`,
    };
  } catch (error) {
    return {
      ok: false,
      action: "error",
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

async function runLegacyAgentPing(repo) {
  try {
    const { stdout } = await execFileAsync(resolveRepoPath("scripts", "agent-terminal-ping"), [repo], {
      cwd: resolveRepoPath(),
      env: process.env,
    });
    const lines = String(stdout || "")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const lastLine = lines[lines.length - 1] || "";

    if (lastLine.startsWith("SENT ")) {
      return { ok: true, action: "sent", message: lastLine };
    }
    if (lastLine.startsWith("NOOP:") || lastLine.startsWith("SKIP ") || lastLine.startsWith("BLOCKED_HUMAN:")) {
      return { ok: true, action: "noop", message: lastLine };
    }

    return {
      ok: false,
      action: "error",
      error: `Unexpected agent ping output for ${repo}${lastLine ? `: ${lastLine}` : ""}`,
    };
  } catch (error) {
    return {
      ok: false,
      action: "error",
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

async function runLegacyPrciPing(repo) {
  try {
    const { stdout } = await execFileAsync(resolveRepoPath("scripts", "prci-terminal-ping"), [repo], {
      cwd: resolveRepoPath(),
      env: process.env,
    });
    const lines = String(stdout || "")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    const lastLine = lines[lines.length - 1] || "";

    if (lastLine.startsWith("OK:") || lastLine.startsWith("NOOP:") || lastLine.startsWith("PR-CI:") || lastLine.startsWith("SKIP ") || lastLine.startsWith("BLOCKED_HUMAN:")) {
      return { ok: true, action: "noop", message: lastLine };
    }

    return {
      ok: false,
      action: "error",
      error: `Unexpected PR-CI ping output for ${repo}${lastLine ? `: ${lastLine}` : ""}`,
    };
  } catch (error) {
    return {
      ok: false,
      action: "error",
      error: error instanceof Error ? error.message : String(error),
    };
  }
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
  if (!manualConfig(repo)) {
    return { ok: false, error: `Unknown manual repo ${repo}` };
  }

  const legacyResult = await runLegacyManualPing(repo);
  if (legacyResult.ok) {
    return {
      ok: true,
      repo,
      action: legacyResult.action,
      message: legacyResult.message,
    };
  }

  return {
    ok: false,
    repo,
    error: legacyResult.error || `Manual ping failed for ${repo}`,
  };
}

export async function runAgentPing(repo) {
  if (!manualConfig(repo)) {
    return { ok: false, error: `Unknown agent repo ${repo}` };
  }

  const legacyResult = await runLegacyAgentPing(repo);
  if (legacyResult.ok) {
    return {
      ok: true,
      repo,
      action: legacyResult.action,
      message: legacyResult.message,
    };
  }

  return {
    ok: false,
    repo,
    error: legacyResult.error || `Agent ping failed for ${repo}`,
  };
}

export async function runPrciPing(repo) {
  if (!manualConfig(repo)) {
    return { ok: false, error: `Unknown PR-CI repo ${repo}` };
  }

  const legacyResult = await runLegacyPrciPing(repo);
  if (legacyResult.ok) {
    return {
      ok: true,
      repo,
      action: legacyResult.action,
      message: legacyResult.message,
    };
  }

  return {
    ok: false,
    repo,
    error: legacyResult.error || `PR-CI ping failed for ${repo}`,
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
