import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const adapterRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

// Cross-language adapter only. bin/fm-operational-input.sh owns the protocol,
// accepted kinds, marker bytes, and serialization grammar.
function runOperationalInput(root, args, content) {
  return new Promise((resolveResult, reject) => {
    const requested = `${root}/bin/fm-operational-input.sh`;
    const script = existsSync(requested)
      ? requested
      : `${adapterRoot}/bin/fm-operational-input.sh`;
    const invocation = process.platform === "win32"
      ? { command: "bash", args: [script, ...args] }
      : { command: script, args };
    const child = spawn(invocation.command, invocation.args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => resolveResult({ code, stdout, stderr }));
    child.stdin.end(content);
  });
}

export async function encodeFirstmateOperationalInput(root, kind, content) {
  const { code, stdout, stderr } = await runOperationalInput(root, ["encode", kind], content);
  if (code === 0 && stdout) return stdout;
  throw new Error(stderr.trim() || `operational-input encoder exited ${code ?? "unknown"}`);
}

// The kind of current or legacy operational input, or "" for any other text.
export async function classifyFirstmateOperationalInput(root, content) {
  const { code, stdout } = await runOperationalInput(root, ["classify"], content);
  return code === 0 ? stdout.trim() : "";
}
