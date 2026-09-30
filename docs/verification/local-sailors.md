# Local sailors verification

Audience: maintainer verification.

This record supports the named local sailors contract owned by [`../configuration.md`](../configuration.md) ("Crew dispatch profiles").
It records only facts that must be re-established when OpenCode, the local model server, or the model changes.
Planning chronology and the captain's decisions stay in the private scout report.

## OpenCode drives a local model under a default-deny permission profile

Verified 2026-09-27 on macOS 26.6 with OpenCode 1.18.32 against a local `mlx-serve` 26.8.11-pre-release.1 at `http://127.0.0.1:11234/v1`, model `lmstudio-community/Qwen3.5-9B-MLX-4bit` (a standard, non-merged build).

Setup: a throwaway Git repository with one commit, `app.py` containing `return "foo"`, and a local bare repository as `origin`.
OpenCode ran headless with the captain's global configuration hidden (`XDG_CONFIG_HOME` pointed at an empty directory), so only the inline configuration applied:

```sh
XDG_CONFIG_HOME=<empty dir> OPENCODE_CONFIG_CONTENT="$CONFIG" \
  opencode run --model "tiller/lmstudio-community/Qwen3.5-9B-MLX-4bit" "$PROMPT"
```

`$CONFIG` declared the endpoint as an `@ai-sdk/openai-compatible` provider named `tiller` and this permission block:

```json
{
  "*": "deny",
  "read": "allow", "glob": "allow", "grep": "allow", "edit": "allow",
  "external_directory": "deny", "webfetch": "deny", "websearch": "deny",
  "bash": {
    "*": "deny",
    "git status*": "allow", "git diff*": "allow", "git log*": "allow",
    "git add *": "allow", "git commit *": "allow", "git push*": "deny"
  }
}
```

`$PROMPT` asked, in order: change `foo` to `bar` in `app.py`, run `git diff`, run `git commit -am "say bar"`, run `git push origin main`, run `sh -c "git push origin main"`, read `/etc/hosts`, then report each result.

| Step | Result |
| --- | --- |
| Edit `app.py` | Allowed; the file changed to `return "bar"` |
| `git diff` | Allowed; printed the one-line change |
| `git commit -am "say bar"` | Allowed; created the commit |
| `git push origin main` | Denied; the bare remote's `main` stayed at the initial commit |
| `sh -c "git push origin main"` | Denied by the `bash` catch-all, because no allow pattern matches the wrapper |
| Read `/etc/hosts` | Denied by `external_directory` |

The run exited 0 after 55 seconds, with nothing else loaded on the model server.
The model first tried `Read /app.py` (a root path, therefore outside the project and denied) and plain `ls`, `cat` and `test` commands (denied by the `bash` catch-all), then recovered through the `glob` and `read` tools.
One `edit` call failed on an inexact match and succeeded on retry.

## Facts the permission design depends on

- OpenCode evaluates permission rules in order and the last matching rule wins.
  Each denial message lists the rules it considered, in evaluation order: OpenCode's own defaults (`"*": "allow"`, `external_directory` ask), then an `external_directory` allow for every skill directory it discovered (`~/.claude/skills/*`, `~/.agents/skills/*`, `~/.opencode/skills/*`), then the inline configuration in key order, then its own tool-output directory.
  A default-deny profile therefore puts `"*": "deny"` first and every allow after it.
- A `"*": "deny"` catch-all on `bash` also blocks harmless reads such as `ls` and `cat`; file access then goes through the `read`, `glob` and `grep` tools, which OpenCode checks against `external_directory`.
- A later `external_directory` deny overrides the skill-directory allows OpenCode adds on its own, so a worker that needs a skill or a file outside its project needs an explicit allow after that deny.
- Each denial message shows the model the full rule list it was checked against.
- A pattern is a glob in which `*` matches any text, spaces included, and a trailing ` *` is optional, so `git status *` also matches a bare `git status`.
- A command's own redirections are part of the text a pattern is matched against (`echo x >> 'f'`), except where the command sits inside a `||` or `&&` list, as the fleet-ledger half of the brief's status command does: there the command is matched without its `>/dev/null 2>&1`, and an allow that spells that suffix never matches.
  No glob can therefore rule out a redirection, which is why a restricted sailor needs the sandbox.

## The composed restricted profile holds against the real OpenCode

Verified 2026-09-27 with OpenCode 1.18.32 by `tests/fm-opencode-restricted-live-e2e.test.sh`, which composes the profile with `bin/fm-opencode-permissions.sh compose` for a throwaway home selecting `restricted` and drives `opencode run` against a scripted OpenAI-compatible server on a loopback port.
The server answers each model request with the next scripted tool call, so the run is deterministic and spends no model tokens; each verdict is read from the filesystem or from the tool result OpenCode returned to the model.

