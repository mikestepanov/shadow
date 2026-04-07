import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SRC_DIR = dirname(fileURLToPath(import.meta.url));

export const OPENCODE_DIR = resolve(SRC_DIR, "..");
export const REPO_ROOT = resolve(SRC_DIR, "..", "..");

export function resolveRepoPath(...segments) {
  return resolve(REPO_ROOT, ...segments);
}

export function resolveOpencodePath(...segments) {
  return resolve(OPENCODE_DIR, ...segments);
}
