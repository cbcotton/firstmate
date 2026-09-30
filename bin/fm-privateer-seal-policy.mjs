// Policy for the Privateer seal plugin (.opencode/plugins/fm-privateer-seal.js)
// inside a sealed Privateer session: which shell commands reach a tmux server
// other than the session's own, and which firstmate-script results count
// toward the refusal budget.
//
// Inside the session every tmux command already talks to the session's own
// server, the one TMUX names, so a command reaches another server only by
// naming one: -L or -S among tmux's own options before its subcommand, or a
// TMUX changed for it (a TMUX= assignment, `unset TMUX`, `export TMUX=`, or an
// env wrapper that sets, unsets, or clears the environment). Such a command
// can type into, read, or pipe any same-user tmux server, so it is denied
// whatever its subcommand. The shell tokenizer and command-position analysis
// are imported from bin/fm-arm-command-policy.mjs, the sole owner of
// firstmate's shell classification; this policy never evaluates, expands, or
// runs any byte of the submitted command. Syntax that tokenizer cannot read is
// denied only when its raw text names tmux together with -L, -S, or TMUX.
//
// The refusal budget: a firstmate-script call is a command that runs a bin/fm-*
// script, in its command position or a shell's script argument, directly or in
// any program nested the way the tmux rule finds them; reading, listing, or
// searching the scripts is not a call. Syntax the tokenizer cannot read is a
// call when its raw text names a bin/fm-* script. Its result is a refusal when the first non-blank line of its
// output reads `error:` or `refused:`, in any case, optionally after one
// `<name>: ` prefix. REFUSAL_BUDGET such results in a row, with no other
// firstmate-script result and no captain message between them, spend the
// budget, and budgetMessage is what the plugin then tells the model.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

export const TMUX_REASON =
  "refused: inside the Privateer session, tmux reaches only this session's own server, so a tmux command that names another server with -L or -S, or changes TMUX, is blocked; steer a worker with bin/fm-send.sh, and ask the captain for anything outside this session";

export const REFUSAL_BUDGET = 3;

export function budgetMessage(lastRefusal) {
  return `refused: three refusals in a row: stop, report the last refusal to the captain, and wait; no firstmate script runs again until the captain answers (the last refusal: ${lastRefusal.slice(0, 400)})`;
}