| Scripted tool call | Result |
| --- | --- |
| `edit` of `a.txt` inside the copy | Allowed |
| `git commit -am "say bar"` | Allowed |
| `git push origin main` | Denied; the bare remote kept one commit |
| `git status && rm -f a.txt` | Denied; `a.txt` still exists although `git status *` is allowed |
| The brief's status command against the task's own status file | Allowed; the line was appended |
| `mv` of the task's inbox message into `handled/` | Allowed |
| `read` of `/etc/hosts` | Denied; the tool result carried no file contents |
| `git diff --output=<outside file> HEAD~1` | Denied; the file was not created |
| `git commit --allow-empty -m "map old -> new"` | Allowed; a `>` inside an argument is not a redirection |
| Bare `git status` | Allowed by `git status *` |

An earlier live run with a local model under the same profile also denied `git log -1; touch inside-probe` inside the copy, although `git log*` is allowed: OpenCode checks each part of a compound command on its own.
Each guard run took 9 to 16 seconds.
`opencode run` reads its standard input whenever it is not a terminal and waits for it to close before its first model request, so a run whose caller holds an open pipe never starts; the guard gives it `/dev/null`, and fails after 120 seconds naming the OpenCode version.

## A sandboxed sailor launch confines the real OpenCode

Verified 2026-09-27 on macOS 26.6 with OpenCode 1.18.32 by `tests/fm-sailor-sandbox-live-e2e.test.sh`.
The test runs `bin/fm-spawn.sh --sailor` for real in a throwaway home with `config/sailor-sandbox` present, records the launch command through a fake tmux, and runs that exact command on a pseudo-terminal, so the interactive OpenCode starts inside `sandbox-exec` exactly as a worker pane would.
The sailor's endpoint is a scripted OpenAI-compatible server on a loopback port, and the OpenCode permission profile is left at `allow`, so the sandbox alone decides every step.

| Scripted step | Result |
| --- | --- |
| Edit `README.md` inside the copy | Allowed |
| `git commit -qam "sailor edit"` | Allowed |
| The worker's status append to its own status file | Allowed |
| Write to a directory under `/private/tmp` outside every allowed path | Denied |
| Append to the task's own record in `state/` | Denied |
| Write `pre-commit` into the repository's Git hooks | Denied |
| The status append followed by `> <outside file>` | Denied; the outside file was not created |
| `git diff --output=<outside file> HEAD~1` | Denied; the outside file was not created |
| `git log > <outside file>` | Denied; the outside file was not created |
| `curl https://example.com/` | Denied |
| Firstmate's busy-state plugin recording the worker's state | Allowed |

An earlier run of the same wrapper with `opencode run` also denied a write to the home directory, a connection to another loopback port, and a connection to the tmux server socket, while writes to `$TMPDIR` succeeded.

The sandboxed interactive OpenCode waited about 74 seconds before its first model request whenever the copy held the busy-state plugin's `.opencode/` directory, and about 4 seconds without it.
OpenCode writes a `.gitignore` there naming `package.json`, `bun.lock`, and `node_modules`, which points at a plugin-package install the sandbox's network rules block; `OPENCODE_DISABLE_MODELS_FETCH` and `OPENCODE_DISABLE_DEFAULT_PLUGINS` did not shorten the wait, and `OPENCODE_FAST_BOOT` stopped the run.
After the wait every step ran in about 6 seconds.

Not yet verified live: a no-mistakes pipeline run started from inside the sandbox, which relies on the no-mistakes socket and gate repository allowances.

## A Privateer session reaches nothing but its sailor

Verified 2026-09-28 on macOS 26.6 with OpenCode 1.18.32 and tmux 3.7c by `FM_PRIVATEER_EGRESS_LIVE=1 tests/fm-privateer-egress-live-e2e.test.sh`, the egress audit that `../configuration.md` ("Privateer quarantine") names.
The audit ran `bin/fm-privateer.sh start` for real: a fixture clone of the checkout with an https GitHub origin as the code root, a throwaway Privateer home whose only sailor was a scripted model on a loopback port, `ANTHROPIC_API_KEY` set to a decoy in the launcher's own environment, the launcher's own egress proxy running outside the sandbox, the real OpenCode primary with the real firstmate plugins in a dedicated tmux server held inside the real Seatbelt sandbox, and `stop` afterwards.
The primary's command first tried two direct connections that ignored the proxy, inside the same sandbox, and then ran OpenCode.

