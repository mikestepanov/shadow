import { getControllerStatus } from "./status.js";
import { sendPrompt } from "./send.js";
import { safeSendPrompt } from "./safe-send.js";
import { waitUntilIdle } from "./wait.js";

function parseArgs(argv) {
  const options = {};
  const rest = [];

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--session") {
      options.sessionId = argv[i + 1] || "";
      i += 1;
      continue;
    }
    if (arg === "--title") {
      options.title = argv[i + 1] || "";
      i += 1;
      continue;
    }
    rest.push(arg);
  }

  return { options, rest };
}

async function main() {
  const command = process.argv[2] || "status";
  const parsed = parseArgs(process.argv.slice(3));
  const options = parsed.options;

  if (command === "status") {
    const result = await getControllerStatus(options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "send") {
    const text = parsed.rest.join(" ");
    const result = await sendPrompt(text, options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "wait") {
    const result = await waitUntilIdle(options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "safe-send") {
    const text = parsed.rest.join(" ");
    const result = await safeSendPrompt(text, options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  console.error(`unknown command: ${command}`);
  process.exit(2);
}

await main();
