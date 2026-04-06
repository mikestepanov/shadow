import { getControllerStatus } from "./status.js";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function waitUntilIdle(options = {}) {
  const timeoutMs = Number(options.timeoutMs || 30000);
  const intervalMs = Number(options.intervalMs || 1000);
  const startedAt = Date.now();

  while (Date.now() - startedAt <= timeoutMs) {
    const status = await getControllerStatus(options);
    if (!status.ok) {
      return status;
    }
    if (status.state === "idle") {
      return {
        ...status,
        waitedMs: Date.now() - startedAt,
      };
    }
    await sleep(intervalMs);
  }

  return {
    ok: false,
    state: "unknown",
    error: `Timed out waiting for idle after ${timeoutMs}ms`,
    waitedMs: timeoutMs,
  };
}
