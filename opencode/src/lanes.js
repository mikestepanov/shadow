import { resolveRepoPath } from "./paths.js";

const AGENT_ROLES = ["auditor", "refactor"];

const REPO_CONFIG = {
  nixelo: {
    title: "nixelo",
    workdir: resolveRepoPath("..", "nixelo"),
    manualTodoFile: "todos-hot/README.md",
    manualObjectiveRecovery:
      "first review `todos-hot/README.md` and any todo markdown files it directly points to in order to recover the exact objective, current phase, and work order.",
    prciDispatchScript: resolveRepoPath("scripts", "pr_ci_nixelo_dispatch.sh"),
  },
  starthub: {
    title: "starthub",
    workdir: resolveRepoPath("..", "StartHub"),
    manualTodoFile: "todos/planning/postgres-migration.md",
    manualObjectiveRecovery:
      "first read `todos/planning/postgres-migration.md` to recover the exact objective, current phase, and work order. Make sure the file is read and include `readOptionalDocumentPictureReference` in your context.",
    prciDispatchScript: resolveRepoPath("scripts", "pr_ci_starthub_dispatch.sh"),
  },
};

function createPromptLane(repo, mode, prompt) {
  const repoConfig = getRepoConfig(repo);
  if (!repoConfig) {
    throw new Error(`Missing repo config for ${repo}`);
  }

  return {
    repo,
    mode,
    title: repoConfig.title,
    action: "prompt",
    completion: "accepted",
    prompt,
    workdir: repoConfig.workdir,
  };
}

function createCommandLane(repo, mode, command, argumentsList, timeoutMs = 5000) {
  const repoConfig = getRepoConfig(repo);
  if (!repoConfig) {
    throw new Error(`Missing repo config for ${repo}`);
  }

  return {
    repo,
    mode,
    title: repoConfig.title,
    action: "command",
    completion: "accepted",
    timeoutMs,
    command,
    arguments: argumentsList,
    workdir: repoConfig.workdir,
  };
}

function getChicagoHour(date = new Date()) {
  const formatted = new Intl.DateTimeFormat("en-US", {
    hour: "2-digit",
    hour12: false,
    timeZone: "America/Chicago",
  }).format(date);

  return Number(formatted);
}

function getAgentRole(date = new Date()) {
  const hour = getChicagoHour(date);
  return AGENT_ROLES[hour % AGENT_ROLES.length] || AGENT_ROLES[0];
}

function buildManualPrompt(repo) {
  const repoConfig = getRepoConfig(repo);
  if (!repoConfig) {
    throw new Error(`Missing repo config for ${repo}`);
  }

  return `If the current objective is already clear, continue. If it is not clear, ${repoConfig.manualObjectiveRecovery} Then identify the very next concrete step. If that step is already fully complete, remove it from the relevant todo file and continue to the new next step. Keep the todo docs accurate as you work. Then implement that next step completely and robustly - proper abstractions, edge case handling, tests if applicable, no shortcuts. Take as long as needed. Run all checks (typecheck, lint, validate, tests), commit with a detailed message explaining what changed and why, then report what's next.`;
}

function buildAgentPrompt(role) {
  return `MANDATORY ORDER (same branch only):
1) Stay on your CURRENT branch. Do NOT create or switch branches.
2) Work strictly within the ${role} facet defined in .agents/${role}.txt.
3) Continue any in-progress work only if it clearly belongs to this ${role} facet.
4) Go deep on this ${role} workstream. If a broader overhaul is needed to solve the ${role} problem correctly, do it. You may make multiple related fixes in this run as long as they all belong to the same ${role} facet.
5) Keep the relevant TODOs and notes accurate as the work evolves.
6) Run the relevant checks and commit at a clean, coherent checkpoint with a focused message.
Hard rules: no destructive git commands; no new branches; no unrelated work; no background branch fan-out.`;
}

function createManualLane(repo) {
  const repoConfig = getRepoConfig(repo);
  if (!repoConfig) {
    throw new Error(`Missing repo config for ${repo}`);
  }

  return {
    ...createPromptLane(repo, "manual", buildManualPrompt(repo)),
    todoFile: repoConfig.manualTodoFile,
  };
}

function createAgentLane(repo) {
  const role = getAgentRole();

  return {
    ...createPromptLane(repo, "agent", buildAgentPrompt(role)),
    role,
  };
}

function createPrciLane(repo) {
  const repoConfig = getRepoConfig(repo);
  if (!repoConfig) {
    throw new Error(`Missing repo config for ${repo}`);
  }

  return {
    ...createCommandLane(repo, "prci", "review", ["shadow"]),
    dispatchScript: repoConfig.prciDispatchScript,
  };
}

const REPOS = Object.keys(REPO_CONFIG);
const MODES = ["manual", "agent", "prci"];

function buildLane(mode, repo) {
  if (mode === "manual") {
    return createManualLane(repo);
  }

  if (mode === "agent") {
    return createAgentLane(repo);
  }

  if (mode === "prci") {
    return createPrciLane(repo);
  }

  return null;
}

export function getRepoConfig(repo) {
  return REPO_CONFIG[repo] || null;
}

export function getLaneConfig(mode, repo) {
  const repoConfig = getRepoConfig(repo);
  if (!repoConfig) {
    return null;
  }

  return buildLane(mode, repo);
}

export function getLaneField(mode, repo, field) {
  const lane = getLaneConfig(mode, repo);
  if (!lane || typeof field !== "string" || !(field in lane)) {
    return null;
  }

  const value = lane[field];
  return typeof value === "string" || typeof value === "number" || typeof value === "boolean" ? value : null;
}

export function listLaneKeys() {
  return REPOS.flatMap(repo => MODES.map(mode => `${mode}:${repo}`)).sort();
}
