# Login sailors verification

Audience: maintainer verification.

This record supports the login sailor contract owned by [`../configuration.md`](../configuration.md) ("Named sailors" and "Sailor slot registry").
It records only facts that must be re-established when codex, kimi, or grok changes, because every verdict below comes from what those apps emit.
Planning chronology and the captain's decisions stay in the private scout report.

## The sign-in checks read the real logins without a value and without a spawn

Verified 2026-10-19 on macOS 26.6 with codex-cli 0.163.0, kimi 2.2.0, and grok 1.0.62, each signed in on the captain's own login.

Setup: a scratch home holding only a dispatch map, a scratch slot registry naming the three planned slots (`teach` on codex, `bonny` on kimi, `mary` on grok, plus one blank slot), and an empty mlx-serve server list, with `OPENAI_API_KEY` unset in the calling shell.
Nothing below spawns a worker, edits the real slot registry or `config/`, or reads a credential file; the kimi `check` is the one request that reaches a model.

```sh
codex --version; kimi --version; grok --version
FM_HOME=<scratch>/home FM_CONFIG_OVERRIDE=<scratch>/home/config FM_STATE_OVERRIDE=<scratch>/home/state \
  FM_MLX_SERVE_SERVERS=<scratch>/servers.json bin/fm-sailor.sh sync <scratch>/sailors.json --home firstmate
bin/fm-sailor.sh list
bin/fm-sailor.sh health
bin/fm-sailor.sh status
bin/fm-sailor.sh check teach gpt-6-sol
bin/fm-sailor.sh check bonny kimi-for-coding
bin/fm-sailor.sh check mary grok-4.7
bin/fm-sailor.sh pick --grade sailor
bin/fm-sailor.sh pick --grade specialist
bin/fm-sailor.sh provider-json teach gpt-6-sol
```

Each later command ran with the same environment as the `sync`.

```
codex-cli 0.163.0
2.2.0
grok 1.0.62 (1474f9cbdd91) [stable]
wrote config/crew-dispatch.json (previous copy: crew-dispatch.json.bak-20261019-185959)
synced home firstmate from <scratch>/sailors.json: teach, bonny, mary
workers: the change applies from each worker's next spawn; running workers keep what they launched with
teach status=live harness=codex max_concurrent=1 grade=specialist models=gpt-6-sol login=chatgpt
bonny status=live harness=kimi max_concurrent=1 grade=sailor models=kimi-for-coding
mary status=live harness=grok max_concurrent=1 grade=sailor models=grok-4.7 login=grok.com
teach up login:codex
bonny up login:kimi
mary up login:grok
teach live answering harness=codex tasks=0/1 grade=specialist models=gpt-6-sol(signed-in) login=chatgpt
bonny live answering harness=kimi tasks=0/1 grade=sailor models=kimi-for-coding(signed-in)
mary live answering harness=grok tasks=0/1 grade=sailor models=grok-4.7(signed-in) login=grok.com
ok: sailor teach runs gpt-6-sol on its codex login (0 of 1 tasks busy; signed in)
ok: sailor bonny runs kimi-for-coding on its kimi login (0 of 1 tasks busy; signed in)
ok: sailor mary runs grok-4.7 on its grok login (0 of 1 tasks busy; signed in)
bonny kimi-for-coding
teach gpt-6-sol
refused: sailor teach is a login sailor on codex, which runs as its own worker app and takes no OpenCode provider
```

Every command exited 0 except `provider-json`, which exited 1.

## What each app emits for a signed-in login

The checks depend on these vendor behaviors, read under the same cleared environment `bin/fm-sailor.sh` uses.

```sh
env -i HOME=$HOME PATH=$PATH codex login status; echo "exit $?"
env -i HOME=$HOME PATH=$PATH GROK_HOME=$HOME/.grok grok models | head -3
ls -ld ~/.kimi-code/credentials ~/.grok/auth.json
```

```
Logged in using ChatGPT
exit 0
You are logged in with grok.com.

Default model: grok-4.7
-rw-------@ 1 cotton  staff  1699 Oct 19 15:36 ~/.grok/auth.json
drwx------@ 3 cotton  staff    96 Oct 19 18:59 ~/.kimi-code/credentials
```

`health` and `status` read only `codex login status`, `~/.grok/auth.json`, and the kimi credentials file, within `FM_SAILOR_PROBE_TIMEOUT`, so a heartbeat never waits on a vendor endpoint; `grok models` and the kimi test prompt run only in `check`, within `FM_SAILOR_LOGIN_TIMEOUT` and `FM_SAILOR_SMOKE_TIMEOUT`.
The kimi credentials directory held one `kimi-code-env-*.json` file, and `kimi -p "Reply with the single word OK." --output-format text` from an empty scratch directory exited 0 within a few seconds, which is the test prompt `check` sends before each kimi task.

## Signed-out behavior

A signed-out verdict is verified only through the portable regression in `tests/fm-sailor.test.sh`, which drives fakes of the three apps: codex exiting non-zero from `codex login status`, grok with no `auth.json` or with `grok models` failing, and kimi with no credentials file or a refused test prompt.
No real app was signed out for this record, so the exact text a signed-out codex, kimi, or grok prints is not recorded here, and the checks rely on their exit status and file presence alone.

## Refreshing this record

```sh
FM_LOGIN_SAILORS_E2E=1 bash tests/fm-login-sailors-live-e2e.test.sh
```

```
ok - sync projects the three login slots from a scratch registry into login sailors
ok - codex codex-cli 0.163.0: health, status, check, and pick read the teach login as signed in, and check says so without printing a value
ok - kimi 2.2.0: health, status, check, and pick read the bonny login as signed in, and check says so without printing a value
ok - grok grok 1.0.62 (1474f9cbdd91) [stable]: health, status, check, and pick read the mary login as signed in, and check says so without printing a value
ok - a login sailor takes no OpenCode provider
# login sailors live guard checked: codex kimi grok
```

The guard sends kimi its one test prompt, so it stays opt-in; rerun it after every codex, kimi, or grok upgrade, and record the per-app result in [`runtime-backends.md`](runtime-backends.md#login-sailors).
