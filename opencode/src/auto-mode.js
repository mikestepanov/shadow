import { readFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { enqueueLane } from "./queue.js";
import { resolveRepoPath } from "./paths.js";

const execFileAsync = promisify(execFile);

const AUTO_CONFIG = {
  nixelo: {
    gateFile: resolveRepoPath("auto-nixelo-enabled.json"),
    repoPath: resolveRepoPath("..", "nixelo"),
    todoFile: "todos-hot/README.md",
  },
};

async function readJson(filePath) {
  const raw = await readFile(filePath, "utf8");
  return JSON.parse(raw);
}

async function countOpenTodos(repoPath, relativeTodoFile) {
  const target = resolve(repoPath, relativeTodoFile);
  const { stdout } = await execFileAsync("bash", ["-lc", `grep -c '^\s*- \[ \]' ${JSON.stringify(target)} || true`]);
  return Number(String(stdout).trim() || "0");
}

async function countCodeChanges(repoPath) {
  const { stdout } = await execFileAsync("bash", ["-lc", `git -C ${JSON.stringify(repoPath)} diff main --name-only | grep -cv '\\.md$' || true`]);
  return Number(String(stdout).trim() || "0");
}

export async function runAutoCycle(repo, options = {}) {
  const config = AUTO_CONFIG[repo];
  if (!config) {
    return { ok: false, error: `Unknown auto repo ${repo}` };
  }

  const gate = await readJson(config.gateFile);
  if (!gate?.enabled) {
    return {
      ok: true,
      repo,
      action: "skipped",
      reason: "auto-disabled",
    };
  }

  const openTodos = await countOpenTodos(config.repoPath, config.todoFile);
  if (openTodos > 0) {
    return {
      ok: true,
      repo,
      action: "none",
      reason: "todos-open",
      openTodos,
    };
  }

  const codeChanges = await countCodeChanges(config.repoPath);
  const nextMode = codeChanges > 0 ? "prci" : "agent";
  const queued = await enqueueLane(nextMode, repo, options);
  return {
    ok: true,
    repo,
    action: "queued",
    nextMode,
    codeChanges,
    openTodos,
    queued,
  };
}
