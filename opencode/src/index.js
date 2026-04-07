import { getControllerStatus } from "./status.js";
import { editCronJob, formatCronList, listCronJobs, runCronJob, setCronEnabled } from "./cron.js";
import { runAutoCycle } from "./auto-mode.js";
import { enqueueLane, runQueue } from "./queue.js";
import { runLane } from "./lane-run.js";
import { listLaneKeys } from "./lanes.js";
import { ensureManualSession, runManualPing } from "./session.js";
import { pollTelegramOnce } from "./telegram.js";
import { sendPrompt } from "./send.js";
import { safeRunCommand } from "./safe-command.js";
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
    if (arg === "--json") {
      options.json = true;
      continue;
    }
    if (arg === "--all") {
      options.all = true;
      continue;
    }
    if (arg === "--every") {
      options.every = argv[i + 1] || "";
      i += 1;
      continue;
    }
    if (arg === "--model") {
      options.model = argv[i + 1] || "";
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

  if (command === "safe-command") {
    const [commandName, ...argumentsList] = parsed.rest;
    const result = await safeRunCommand(commandName || "", argumentsList, options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "lane-run") {
    const [mode, repo] = parsed.rest;
    const result = await runLane(mode || "", repo || "", options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "ensure-session") {
    const [repo] = parsed.rest;
    const result = await ensureManualSession(repo || "");
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "manual-ping") {
    const [repo] = parsed.rest;
    const result = await runManualPing(repo || "");
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "telegram-poll") {
    const result = await pollTelegramOnce();
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "lanes") {
    process.stdout.write(`${JSON.stringify(listLaneKeys(), null, 2)}\n`);
    process.exit(0);
  }

  if (command === "enqueue-lane") {
    const [mode, repo] = parsed.rest;
    const result = await enqueueLane(mode || "", repo || "", options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "run-queue") {
    const result = await runQueue(options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "auto-cycle") {
    const [repo] = parsed.rest;
    const result = await runAutoCycle(repo || "", options);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    process.exit(result.ok ? 0 : 1);
  }

  if (command === "cron") {
    const [subcommand, identifier] = parsed.rest;

    if (subcommand === "list") {
      const result = await listCronJobs(options);
      if (options.json) {
        process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      } else {
        process.stdout.write(`${formatCronList(result)}\n`);
      }
      process.exit(result.ok ? 0 : 1);
    }

    if (subcommand === "enable") {
      const result = await setCronEnabled(identifier || "", true, options);
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      process.exit(result.ok ? 0 : 1);
    }

    if (subcommand === "disable") {
      const result = await setCronEnabled(identifier || "", false, options);
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      process.exit(result.ok ? 0 : 1);
    }

    if (subcommand === "edit") {
      const result = await editCronJob(
        identifier || "",
        {
          ...(options.every ? { every: options.every } : {}),
          ...(options.model ? { model: options.model } : {}),
        },
        options,
      );
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      process.exit(result.ok ? 0 : 1);
    }

    if (subcommand === "run") {
      const result = await runCronJob(identifier || "", options);
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      process.exit(result.ok ? 0 : 1);
    }

    console.error(`unknown cron subcommand: ${subcommand || ""}`);
    process.exit(2);
  }

  console.error(`unknown command: ${command}`);
  process.exit(2);
}

await main();
