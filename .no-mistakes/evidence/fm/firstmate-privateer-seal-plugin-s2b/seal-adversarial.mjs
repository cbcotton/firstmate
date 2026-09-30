import { FmPrivateerSeal } from "/Users/cotton/.no-mistakes/worktrees/e74e4e411ceb/01M3SM4PAPH6H1S5JPSDH70M3E/.opencode/plugins/fm-privateer-seal.js";
const hooks = await FmPrivateerSeal({ client: {}, directory: "/Users/cotton/.no-mistakes/worktrees/e74e4e411ceb/01M3SM4PAPH6H1S5JPSDH70M3E", worktree: "/Users/cotton/.no-mistakes/worktrees/e74e4e411ceb/01M3SM4PAPH6H1S5JPSDH70M3E" });
console.log("mode hooks:", Object.keys(hooks).join(","));
const cases = [
  ["tmux -L default send-keys -t fleet 'rm -rf x' Enter", true],
  ["tmux -S /tmp/tmux-501/default capture-pane -p", true],
  ["TMUX= tmux send-keys -t 0 hi", true],
  ["unset TMUX; tmux ls", true],
  ["env -u TMUX tmux ls", true],
  ["env -i PATH=/usr/bin tmux ls", true],
  ["bash -c 'tmux -L other ls'", true],
  ["echo $(tmux -Lx ls)", true],
  ["eval tmux -S /tmp/s ls", true],
  ["sh <<'EOF'\ntmux -L x ls\nEOF", true],
  ["/opt/homebrew/bin/tmux -uL other ls", true],
  ["export TMUX=/tmp/x,1,0; tmux ls", true],
  ["tmux ls", false],
  ["tmux send-keys -t worker 'hi' Enter", false],
  ["tmux new-window -c /tmp -n w", false],
  ["grep -n TMUX bin/fm-send.sh", false],
  ["ls -L /tmp", false],
];
let bad = 0;
for (const [cmd, deny] of cases) {
  let denied = false;
  try { await hooks["tool.execute.before"]({ tool: "bash", sessionID: "s" }, { args: { command: cmd } }); } catch { denied = true; }
  const ok = denied === deny; if (!ok) bad++;
  console.log(`${ok ? "ok  " : "FAIL"} ${denied ? "DENY " : "ALLOW"} ${JSON.stringify(cmd)}`);
}
// refusal budget
const s = "b";
const after = async (out) => { const o = { output: out }; await hooks["tool.execute.after"]({ tool: "bash", sessionID: s, args: { command: "bin/fm-spawn.sh x" } }, o); return o.output; };
await after("error: fm-spawn.sh refused: nope"); await after("refused: again");
const third = await after("fm-spawn: error: third");
console.log("third result carries budget msg:", /three refusals in a row/.test(third));
let blocked = false; try { await hooks["tool.execute.before"]({ tool: "bash", sessionID: s }, { args: { command: "bin/fm-status.sh" } }); } catch (e) { blocked = true; console.log("4th call:", e.message.slice(0, 90)); }
let readOk = true; try { await hooks["tool.execute.before"]({ tool: "bash", sessionID: s }, { args: { command: "cat bin/fm-status.sh" } }); } catch { readOk = false; }
console.log("4th fm call blocked:", blocked, "| reading script still allowed:", readOk);
process.exit(bad || !blocked || !readOk ? 1 : 0);
