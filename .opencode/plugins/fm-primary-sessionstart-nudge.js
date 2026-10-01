import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

// Run-tier session start for OpenCode (docs/sessionstart-nudge.md owns the
// tier and source table). session.created runs bin/fm-sessionstart-run.sh and
// injects the digest itself as the session's first turn, so the model never
// has to decide whether to run session start; session.compacted re-injects it
// with --source compact, because a compaction loses exactly that digest. The
// compacting hook is not used: text added there is summarized away, not kept.
// OpenCode saves the captain's first message only after its chat.message hook
// returns, so that hook waits for the digest: the model's first request then
// already holds the digest, where an injection that raced the message would
// land after the model had answered it. The digest is delivered as its own
// turn, after the captain's message in history but before any model call.
// Headless `opencode run` may exit before a queued turn, so delivery stays
// fail-open there. Any run that yields no digest falls back to the nudge
// wrapper, which stays silent wherever the run wrapper stood down.

const handledSessions = new Set();
const childSessions = new Set();
// Per session, the digest computation that chat.message waits on.
const ready = new Map();
const DELIVERY_BYTES = 512 * 1024;
const RUN_TIMEOUT_MS = 180000;
const TRUNCATED_MARKER =
  "\n\nOPENCODE SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. " +
  "Treat omitted context as unread and inspect the named files directly before acting on it.";
let tookStartup = false;

function runProcess(command, args, { limit = Infinity, timeoutMs = 0 } = {}) {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    const chunks = [];
    let retained = 0;
    let truncated = false;
    let timer = null;
    child.stdout.on("data", (chunk) => {
      const room = limit - retained;
      if (room <= 0) {
        truncated = true;
        return;
      }
      const kept = chunk.length <= room ? chunk : chunk.subarray(0, room);
      chunks.push(kept);
      retained += kept.length;
      if (kept.length !== chunk.length) truncated = true;
    });
    if (timeoutMs > 0) {
      timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
      timer.unref();
    }
    const settle = (code) => {
      if (timer) clearTimeout(timer);
      resolveResult({ code, stdout: Buffer.concat(chunks).toString("utf8"), truncated });
    };
    child.on("error", () => settle(0));
    child.on("close", (code) => settle(code ?? 0));
  });
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

async function digestInput(root, source) {
  const result = await runProcess(`${root}/bin/fm-sessionstart-run.sh`, ["--source", source], {
    limit: DELIVERY_BYTES,
    timeoutMs: RUN_TIMEOUT_MS,
  });
  const digest = result.code === 0 ? result.stdout.trim() : "";
  if (!digest) return "";
  return encodeFirstmateOperationalInput(root, "session-start", result.truncated ? `${digest}${TRUNCATED_MARKER}` : digest);
}

async function nudgeInput(root) {
  const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
  return result.code === 0 ? result.stdout.trim() : "";
}

async function deliver(client, sessionID, text) {
  try {
    await client.session.promptAsync({
      path: { id: sessionID },
      body: { parts: [{ type: "text", text }] },
    });
  } catch {
  }
}

async function compute(root, source) {
  let text = "";
  try {
    text = await digestInput(root, source);
  } catch {
  }
  if (!text && source !== "compact") text = await nudgeInput(root);
  return text;
}

export const FmPrimarySessionstartNudge = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    "chat.message": async (input) => {
      const sessionID = input?.sessionID;
      if (!sessionID) return;
      // The session.created event may still be in flight when the message is
      // submitted, so give it one turn to register before deciding.
      if (!ready.has(sessionID)) await new Promise((done) => setTimeout(done, 0));
      await ready.get(sessionID);
    },
    event: async ({ event }) => {
      if (!root) return;
      if (event.type === "session.created") {
        const info = event.properties?.info;
        const sessionID = info?.id ?? event.properties?.sessionID;
        if (!sessionID) return;
        if (info?.parentID) {
          childSessions.add(sessionID);
          return;
        }
        if (handledSessions.has(sessionID)) return;
        handledSessions.add(sessionID);
        // Only this process's first session is a true start; a later one has
        // the helm already and lost only its context, like a clear.
        const source = tookStartup ? "clear" : "startup";
        tookStartup = true;
        const computing = compute(root, source);
        ready.set(sessionID, computing);
        const text = await computing;
        if (text) await deliver(client, sessionID, text);
        return;
      }
      if (event.type === "session.compacted") {
        const sessionID = event.properties?.sessionID;
        if (!sessionID || childSessions.has(sessionID)) return;
        const text = await compute(root, "compact");
        if (text) await deliver(client, sessionID, text);
      }
    },
  };
};