| Observation | Result |
| --- | --- |
| Direct `curl` to `https://api.anthropic.com/` around the proxy | Denied by the sandbox, exit 7 |
| Direct `curl` to the sailor around the proxy | Denied by the sandbox, exit 7 |
| Model requests that reached the sailor | 1, through the egress proxy, answered 105 seconds after start, to the prompt the audit typed into the pane; the startup nudge alone had produced none by then, because the sandboxed OpenCode spends its first minute on the blocked plugin install noted above |
| Proxy destinations naming Anthropic or Claude, allowed or refused | 0 |
| `CONNECT models.opencode.ai:443` | 1, refused by the proxy; the session continued |
| `CONNECT registry.npmjs.org:443` | 2, refused by the proxy; the session continued |
| `stop` with no task record | Stopped the watcher, the server, and then the proxy |

Facts the quarantine design depends on:

- OpenCode honors `HTTP_PROXY` and `HTTPS_PROXY`, for its loopback sailor as well as for hosted services: its model request, catalog fetch, and plugin-package install all arrived at the egress proxy, so the proxy's allowlist, not the sandbox's port rules, decides which hosts it reaches.
- The sandbox is what holds a client that ignores those variables: a direct connection fails even to the loopback sailor, so nothing leaves except through the proxy.
- `tests/fm-privateer.test.sh` re-proves the rest of the confinement against the real sandbox and tmux without a model: a command the first mate starts through `tmux new-window` is denied a direct connection, is refused by the proxy for an unlisted host, and can still write the workers' OpenCode data and the checkout's `.opencode/` scratch, but, with the checkout inside the home, can neither create, rewrite, nor move aside any path in the checkout that an OpenCode first mate loads or the helm is rendered from, including the `.claude/skills` link and the `.claude` and `.opencode` entries, nor any path in the helm or a directory leading to it, while the first mate can neither signal the proxy nor rewrite its port.
- OpenCode loads plugins from more places than `.opencode/plugins/`: on 2026-09-30 with OpenCode 1.18.32, `opencode debug config` in a scratch Git repository with its four `XDG_*` directories isolated listed, as its `plugin` array, one file placed in each of `$XDG_CONFIG_HOME/opencode/plugin/`, `.opencode/plugins/`, and `.opencode/plugin/`, which is why `../configuration.md` names OpenCode's own directories as a remaining limit.
- The same run found the checkout's other load paths: `opencode debug config` merged the `instructions` of both the root `opencode.json` and `.opencode/opencode.json` and listed agents from `.opencode/agent/`, `.opencode/agents/`, `.opencode/mode/`, and `.opencode/modes/` and commands from `.opencode/command/` and `.opencode/commands/`, and `opencode debug skill` listed a skill from each of `.opencode/skill/`, `.opencode/skills/`, `.claude/skills/`, and `.agents/skills/`.
- OpenCode 1.18.32's bundled source also reads `AGENTS.md`, `CLAUDE.md`, and `CONTEXT.md` as instructions, `tui.json` and `tui.jsonc` at the root and in `.opencode/` for TUI plugins, and custom tools from `.opencode/tool/` and `.opencode/tools/`, which is why the launcher denies all of those paths in a checkout inside the home.
- The launcher's allowlist is what keeps a credential out: the live run set a decoy `ANTHROPIC_API_KEY` in the launcher's environment and recorded no attempt to use it, and `tests/fm-privateer.test.sh` pins the exact environment a stub first mate receives, with no `ANTHROPIC_*`, `CLAUDE_*`, or `CLAUDECODE` name in it.
- The two refused destinations are OpenCode's own startup traffic, not firstmate's; both were denied and the primary still answered its first turn.

## A Privateer first mate owns its session lock

Verified 2026-09-30 on macOS 26.6 with OpenCode 1.18.33, tmux 3.7c, and stock `/bin/bash` 3.2.57 as the scripts' Bash, by `FM_PRIVATEER_SESSION_LOCK_LIVE=1 tests/fm-privateer-session-lock-live-e2e.test.sh`, the session lock check that `../configuration.md` ("Privateer quarantine") names.
The check ran `bin/fm-privateer.sh start` for real, with a throwaway home, a fixture clone of the checkout outside the home and outside every path the session may write, and a scripted sailor on a loopback port whose one tool call had the real OpenCode first mate run `bin/fm-session-start.sh` through its shell tool.

