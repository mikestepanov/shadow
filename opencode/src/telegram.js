import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { spawn } from "node:child_process";
import { resolveOpencodeVarPath, resolveRepoPath } from "./paths.js";

const OPENCODE_BIN = "/run/current-system/sw/bin/opencode";
const TELEGRAM_STATE_PATH = resolveOpencodeVarPath("telegram-bridge.json");
const DEFAULT_BASE_URL = process.env.OPENCODE_BASE_URL || "http://127.0.0.1:4096";
const DEFAULT_CHAT_ID = process.env.TELEGRAM_CHAT_ID || "780599199";

function parseJsonLines(raw) {
  return String(raw || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

async function ensureParent(filePath) {
  await mkdir(dirname(filePath), { recursive: true });
}

async function loadState() {
  try {
    const raw = await readFile(TELEGRAM_STATE_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (error) {
    if (error && typeof error === "object" && error.code === "ENOENT") {
      return {};
    }
    throw error;
  }
}

async function saveState(state) {
  await ensureParent(TELEGRAM_STATE_PATH);
  await writeFile(TELEGRAM_STATE_PATH, `${JSON.stringify(state, null, 2)}\n`, "utf8");
}

function getToken() {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (typeof token !== "string" || token.trim() === "") {
    throw new Error("TELEGRAM_BOT_TOKEN is not set");
  }
  return token;
}

function getAllowedChatId() {
  return String(DEFAULT_CHAT_ID);
}

async function telegramApi(method, params) {
  const token = getToken();
  const body = new URLSearchParams();
  for (const [key, value] of Object.entries(params || {})) {
    if (value !== undefined && value !== null) {
      body.set(key, String(value));
    }
  }

  const response = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const payload = await response.json();
  if (!response.ok || payload?.ok !== true) {
    throw new Error(payload?.description || `Telegram ${method} failed`);
  }
  return payload.result;
}

async function getUpdates(offset) {
  return telegramApi("getUpdates", {
    timeout: 1,
    allowed_updates: JSON.stringify(["message"]),
    ...(typeof offset === "number" ? { offset } : {}),
  });
}

async function sendMessage(chatId, text, replyToMessageId) {
  return telegramApi("sendMessage", {
    chat_id: chatId,
    text,
    ...(replyToMessageId ? { reply_parameters: JSON.stringify({ message_id: replyToMessageId }) } : {}),
  });
}

function extractReplyText(events) {
  const parts = events
    .filter((event) => event?.type === "text" && typeof event?.part?.text === "string")
    .map((event) => event.part.text.trim())
    .filter(Boolean);
  return parts.join("\n\n").trim();
}

async function runOpencodeReply(prompt) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      OPENCODE_BIN,
      [
        "run",
        "--attach",
        DEFAULT_BASE_URL,
        "--title",
        "telegram",
        "--dir",
        resolveRepoPath(),
        "--continue",
        "--format",
        "json",
        prompt,
      ],
      {
        cwd: resolveRepoPath(),
        env: process.env,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );

    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
    }, 10 * 60 * 1000);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });

    child.on("close", (code, signal) => {
      clearTimeout(timer);
      const events = parseJsonLines(stdout);
      const text = extractReplyText(events);
      if (text) {
        resolve({ ok: true, text, code, signal });
        return;
      }
      reject(new Error(stderr.trim() || `OpenCode telegram reply failed (${code ?? signal ?? "unknown"})`));
    });
  });
}

function incomingPrompt(message) {
  const text = String(message?.text || "").trim();
  const fromName = [message?.from?.first_name, message?.from?.last_name].filter(Boolean).join(" ").trim() || "Mikhail";
  return [
    `Telegram message from ${fromName}.`,
    `Reply directly and helpfully to this message. Keep it concise unless detail is needed.`,
    text,
  ].join("\n\n");
}

function isAllowedMessage(update) {
  const message = update?.message;
  if (!message || typeof message !== "object") {
    return false;
  }
  if (message?.from?.is_bot) {
    return false;
  }
  if (String(message?.chat?.id || "") !== getAllowedChatId()) {
    return false;
  }
  return typeof message?.text === "string" && message.text.trim() !== "";
}

export async function pollTelegramOnce() {
  const state = await loadState();
  const updates = await getUpdates(typeof state.nextUpdateId === "number" ? state.nextUpdateId : undefined);

  let handled = 0;
  let replied = 0;
  let lastUpdateId = typeof state.nextUpdateId === "number" ? state.nextUpdateId - 1 : null;
  const results = [];

  for (const update of updates) {
    if (typeof update?.update_id === "number") {
      lastUpdateId = update.update_id;
    }

    if (!isAllowedMessage(update)) {
      continue;
    }

    handled += 1;
    const message = update.message;
    try {
      const reply = await runOpencodeReply(incomingPrompt(message));
      const sent = await sendMessage(message.chat.id, reply.text, message.message_id);
      replied += 1;
      results.push({
        updateId: update.update_id,
        chatId: message.chat.id,
        messageId: message.message_id,
        replyMessageId: sent?.message_id,
        ok: true,
      });
    } catch (error) {
      const fallback = `Telegram bridge error: ${error instanceof Error ? error.message : String(error)}`;
      await sendMessage(message.chat.id, fallback, message.message_id).catch(() => {});
      results.push({
        updateId: update.update_id,
        chatId: message.chat.id,
        messageId: message.message_id,
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const nextUpdateId = typeof lastUpdateId === "number" ? lastUpdateId + 1 : state.nextUpdateId;
  await saveState({
    nextUpdateId,
    lastPollAt: Date.now(),
  });

  return {
    ok: true,
    updatesSeen: updates.length,
    handled,
    replied,
    nextUpdateId,
    results,
  };
}
