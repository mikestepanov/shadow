import { getBaseUrl, getHealth, getSessionStatuses, listSessions } from "./client.js";

function toSessionArray(value) {
  return Array.isArray(value) ? value : [];
}

function toStatusEntries(value) {
  return value && typeof value === "object" ? Object.entries(value) : [];
}

function classifyStatusValue(rawStatus) {
  if (typeof rawStatus === "string") {
    const value = rawStatus.toLowerCase();
    if (value.includes("wait") && value.includes("user")) return "waiting_user";
    if (value.includes("idle")) return "idle";
    if (value.includes("busy") || value.includes("running") || value.includes("stream") || value.includes("tool")) return "busy";
    if (value.includes("prompt") || value.includes("permission") || value.includes("approval")) return "waiting_user";
  }
  return null;
}

function normalizeSessionState(statusValue) {
  if (typeof statusValue === "string") {
    return classifyStatusValue(statusValue) || "unknown";
  }

  if (statusValue && typeof statusValue === "object") {
    const directKeys = [statusValue.status, statusValue.state, statusValue.mode, statusValue.kind];
    for (const value of directKeys) {
      const classified = classifyStatusValue(value);
      if (classified) return classified;
    }

    for (const [key, value] of Object.entries(statusValue)) {
      const classifiedKey = classifyStatusValue(key);
      if (classifiedKey) return classifiedKey;
      const classifiedValue = classifyStatusValue(value);
      if (classifiedValue) return classifiedValue;
    }
  }

  return "unknown";
}

function scoreStatus(state) {
  if (state === "busy") return 3;
  if (state === "waiting_user") return 2;
  if (state === "idle") return 1;
  return 0;
}

function pickRepresentativeSession(sessions, statuses) {
  const statusById = new Map(toStatusEntries(statuses));
  const enriched = toSessionArray(sessions).map((session) => {
    const sessionId = session?.id || session?.ID || session?.sessionID || "";
    const rawStatus = statusById.get(sessionId);
    const state = normalizeSessionState(rawStatus);
    return {
      session,
      sessionId,
      rawStatus,
      state,
    };
  });

  enriched.sort((a, b) => scoreStatus(b.state) - scoreStatus(a.state));
  return enriched[0] || null;
}

export async function getControllerStatus(options = {}) {
  const baseUrl = getBaseUrl(options);

  try {
    const [health, sessions, statuses] = await Promise.all([
      getHealth({ baseUrl }),
      listSessions({ baseUrl }),
      getSessionStatuses({ baseUrl }),
    ]);

    const sessionList = toSessionArray(sessions);
    const statusEntries = toStatusEntries(statuses);
    const picked = pickRepresentativeSession(sessionList, statuses);
    const inferredState = statusEntries.length === 0 && sessionList.length > 0 ? "idle" : picked?.state || "unknown";
    return {
      ok: true,
      baseUrl,
      healthy: Boolean(health?.healthy),
      version: typeof health?.version === "string" ? health.version : null,
      state: inferredState,
      sessionId: picked?.sessionId || null,
      title: picked?.session?.title || null,
      rawStatus: picked?.rawStatus ?? null,
      sessions: sessionList.length,
    };
  } catch (error) {
    return {
      ok: false,
      baseUrl,
      healthy: false,
      version: null,
      state: "unknown",
      sessionId: null,
      title: null,
      rawStatus: null,
      sessions: 0,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