// tmux's own options that take an argument (tmux 3.x: -c, -f, -L, -S, -T).
const TMUX_OPTIONS_WITH_ARGUMENT = new Set(["c", "f", "L", "S", "T"]);
const SHELLS = new Set(["sh", "bash", "zsh"]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function assignsTmux(word) {
  return /^TMUX=/.test(word.value);
}

// Whether tmux's own options, before its subcommand, name a server.
function namesServer(args) {
  for (let i = 0; i < args.length; i += 1) {
    const value = args[i].value;
    if (value === "--" || !value.startsWith("-") || value === "-") return false;
    for (let offset = 1; offset < value.length; offset += 1) {
      const option = value[offset];
      if (option === "L" || option === "S") return true;
      if (TMUX_OPTIONS_WITH_ARGUMENT.has(option)) {
        if (offset + 1 === value.length) i += 1;
        break;
      }
    }
  }
  return false;
}

// Whether an env wrapper before the command changes or clears TMUX.
function envChangesTmux(position) {
  if (!position.wrappers.includes("env")) return false;
  return position.words.slice(position.prefixAssignments, position.index).some((word) =>
    /TMUX/.test(word.value) || word.value === "-" || word.value === "--ignore-environment" || /^-[A-Za-z0-9]*i/.test(word.value));
}

function rawReachesAnotherServer(command) {
  const text = command.replace(/\\\r?\n/g, "");
  return /\btmux\b/.test(text) && (/(?:^|\s)-[A-Za-z0-9]*[LS]/.test(text) || /\bTMUX\b/.test(text));
}

// The programs a node runs besides its own command: groups, substitutions, an
// env -S payload, a shell's -c program or the heredoc or here-string it reads,
// and eval's words.
function nestedPrograms(tokens, position) {
  const programs = [...position.wrapperPayloads];
  for (const token of tokens) {
    if (token.type === "group") programs.push(token.content);
    if (token.type === "word") for (const substitution of token.subs) programs.push(substitution.content);
  }
  const name = basename(position.command?.value || "");
  const args = position.words.slice(position.index + 1);
  if (SHELLS.has(name)) {
    const flag = args.findIndex((word) => /^-[A-Za-z]*c[A-Za-z]*$/.test(word.value));
    if (flag !== -1 && args[flag + 1]) programs.push(args[flag + 1].value);
    tokens.forEach((token, index) => {
      if (token.type !== "redir" || token.fd !== 0) return;
      if (typeof token.heredoc === "string") programs.push(token.heredoc);
      if (token.value === "<<<" && tokens[index + 1]?.type === "word") programs.push(tokens[index + 1].value);
    });
  }
  if (name === "eval") programs.push(args.map((word) => word.value).join(" "));
  return programs;
}

function reachesAnotherServer(command, depth) {
  if (depth > 12) return rawReachesAnotherServer(command);
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return rawReachesAnotherServer(command);
  let tmuxChanged = false;
  for (const tokens of splitProgram(lexed.tokens).nodes) {
    const position = commandPosition(tokens);
    if (nestedPrograms(tokens, position).some((program) => reachesAnotherServer(program, depth + 1))) return true;
    const prefix = position.words.slice(0, position.prefixAssignments);
    const name = basename(position.command?.value || "");
    const args = position.words.slice(position.index + 1);
    if (!position.command && prefix.some(assignsTmux)) tmuxChanged = true;
    if (name === "unset" && args.some((word) => word.value === "TMUX")) tmuxChanged = true;
    if ((name === "export" || name === "declare" || name === "typeset") && args.some(assignsTmux)) tmuxChanged = true;
    if (name !== "tmux") continue;
    if (tmuxChanged || prefix.some(assignsTmux) || envChangesTmux(position) || namesServer(args)) return true;
  }
  return false;
}

// tmuxDecision <command>: "" to allow, or the refusal to throw.
export function tmuxDecision(command) {
  if (typeof command !== "string" || !command) return "";
  return reachesAnotherServer(command, 0) ? TMUX_REASON : "";
}

const FIRSTMATE_SCRIPT = /(?:^|[^A-Za-z0-9_.-])bin\/fm-[A-Za-z0-9_.-]+/;

function isFirstmateScript(word) {
  return Boolean(word) && /(?:^|\/)bin\/fm-[A-Za-z0-9_.-]+$/.test(word.value);
}

function runsFirstmateScript(command, depth) {
  if (depth > 12) return FIRSTMATE_SCRIPT.test(command);
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return FIRSTMATE_SCRIPT.test(command);
  for (const tokens of splitProgram(lexed.tokens).nodes) {
    const position = commandPosition(tokens);
    if (nestedPrograms(tokens, position).some((program) => runsFirstmateScript(program, depth + 1))) return true;
    if (isFirstmateScript(position.command)) return true;
    const args = position.words.slice(position.index + 1);
    if (SHELLS.has(basename(position.command?.value || "")) && isFirstmateScript(args.find((word) => !word.value.startsWith("-")))) return true;
  }
  return false;
}

export function callsFirstmateScript(command) {
  return typeof command === "string" && Boolean(command) && runsFirstmateScript(command, 0);
}

// refusalLine <output>: the refusal's first line, or "" when the output is not one.
export function refusalLine(output) {
  if (typeof output !== "string") return "";
  const line = output.split(/\r?\n/).find((candidate) => candidate.trim()) || "";
  return /^\s*(?:[A-Za-z0-9_.-]+:\s+)?(?:error|refused):/i.test(line) ? line.trim() : "";
}
