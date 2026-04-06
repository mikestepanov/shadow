import { listSessions } from "./client.js";

function toSessionArray(value) {
  return Array.isArray(value) ? value : [];
}

function sessionUpdatedAt(session) {
  return Number(session?.time?.updated || session?.time?.created || 0);
}

export async function resolveTargetSession(options = {}) {
  const sessions = toSessionArray(await listSessions(options));
  if (sessions.length === 0) {
    return null;
  }

  if (options.sessionId) {
    return sessions.find((session) => session.id === options.sessionId) || null;
  }

  const sorted = [...sessions].sort((a, b) => sessionUpdatedAt(b) - sessionUpdatedAt(a));
  return sorted[0] || null;
}
