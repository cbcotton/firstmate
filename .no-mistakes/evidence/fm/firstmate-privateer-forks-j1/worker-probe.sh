#!/bin/sh
cd '/private/var/folders/3c/4w5d0nf515l_hw4zg0pcvq880000gn/T/fm-lab.GovhMX/main/forks/privateer'
out='/private/var/folders/3c/4w5d0nf515l_hw4zg0pcvq880000gn/T/fm-lab.GovhMX/main/forks/privateer/state/worker-probe.txt'
: > "$out"
for t in AGENTS.md CLAUDE.md CONTEXT.md opencode.json opencode.jsonc tui.json tui.jsonc .agents/skills/new/SKILL.md docs/new.md   .claude/skills/new/SKILL.md .opencode/opencode.json .opencode/opencode.jsonc .opencode/tui.json .opencode/tui.jsonc; do
  if ( mkdir -p "$(dirname "$t")" 2>/dev/null; echo tamper >> "$t" ) 2>/dev/null; then echo "WRITE-ALLOWED $t"; else echo "write-refused $t"; fi >> "$out"
done
for d in agent agents command commands mode modes plugin plugins skill skills tool tools; do
  if ( mkdir -p .opencode/$d && echo x > .opencode/$d/new.md ) 2>/dev/null; then echo "WRITE-ALLOWED .opencode/$d"; else echo "write-refused .opencode/$d"; fi >> "$out"
done
for t in AGENTS.md .agents docs .opencode .claude .claude/skills; do
  if mv "$t" "$t.aside" 2>/dev/null; then echo "MOVE-ALLOWED $t"; else echo "move-refused $t"; fi >> "$out"
done
if rm .claude/skills 2>/dev/null; then echo "RM-ALLOWED .claude/skills"; else echo "rm-refused .claude/skills"; fi >> "$out"
if echo x > .opencode/scratch && mkdir -p .opencode/node_modules/probe && echo x > .opencode/node_modules/probe/x; then echo "scratch-write-ok .opencode/scratch,.opencode/node_modules"; else echo "SCRATCH-REFUSED"; fi >> "$out" 2>&1
if echo x > state/probe-ok; then echo "state-write-ok"; else echo "STATE-REFUSED"; fi >> "$out" 2>&1
echo done >> "$out"