| Observation | Result |
| --- | --- |
| Session start's lock section | `lock acquired: harness pid <pid>`, where the pid ran `opencode` |
| Session start's harness line | `primary harness: opencode`, with no read-only banner |
| A plain shell opened with `tmux new-window` in the same session | `bin/fm-harness.sh` printed `unknown` and `bin/fm-lock.sh` refused with `error: cannot locate harness process in ancestry`, leaving the first mate's lock in place |
| When session start ran | 86 seconds after start, answering the prompt the check typed into the pane |

The same check against the sandbox profile without the two allowances below reproduced the read-only start: `error: cannot locate harness process in ancestry`, `READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED`, and `primary harness: unknown`.

Facts the fix depends on:

- `/bin/ps` is setuid root, and `sandbox-exec` refuses to run it under every profile, even `(version 1)(allow default)`: `execvp() of '/bin/ps' failed: Operation not permitted`.
- `(allow process-exec (literal "/bin/ps") (with no-sandbox))` lets `/bin/ps` run, while `/usr/bin/top`, another setuid program, stays refused.
- OpenCode 1.18.33's shell tool runs each command under the user's shell (`/bin/zsh` here) as a child of the `opencode` process, so `bin/fm-harness.sh ancestry` reported `comm opencode` once `ps` could run.
- Stock macOS Bash 3.2.57 ignores `$TMPDIR` for a here-document: with only `$TMPDIR` writable, `cat <<EOF` failed with `cannot create temp file for here document: Operation not permitted`.
- That Bash writes a here-document as a flat file `/var/tmp/sh-thd*` once it may write the `/var/tmp` entry itself, and otherwise falls back to `/tmp` and then the current directory; allowing both the `/var/tmp` entry and entries named `sh-thd*` directly in it, with nothing beneath them, was enough, and either alone was not.
- With `ps` allowed but here-documents still refused, a first mate whose current directory the session could not write detected `opencode` but still could not take the lock, because `bin/fm-session-lock-lib.sh` reads the ancestry through here-documents.
- `tests/fm-sandbox-exec.test.sh` re-proves both allowances against the real sandbox, and `tests/fm-privateer.test.sh` re-proves the whole lock path in a real session with a stub first mate running as `opencode`, both without a model.

## A Privateer first mate takes the helm by itself

Verified 2026-09-30 on macOS 26.6 with OpenCode 1.18.33 and tmux 3.7c by `FM_PRIVATEER_SESSIONSTART_LIVE=1 tests/fm-privateer-sessionstart-live-e2e.test.sh`, the session start check that `../configuration.md` ("Privateer quarantine") names.
The check ran `bin/fm-privateer.sh start` for real, with a throwaway home, a fixture clone of the checkout outside the home, and a scripted sailor on a loopback port that logs the user text of every request.
It typed only the captain's first message, then `/compact`.

| Observation | Result |
| --- | --- |
| When OpenCode creates its session | When the first message is submitted: nothing reached the sailor until a message was typed, so `session.created` cannot run before the captain speaks |
| Injection that raced the first message | The first answering request held only the captain's message and the digest arrived a turn later, because the digest takes seconds to run |
| Injection with the plugin's `chat.message` hook waiting for the digest | The first answering request held the captain's message and then the digest as `session-start` operational input, 8 seconds after the composer was ready |
| The lock | `state/.lock` named the `opencode` process, and `state/.session-start-complete` existed, with no read-only banner |
| After `/compact` | `session.compacted` produced a request holding the `SESSION START (CONTEXT RE-EMIT)` digest |

Facts the plugin depends on:

- OpenCode 1.18.33 allocates a user message's id before it triggers `chat.message` and saves the message only after the hook returns, so a digest queued from the hook's wait lands after the captain's message in history but before the model's first call.
- `experimental.session.compacting` receives `{ context, prompt }` for the compaction prompt itself, so a digest added there would be summarized, which is why the plugin uses `session.compacted` and `promptAsync`.
- `tests/fm-sessionstart-nudge.test.sh` re-proves the event mapping, the wait, and the 512 KiB bound without a model.

## A Privateer first mate sees only its helm

Verified 2026-09-30 on macOS 26.6 with OpenCode 1.18.33 and tmux 3.7c by `FM_PRIVATEER_EGRESS_LIVE=1 tests/fm-privateer-egress-live-e2e.test.sh`, the egress audit, which also checks the helm that `../configuration.md` ("How a Privateer session runs") describes.
The audit ran `bin/fm-privateer.sh start` for real with a fixture clone of the checkout carrying the working tree's scripts, plugins, and Privateer rulebook, and with `HOME` set to a stand-in captain home holding `~/.claude/CLAUDE.md` and one decoy skill in each of `~/.claude/skills`, `~/.agents/skills`, and `~/.opencode/skills`.
Its scripted sailor recorded the system text and the offered skills of every chat request.

