import { commandSession, listCommands } from "./client.js";
import { resolveTargetSession } from "./session.js";
import { getControllerStatus } from "./status.js";
import { waitUntilIdle } from "./wait.js";

export async function safeRunCommand(command, argumentsList = [], options = {}) {
  if (typeof command !== "string" || command.trim() === "") {
    throw new Error("safe-command requires a command name");
  }

  const availableCommands = await listCommands(options);
  const commandExists = Array.isArray(availableCommands)
    ? availableCommands.some((entry) => entry?.name === command)
    : false;
  if (!commandExists) {
    return {
      ok: false,
      state: "unknown",
      error: `OpenCode command not available: ${command}`,
    };
  }

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

  const session = await resolveTargetSession(options);
  if (!session) {
    return {
      ok: false,
      error: "No OpenCode session found",
    };
  }

  const argumentText = Array.isArray(argumentsList) ? argumentsList.join(" ") : String(argumentsList || "");

  await commandSession(
    session.id,
    {
      command,
      arguments: argumentText,
      ...(typeof options.model === "string" ? { model: options.model } : {}),
    },
    options,
  );

  return {
    ok: true,
    state: "sent",
    sessionId: session.id,
    title: session.title || null,
    waitedMs: waited?.waitedMs || 0,
    command,
    arguments: argumentText,
  };
}
