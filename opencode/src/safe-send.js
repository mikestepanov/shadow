import { sendPrompt } from "./send.js";
import { getControllerStatus } from "./status.js";
import { waitUntilIdle } from "./wait.js";

export async function safeSendPrompt(text, options = {}) {
  const current = await getControllerStatus(options);
  if (!current.ok) {
    return current;
  }

  if (current.state === "waiting_user") {
    return {
      ok: false,
      state: current.state,
      sessionId: current.sessionId,
      title: current.title,
      error: "Session is waiting for user input or approval",
    };
  }

  let waited = null;
  if (current.state === "busy") {
    waited = await waitUntilIdle(options);
    if (!waited.ok) {
      return waited;
    }
  }

  const sent = await sendPrompt(text, options);
  if (!sent.ok) {
    return sent;
  }

  return {
    ok: true,
    state: "sent",
    sessionId: sent.sessionId,
    title: sent.title,
    waitedMs: waited?.waitedMs || 0,
  };
}
