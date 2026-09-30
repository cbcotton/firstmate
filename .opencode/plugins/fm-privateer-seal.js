import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import {
  budgetMessage,
  callsFirstmateScript,
  REFUSAL_BUDGET,
  refusalLine,
  tmuxDecision,
} from "../../bin/fm-privateer-seal-policy.mjs";
import {
  classifyFirstmateOperationalInput,
  encodeFirstmateOperationalInput,
} from "./lib/fm-operational-input.js";

// The Privateer seal. In a home with config/privateer, `bin/fm-privateer.sh
// inside` answers once, at load, whether this OpenCode process runs inside the
// home's sealed session; in any other home it answers that there is no seal,
// or cannot run, and this plugin adds no hook at all.
//
// Outside the session, which is how the captain's own OpenCode, opened in the
// home, meets the seal: session.created injects that script's refusal once per
// session as operational input, and tool.execute.before throws it for every
// tool, so the model can only stop and hand back to the captain.
//
// Inside the session: tool.execute.before throws for a bash command that
// reaches another tmux server, and the refusal budget stops a model that keeps
// retrying firstmate scripts that refuse it. tool.execute.after counts
// consecutive refused bin/fm-* results per session; the one that spends the
// budget gets the budget message appended, every later bin/fm-* call throws it,
// and a captain message, one that is not Firstmate operational input, resets
// the count. bin/fm-privateer-seal-policy.mjs owns what each rule matches and
// says. docs/verification/local-sailors.md records the OpenCode hook behavior
// this relies on, and tests/fm-privateer-seal-live-e2e.test.sh refreshes it.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: -1, stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? -1, stderr }));
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
  const result = await new Promise((resolvePromise) => {
    const child = spawn("git", ["-C", anchor, "rev-parse", "--show-toplevel"], { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolvePromise(""));
    child.on("close", (code) => resolvePromise(code === 0 ? stdout.trim() : ""));
  });
  return result || resolvePath(anchor);
}

async function sealMode(root) {
  if (!root) return { mode: "off" };
  const result = await runProcess(`${root}/bin/fm-privateer.sh`, ["inside"]);
  if (result.code === 0) return { mode: "inside" };
  if (result.code === 1 && result.stderr.trim()) return { mode: "outside", reason: result.stderr.trim() };
  return { mode: "off" };
}

function outsideHooks(root, client, reason) {
  const told = new Set();
  return {
    event: async ({ event }) => {
      if (event.type !== "session.created") return;
      const sessionID = event.properties?.info?.id ?? event.properties?.sessionID;
      if (!sessionID || told.has(sessionID)) return;
      told.add(sessionID);
      try {
        const text = await encodeFirstmateOperationalInput(root, "privateer-seal", reason);
        await client.session.promptAsync({
          path: { id: sessionID },
          body: { parts: [{ type: "text", text }] },
        });
      } catch {
      }
    },
    "tool.execute.before": async () => {
      throw new Error(reason);
    },
  };
}

function insideHooks(root) {
  const budgets = new Map();
  return {
    "tool.execute.before": async (input, output) => {
      if (input?.tool !== "bash") return;
      const command = output?.args?.command;
      if (typeof command !== "string" || !command) return;
      const tmux = tmuxDecision(command);
      if (tmux) throw new Error(tmux);
      const budget = budgets.get(input.sessionID);
      if (budget && budget.refusals >= REFUSAL_BUDGET && callsFirstmateScript(command)) {
        throw new Error(budgetMessage(budget.last));
      }
    },
    "tool.execute.after": async (input, output) => {
      if (input?.tool !== "bash" || !callsFirstmateScript(input?.args?.command)) return;
      const line = refusalLine(output?.output);
      if (!line) {
        budgets.delete(input.sessionID);
        return;
      }
      const budget = budgets.get(input.sessionID) ?? { refusals: 0, last: "" };
      budget.refusals += 1;
      budget.last = line;
      budgets.set(input.sessionID, budget);
      if (budget.refusals === REFUSAL_BUDGET && typeof output.output === "string") {
        output.output = `${output.output}\n\n${budgetMessage(line)}`;
      }
    },
    "chat.message": async (input, output) => {
      if (!budgets.has(input?.sessionID)) return;
      const text = (output?.parts ?? []).find((part) => part?.type === "text")?.text ?? "";
      let kind = "";
      try {
        kind = await classifyFirstmateOperationalInput(root, text);
      } catch {
      }
      if (!kind) budgets.delete(input.sessionID);
    },
  };
}

export const FmPrivateerSeal = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  const seal = await sealMode(root);
  if (seal.mode === "outside") return outsideHooks(root, client, seal.reason);
  if (seal.mode === "inside") return insideHooks(root);
  return {};
};
