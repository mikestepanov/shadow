import { promptSessionAsync } from "./client.js";
import { resolveTargetSession } from "./session.js";

export async function sendPrompt(text, options = {}) {
  if (typeof text !== "string" || text.trim() === "") {
    throw new Error("send requires non-empty text");
  }

  const session = await resolveTargetSession(options);
  if (!session) {
    return {
      ok: false,
      error: "No OpenCode session found",
    };
  }

  await promptSessionAsync(
    session.id,
    {
      parts: [{ type: "text", text }],
    },
    options,
  );

  return {
    ok: true,
    sessionId: session.id,
    title: session.title || null,
    sent: true,
  };
}
