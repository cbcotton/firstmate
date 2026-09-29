#!/usr/bin/env bash
# Drives bin/fm-fleet-snapshot.sh --json against a disposable lab home seeded
# with Gitea, GitHub and near-miss PR links. Arg1 = repo checkout to run from.
set -u
REPO=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/projects/wt"
cat > "$LAB/data/backlog.md" <<'B'
## Done
- [x] gitea-done - Gitea Done https://gitea.example.com/acme/widgets/pulls/12 (repo: acme) (kind: ship) (merged 2026-09-28)
- [x] github-done - GitHub Done https://github.com/acme/widgets/pull/7 (repo: acme) (kind: ship) (merged 2026-09-28)
- [x] nearmiss-done - Near miss https://gitea.example.com/acme/widgets/pullsx/3 https://gitea.example.com/acme/widgets/pulls/abc (repo: acme) (kind: ship) (merged 2026-09-28)
B
for id in gitea-task github-task nearmiss-task; do
  printf 'window=firstmate:fm-%s\nworktree=%s/projects/wt\nproject=acme\nharness=claude\nkind=ship\nmode=ship\nyolo=off\n' "$id" "$LAB" > "$LAB/state/$id.meta"
done
printf 'done [at=1]: PR https://gitea.example.com/acme/widgets/pulls/12 checks green risk=low touches=none\n' > "$LAB/state/gitea-task.status"
printf 'done [at=1]: PR https://github.com/acme/widgets/pull/7 checks green\n' > "$LAB/state/github-task.status"
printf 'done [at=1]: PR https://gitea.example.com/acme/widgets/pullsx/3 checks green\n' > "$LAB/state/nearmiss-task.status"
out=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$REPO/bin/fm-fleet-snapshot.sh" --json 2>/dev/null)
rc=$?
echo "snapshot exit=$rc"
printf '%s' "$out" | jq -c '{backlog: [.backlog.records[] | select(.id!=null) | {id, pr_url}], tasks: [.tasks[] | {id, pr: .pr}]}'
rm -rf "$LAB"
