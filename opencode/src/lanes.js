const LANE_CONFIG = {
  "manual:nixelo": {
    repo: "nixelo",
    mode: "manual",
    title: "nixelo",
    action: "prompt",
    completion: "accepted",
    prompt: "Manual nixelo check-in: inspect current context, continue only if safe, and wait for the next explicit instruction if user input is required.",
  },
  "manual:starthub": {
    repo: "starthub",
    mode: "manual",
    title: "starthub",
    action: "prompt",
    completion: "accepted",
    prompt: "Manual starthub check-in: inspect current context, continue only if safe, and wait for the next explicit instruction if user input is required.",
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
