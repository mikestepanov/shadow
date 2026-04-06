const DEFAULT_BASE_URL = process.env.OPENCODE_BASE_URL || "http://127.0.0.1:4096";

function joinUrl(baseUrl, path) {
  return `${baseUrl.replace(/\/$/, "")}${path}`;
}

export async function fetchJson(path, options = {}) {
  const baseUrl = options.baseUrl || DEFAULT_BASE_URL;
  const response = await fetch(joinUrl(baseUrl, path), {
    headers: {
      accept: "application/json",
      ...(options.headers || {}),
    },
    method: options.method || "GET",
    body: options.body,
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${path}`);
  }

  return response.json();
}

export async function fetchEmpty(path, options = {}) {
  const baseUrl = options.baseUrl || DEFAULT_BASE_URL;
  const response = await fetch(joinUrl(baseUrl, path), {
    headers: {
      accept: "application/json",
      ...(options.headers || {}),
    },
    method: options.method || "POST",
    body: options.body,
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${path}`);
  }

  return true;
}

export async function getHealth(options = {}) {
  return fetchJson("/global/health", options);
}

export async function listSessions(options = {}) {
  return fetchJson("/session", options);
}

export async function getSessionStatuses(options = {}) {
  return fetchJson("/session/status", options);
}

export async function listSessionMessages(sessionId, options = {}) {
  return fetchJson(`/session/${sessionId}/message?limit=${options.limit || 1}`, options);
}

export async function promptSessionAsync(sessionId, body, options = {}) {
  return fetchEmpty(`/session/${sessionId}/prompt_async`, {
    ...options,
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(options.headers || {}),
    },
    body: JSON.stringify(body),
  });
}

export function getBaseUrl(options = {}) {
  return options.baseUrl || DEFAULT_BASE_URL;
}