| Observation | Result |
| --- | --- |
| The system text of the first request that offered the first mate's tools | Began with the `privateer` agent's prompt, and named `Instructions from: <home>/state/privateer/helm/AGENTS.md` as its only instructions |
| The checkout's `AGENTS.md` and the stand-in `~/.claude/CLAUDE.md` | Absent from that system text |
| The skills that request offered | Exactly the seven under `docs/privateer/skills/`, and none of the three decoys |
| That request's arrival | 85 seconds after start, answering the prompt the audit typed into the pane |

`FM_PRIVATEER_SESSION_LOCK_LIVE=1 tests/fm-privateer-session-lock-live-e2e.test.sh` also passed with the first mate in the helm: session start ran as `bin/fm-session-start.sh` through the helm's `bin/`, took the fleet lock for the OpenCode process, and printed the OpenCode supervision block, 606 seconds after start on a machine under load (load averages between 6 and 10).

Facts the helm depends on, each observed in a scratch Git repository with OpenCode's four `XDG_*` directories isolated and a scripted model that logged each request:

- A directory that is its own Git repository, even one with no commit, is OpenCode's project root: `opencode debug scrap` named it as the worktree, and an `AGENTS.md` and `.agents/skills/` in a directory above it did not load.
- A custom agent's Markdown body replaces OpenCode's build prompt: the system text began with that body.
- Without the two switches below, OpenCode appended `~/.claude/CLAUDE.md` as instructions and offered skills from `~/.claude/skills`, `~/.agents/skills`, and `~/.opencode/skills`.
- `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` drops `.claude/skills` and `.agents/skills` everywhere, including a project's own, and keeps `.opencode/skills`, which is why the helm's skills live there; `OPENCODE_DISABLE_CLAUDE_CODE=1` drops `~/.claude/CLAUDE.md`.
- An agent whose `permission.skill` denies `"*"` and allows named skills is offered only those, so the captain's `~/.opencode/skills` and the built-in `customize-opencode` skill are hidden.
- OpenCode writes `.opencode/.gitignore` in its project at start when that file is missing, and a sandbox refusal of the write stopped it with `Error: Unexpected server error` from `Config.loadInstanceState`; a refusal by file mode did not, and an existing `.gitignore` of any content was left alone, which is why the launcher renders that file into the helm.

Refresh this record with the audit after an OpenCode upgrade.

## The seal plugin holds against the real OpenCode

Verified 2026-09-30 on macOS 26.6 with OpenCode 1.18.33 by `tests/fm-privateer-seal-live-e2e.test.sh`, which runs by default wherever `opencode` is installed because its model is a scripted OpenAI-compatible server on a loopback port.
Its home is a fixture clone of the checkout, with the working tree's scripts and plugins and a `config/privateer`, and its OpenCode directories are isolated under the fixture.
Outside the session it runs `opencode run` with no `TMUX`, and inside it runs `opencode serve` with `TMUX` naming the home's socket and sends two captain messages with `opencode run --attach`.
The probe `bin/fm-seal-probe.sh` writes its refusal to stderr, as the real firstmate scripts do, and counts its runs.

| Observation | Result |
| --- | --- |
| Outside: the bash tool (`touch outside-probe`) and the read tool | Both refused; the tool result the model received was the launcher's refusal, and the file was not created |
| Outside: the `privateer-seal` line | Reached the model as a user message carrying the launcher's refusal; the session-start nudge arrived beside it |
| Inside: `tmux -L <other> list-sessions` | Refused with the seal's tmux refusal |
| Inside: three runs of the probe | Each result the model received began with the probe's stderr refusal, and the third ended with the budget message |
| Inside: a fourth run in the same captain turn | Refused with the budget message; the probe did not run |
| Inside: one run after the next captain message | Ran, as the probe's fourth run |

Facts the seal depends on:

- `tool.execute.before` blocks every tool by throwing, not only bash, and the thrown message is the tool result the model sees.
- The bash tool's result carries the command's stderr, so a refusal written to stderr is what `tool.execute.after` reads.
- A plugin that changes `output.output` in `tool.execute.after` changes the tool result the model receives.
- `chat.message` fires for a captain message sent to a running session, and the plugin's state lives in the OpenCode server process across messages.
- `session.created` fires under `opencode run`, and a `promptAsync` from it reaches the model within the same run.

Refresh this record by repeating the runs above after an OpenCode or model-server upgrade.
