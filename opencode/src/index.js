import { getControllerStatus } from "./status.js";
import { sendPrompt } from "./send.js";
import { waitUntilIdle } from "./wait.js";

async function main() {
  const command = process.argv[2] || "status";

  if (command === "status") {
    const result = await getControllerStatus();
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "send") {
    const text = process.argv.slice(3).join(" ");
    const result = await sendPrompt(text);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "wait") {
    const result = await waitUntilIdle();
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

    console.error(`unknown command: ${command}`);
    process.exit(2);
}

await main();
