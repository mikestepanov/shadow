const LANE_CONFIG = {
  "manual:nixelo": {
    repo: "nixelo",
    mode: "manual",
    title: "nixelo",
    action: "prompt",
    completion: "accepted",
    prompt: "If the current objective is already clear, continue. If it is not clear, first review `todos-hot/README.md` and any todo markdown files it directly points to in order to recover the exact objective, current phase, and work order. Then identify the very next concrete step. If that step is already fully complete, remove it from the relevant todo file and continue to the new next step. Keep the todo docs accurate as you work. Then implement that next step completely and robustly - proper abstractions, edge case handling, tests if applicable, no shortcuts. Take as long as needed. Run all checks (typecheck, lint, validate, tests), commit with a detailed message explaining what changed and why, then report what's next.",
  },
  "manual:starthub": {
    repo: "starthub",
    mode: "manual",
    title: "starthub",
    action: "prompt",
    completion: "accepted",
    prompt: "If the current objective is already clear, continue. If it is not clear, first review `todos/planning/postgres-migration.md` to recover the exact objective, current phase, and work order. Then identify the very next concrete step. If that step is already fully complete, remove it from the relevant todo file and continue to the new next step. Keep the todo docs accurate as you work. Then implement that next step completely and robustly - proper abstractions, edge case handling, tests if applicable, no shortcuts. Take as long as needed. Run all checks (typecheck, lint, validate, tests), commit with a detailed message explaining what changed and why, then report what's next.",
  },
  "agent:nixelo": {
    repo: "nixelo",
    mode: "agent",
    title: "nixelo",
    action: "prompt",
    completion: "accepted",
    prompt: "Agent nixelo run: pick the next safe autonomous step, execute it, and stop if approval or clarification is required.",
  },
  "agent:starthub": {
    repo: "starthub",
    mode: "agent",
    title: "starthub",
    action: "prompt",
    completion: "accepted",
    prompt: "Agent starthub run: pick the next safe autonomous step, execute it, and stop if approval or clarification is required.",
  },
  "prci:nixelo": {
    repo: "nixelo",
    mode: "prci",
    title: "nixelo",
    action: "command",
    completion: "accepted",
    timeoutMs: 5000,
    command: "review",
    arguments: ["shadow"],
  },
  "prci:starthub": {
    repo: "starthub",
    mode: "prci",
    title: "starthub",
    action: "command",
    completion: "accepted",
    timeoutMs: 5000,
    command: "review",
    arguments: ["shadow"],
  },
};

export function getLaneConfig(mode, repo) {
  return LANE_CONFIG[`${mode}:${repo}`] || null;
}

export function listLaneKeys() {
  return Object.keys(LANE_CONFIG).sort();
}
