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

Refresh this record by repeating the run above after an OpenCode or model-server upgrade.
