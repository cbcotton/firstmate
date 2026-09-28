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
The audit ran `bin/fm-privateer.sh start --audit-proxy` for real: a fixture clone of the checkout as the code root, a throwaway Privateer home whose only sailor was a logging proxy on a loopback port that also served a scripted model, `ANTHROPIC_API_KEY` set to a decoy in the launcher's own environment, the real OpenCode primary with the real firstmate plugins inside the real Seatbelt sandbox in a dedicated tmux server, and `stop` afterwards.
The proxy recorded every request and refused every tunnel.

| Observation | Result |
| --- | --- |
| Model requests that reached the sailor | 1, answered 84 seconds after start, to the prompt the audit typed into the pane; the startup nudge alone had produced none by then, because the sandboxed OpenCode spends its first minute on the blocked plugin install noted above |
| Recorded attempts naming Anthropic or Claude | 0 |
| `CONNECT models.opencode.ai:443` | 1, refused by the proxy; the session continued |
| `CONNECT registry.npmjs.org:443` | 2, refused by the proxy; the session continued |
| `stop` with no task record | Stopped the watcher and the server |

Facts the quarantine design depends on:

- OpenCode honors `HTTP_PROXY` and `HTTPS_PROXY`: its own catalog fetch and plugin-package install arrived at the audit proxy as tunnels, so an audit proxy sees a well-behaved client's outbound traffic, and the sandbox (proven above) is what refuses anything that goes around it.
- The launcher's allowlist is what keeps a credential out: the live run set a decoy `ANTHROPIC_API_KEY` in the launcher's environment and recorded no attempt to use it, and `tests/fm-privateer.test.sh` pins the exact environment a stub first mate receives, with no `ANTHROPIC_*`, `CLAUDE_*`, or `CLAUDECODE` name in it.
- The two refused tunnels are OpenCode's own startup traffic, not firstmate's; both were denied and the primary still answered its first turn.

Refresh this record by repeating the runs above after an OpenCode or model-server upgrade.
