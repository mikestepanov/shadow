const LANE_CONFIG = {
  "manual:nixelo": {
    repo: "nixelo",
    mode: "manual",
    title: "nixelo",
    action: "prompt",
    completion: "accepted",
    prompt: "Read todos-hot/README.md. Pick the single highest-impact open item. Implement it completely and robustly - proper abstractions, edge case handling, tests if applicable, no shortcuts. Take as long as needed. Run all checks (typecheck, lint, validate, tests), commit with a detailed message explaining what changed and why, then report what's next.",
  },
  "manual:starthub": {
    repo: "starthub",
    mode: "manual",
    title: "starthub",
    action: "prompt",
    completion: "accepted",
    prompt: "Read todos/planning/postgres-migration.md. Pick the single highest-impact open item. Implement it completely and robustly - proper abstractions, edge case handling, tests if applicable, no shortcuts. Take as long as needed. Run all checks (typecheck, lint, validate, tests), commit with a detailed message explaining what changed and why, then report what's next.",
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
