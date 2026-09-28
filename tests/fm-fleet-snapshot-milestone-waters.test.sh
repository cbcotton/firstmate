#!/usr/bin/env bash
# Behavior tests for milestone and waters tag parsing in fm-fleet-snapshot.sh.
# Backlog rows may carry (milestone: <slug>) and (waters: <slug>) tags alongside
# existing repo and priority tags. The parser must extract these without breaking
# compatibility with existing tags and unparsed lines.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-milestone-waters)
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck disable=SC2317
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# Test 1: Backlog row with milestone tag is parsed correctly
test 1 "backlog row with milestone tag is parsed" <<'EOF'
[ - ] ship-task-1 - Implement feature X (milestone: v2.0) (repo: acme/app)
EOF
home=$(make_home "home-milestone")
printf '%s\n' "- [ ] ship-task-1 - Implement feature X (milestone: v2.0) (repo: acme/app)" > "$home/data/backlog.md"
output=$(FM_HOME="$home" bash "$SNAPSHOT" --json 2>/dev/null)
record=$(printf '%s\n' "$output" | jq -r '.backlog.records[] | select(.id == "ship-task-1")' 2>/dev/null)
milestone=$(printf '%s\n' "$record" | jq -r '.milestone // "MISSING"' 2>/dev/null)
repo=$(printf '%s\n' "$record" | jq -r '.repo // "MISSING"' 2>/dev/null)
if [ "$milestone" = "v2.0" ] && [ "$repo" = "acme/app" ]; then
  pass "milestone and repo both parsed"
else
  fail "milestone=$milestone repo=$repo"
fi

# Test 2: Backlog row with waters tag is parsed correctly
test 2 "backlog row with waters tag is parsed" <<'EOF'
[ - ] ship-task-2 - Implement feature Y (waters: deep-sea) (repo: acme/app)
EOF
home=$(make_home "home-waters")
printf '%s\n' "- [ ] ship-task-2 - Implement feature Y (waters: deep-sea) (repo: acme/app)" > "$home/data/backlog.md"
output=$(FM_HOME="$home" bash "$SNAPSHOT" --json 2>/dev/null)
record=$(printf '%s\n' "$output" | jq -r '.backlog.records[] | select(.id == "ship-task-2")' 2>/dev/null)
waters=$(printf '%s\n' "$record" | jq -r '.waters // "MISSING"' 2>/dev/null)
repo=$(printf '%s\n' "$record" | jq -r '.repo // "MISSING"' 2>/dev/null)
if [ "$waters" = "deep-sea" ] && [ "$repo" = "acme/app" ]; then
  pass "waters and repo both parsed"
else
  fail "waters=$waters repo=$repo"
fi

# Test 3: Backlog row with both milestone and waters tags
test 3 "backlog row with both milestone and waters tags" <<'EOF'
[ - ] ship-task-3 - Complex feature (milestone: v3.0) (waters: deep-sea) (priority: high) (repo: acme/app)
EOF
home=$(make_home "home-both")
printf '%s\n' "- [ ] ship-task-3 - Complex feature (milestone: v3.0) (waters: deep-sea) (priority: high) (repo: acme/app)" > "$home/data/backlog.md"
output=$(FM_HOME="$home" bash "$SNAPSHOT" --json 2>/dev/null)
record=$(printf '%s\n' "$output" | jq -r '.backlog.records[] | select(.id == "ship-task-3")' 2>/dev/null)
milestone=$(printf '%s\n' "$record" | jq -r '.milestone // "MISSING"' 2>/dev/null)
waters=$(printf '%s\n' "$record" | jq -r '.waters // "MISSING"' 2>/dev/null)
priority=$(printf '%s\n' "$record" | jq -r '.priority // "MISSING"' 2>/dev/null)
repo=$(printf '%s\n' "$record" | jq -r '.repo // "MISSING"' 2>/dev/null)
if [ "$milestone" = "v3.0" ] && [ "$waters" = "deep-sea" ] && [ "$priority" = "high" ] && [ "$repo" = "acme/app" ]; then
  pass "all tags parsed correctly"
else
  fail "milestone=$milestone waters=$waters priority=$priority repo=$repo"
fi

# Test 4: Backlog row without tags (existing behavior unchanged)
test 4 "backlog row without tags remains compatible" <<'EOF'
[ - ] ship-task-4 - Simple task
EOF
home=$(make_home "home-none")
printf '%s\n' "- [ ] ship-task-4 - Simple task" > "$home/data/backlog.md"
output=$(FM_HOME="$home" bash "$SNAPSHOT" --json 2>/dev/null)
record=$(printf '%s\n' "$output" | jq -r '.backlog.records[] | select(.id == "ship-task-4")' 2>/dev/null)
milestone=$(printf '%s\n' "$record" | jq -r '.milestone // "null"' 2>/dev/null)
waters=$(printf '%s\n' "$record" | jq -r '.waters // "null"' 2>/dev/null)
if [ "$milestone" = "null" ] && [ "$waters" = "null" ]; then
  pass "row without tags has null milestone and waters"
else
  fail "milestone=$milestone waters=$waters"
fi

# Test 5: Project chart is included in snapshot
test 5 "project chart is included in snapshot" <<'EOF'
Home with project chart emits it in the snapshot.
EOF
home=$(make_home "home-chart")
mkdir -p "$home/data/charts"
cat > "$home/data/charts/acme-app.json" <<'CHART'
{"ports":[{"name":"v1.0","order":1,"target_date":"2025-10-01"},{"name":"v2.0","order":2,"target_date":"2025-11-15"}],"waters":["coastal","deep-sea"]}
CHART
printf '%s\n' "- [ ] ship-task-5 - Charted work (milestone: v1.0) (repo: acme-app)" > "$home/data/backlog.md"
output=$(FM_HOME="$home" bash "$SNAPSHOT" --json 2>/dev/null)
has_chart=$(printf '%s\n' "$output" | jq -e '.charts' >/dev/null 2>&1 && echo "yes" || echo "no")
if [ "$has_chart" = "yes" ]; then
  pass "snapshot contains charts field"
else
  fail "snapshot missing charts field"
fi

# Test 6: Chart data is correct
chart_data=$(printf '%s\n' "$output" | jq -r '.charts[0] // "MISSING"' 2>/dev/null)
chart_project=$(printf '%s\n' "$chart_data" | jq -r '.project // "MISSING"' 2>/dev/null)
chart_ports=$(printf '%s\n' "$chart_data" | jq -r '.ports | length' 2>/dev/null)
if [ "$chart_project" = "acme-app" ] && [ "$chart_ports" = "2" ]; then
  pass "chart data is correct"
else
  fail "chart_project=$chart_project chart_ports=$chart_ports"
fi

echo "---"
report "fm-fleet-snapshot milestone/waters chart parsing"
exit $failures
