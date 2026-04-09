import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { promisify } from "node:util";
import { resolveRepoPath } from "./paths.js";

const execFileAsync = promisify(execFile);

const AUTO_CONFIG = {
  nixelo: {
    gateFile: resolveRepoPath("auto-nixelo-enabled.json"),
    scriptPath: resolveRepoPath("scripts", "auto_nixelo_cycle.sh"),
  },
};

async function readJson(filePath) {
  const raw = await readFile(filePath, "utf8");
  return JSON.parse(raw);
}

function splitOutput(stdout, stderr) {
  return `${stdout || ""}${stderr || ""}`
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function summarizeOutput(lines) {
  const lastLine = lines[lines.length - 1] || "";

  if (lastLine.startsWith("CYCLED:")) {
    return { action: "cycled", result: lastLine };
  }
  if (lastLine.startsWith("WAIT:")) {
    return { action: "waiting", result: lastLine };
  }
  if (lastLine.startsWith("SKIP:")) {
    return { action: "skipped", result: lastLine };
  }

  return { action: "checked", result: lastLine || "NO_OUTPUT" };
}

export async function runAutoCycle(repo) {
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

  try {
    const { stdout = "", stderr = "" } = await execFileAsync("bash", [config.scriptPath], {
      cwd: resolveRepoPath(),
      env: process.env,
    });
    const output = splitOutput(stdout, stderr);
    return {
      ok: true,
      repo,
      ...summarizeOutput(output),
      output,
    };
  } catch (error) {
    const stdout = typeof error?.stdout === "string" ? error.stdout : "";
    const stderr = typeof error?.stderr === "string" ? error.stderr : String(error?.message || "auto-cycle failed");
    const output = splitOutput(stdout, stderr);
    return {
      ok: false,
      repo,
      error: output[output.length - 1] || "auto-cycle failed",
      output,
    };
  }
}
