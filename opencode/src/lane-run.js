import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { getLaneConfig } from "./lanes.js";
import { resolveRepoPath } from "./paths.js";
import { safeRunCommand } from "./safe-command.js";
import { safeSendPrompt } from "./safe-send.js";
import { getControllerStatus } from "./status.js";

const execFileAsync = promisify(execFile);

const TERMINAL_PING_SCRIPT_BY_MODE = {
  manual: "manual-terminal-ping",
  agent: "agent-terminal-ping",
  prci: "prci-terminal-ping",
};

function terminalPingScript(mode) {
  const script = TERMINAL_PING_SCRIPT_BY_MODE[mode];
  return script ? resolveRepoPath("scripts", script) : null;
}

function lastOutputLine(raw) {
  return String(raw || "")
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .at(-1) || "";
}

async function answerWaitingUserWithTerminalLane(lane, current) {
  const script = terminalPingScript(lane.mode);
  if (!script) {
    return null;
  }

  try {
    const { stdout = "", stderr = "" } = await execFileAsync(script, [lane.repo], {
      cwd: resolveRepoPath(),
      env: {
        ...process.env,
        ANSWER_QUESTION_ONLY: "1",
      },
    });
    const message = lastOutputLine(`${stdout}\n${stderr}`);

    if (message.startsWith("SENT ") || message.startsWith("PR-CI: SENT ")) {
      return {
        ok: true,
        state: "waiting_user_answered",
        sessionId: current.sessionId,
        title: current.title,
        accepted: false,
        deferred: true,
        questionAnswered: true,
        message,
      };
    }

    if (message.startsWith("BLOCKED_HUMAN:")) {
      return {
        ok: false,
        state: current.state,
        sessionId: current.sessionId,
        title: current.title,
        accepted: false,
        deferred: true,
        error: message,
      };
    }

    return null;
  } catch (error) {
    return {
      ok: false,
      state: current.state,
      sessionId: current.sessionId,
      title: current.title,
      accepted: false,
      deferred: true,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

async function finalizeAccepted(result, options = {}) {
  if (!result.ok) {
    return result;
  }

  const status = await getControllerStatus(options);
  return {
    ...result,
    dispatch: status.ok ? status.state : "unknown",
    accepted: true,
  };
}

async function dispatchAcceptedLane(lane, runOptions) {
  const current = await getControllerStatus(runOptions);
  if (!current.ok) {
    return current;
  }

  if (current.state === "waiting_user") {
    const questionResult = await answerWaitingUserWithTerminalLane(lane, current);
    if (questionResult) {
      return questionResult;
    }
  }

  if (current.state === "busy" || current.state === "waiting_user") {
    return {
      ok: false,
      state: current.state,
      sessionId: current.sessionId,
      title: current.title,
      accepted: false,
      deferred: true,
      error: `Lane deferred because session is ${current.state}`,
    };
  }

  if (lane.action === "prompt") {
    const result = await safeSendPrompt(lane.prompt, runOptions);
    return finalizeAccepted(result, runOptions);
  }

  if (lane.action === "command") {
    const result = await safeRunCommand(lane.command, lane.arguments || [], runOptions);
    return finalizeAccepted(result, runOptions);
  }

  return {
    ok: false,
    error: `Unsupported lane action ${lane.action}`,
  };
}

export async function runLane(mode, repo, options = {}) {
  const lane = getLaneConfig(mode, repo);
  if (!lane) {
    return {
      ok: false,
      error: `Unknown lane ${mode}:${repo}`,
    };
  }

  const runOptions = {
    ...options,
    title: options.title || lane.title,
    timeoutMs: options.timeoutMs || lane.timeoutMs,
  };

  if (lane.completion === "accepted") {
    return dispatchAcceptedLane(lane, runOptions);
  }

  if (lane.action === "prompt") {
    return safeSendPrompt(lane.prompt, runOptions);
  }

  if (lane.action === "command") {
    return safeRunCommand(lane.command, lane.arguments || [], runOptions);
  }

  return {
    ok: false,
    error: `Unsupported lane action ${lane.action}`,
  };
}
