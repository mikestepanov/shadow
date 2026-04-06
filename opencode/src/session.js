import { listSessions } from "./client.js";

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
