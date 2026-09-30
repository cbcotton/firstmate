#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh project-by-name resolution, unknown-flag
# refusal, and the sealed Privateer home's projects/-only rule, plus
# fm-project-mode.sh --registered and fm-brief.sh's keyword and unknown-flag
# refusals. Spawns run against a fake tmux and a real isolated git worktree.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-project-name)
unset LAVISH_AXI_HOST

# make_case <name>: prints "case_dir|home|fakebin|worktree|task-id".
make_case() {
  local name=$1 case_dir home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  printf '%s\n' '- alpha [no-mistakes] - the registered clone (added 2026-01-01)' \
    '- alphabet - a longer name sharing the prefix (added 2026-01-01)' > "$home/data/projects.md"
  fm_git_worktree "$home/projects/alpha" "$case_dir/wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name-t1"
  printf '%s\n' "$case_dir|$home|$fakebin|$case_dir/wt|$name-t1"
}

field() { # <record> <1-based index>
  printf '%s' "$1" | cut -d'|' -f"$2"
}

spawn_in() { # <record> <args...>
  local rec=$1
  shift
  fm_test_run_spawn "$(field "$rec" 2)" "$(field "$rec" 4)" "$(field "$rec" 3)" "$@"
}

test_registered_name_resolves_to_its_clone() {
  local rec id out status
  rec=$(make_case byname)
  id=$(field "$rec" 5)
  out=$(spawn_in "$rec" "$id" alpha --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a registered project name should spawn: $out"
  assert_contains "$out" "spawned $id" "spawn did not report the task"
  pass "fm-spawn.sh: a registered project name resolves to projects/<name>"
}

test_unknown_name_and_missing_clone_are_refused() {
  local rec id out status
  rec=$(make_case unknown)
  id=$(field "$rec" 5)
  out=$(spawn_in "$rec" "$id" nosuchproject --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an unregistered bare name should be refused"
  assert_contains "$out" "not a registered project" "refusal did not name the registry"
  out=$(spawn_in "$rec" "$id" alphabet --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a registered name with no clone should be refused"
  assert_contains "$out" "not a registered project with a clone" "refusal did not explain the missing clone"
  pass "fm-spawn.sh: an unregistered name, or one with no clone, is refused with an explanation"
}

test_unknown_flag_is_refused_not_read_as_harness() {
  local rec id out status
  rec=$(make_case flag)
  id=$(field "$rec" 5)
  out=$(spawn_in "$rec" "$id" --project alpha --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "--project should be refused"
  assert_contains "$out" "unknown flag '--project'" "refusal did not name the flag"
  assert_contains "$out" "--sailor" "refusal did not list the accepted flags"
  case "$out" in *"unknown harness"*) fail "the flag was read as a harness: $out" ;; esac
  out=$(spawn_in "$rec" "$id" alpha --project --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a trailing unknown flag should be refused"
  assert_contains "$out" "unknown flag '--project'" "trailing flag not refused as unknown"
  pass "fm-spawn.sh: an unknown --flag is refused with the accepted list, never read as a harness"
}

test_privateer_home_refuses_directory_outside_projects() {
  local rec id out outside home case_dir
  rec=$(make_case sealed)
  id=$(field "$rec" 5)
  case_dir=$(field "$rec" 1)
  home=$(field "$rec" 2)
  outside="$case_dir/elsewhere"
  mkdir -p "$outside"
  : > "$home/config/privateer"
  out=$(spawn_in "$rec" "$id" "$outside" --mode local-only --yolo off)
  [ $? -ne 0 ] || fail "a sealed home should refuse a directory outside projects/"
  assert_contains "$out" "outside projects/" "refusal did not explain the projects/ rule"
  out=$(spawn_in "$rec" "$id" alpha --mode local-only --yolo off)
  case "$out" in *"outside projects/"*) fail "a project under projects/ was refused as outside: $out" ;; esac
  rm -f "$home/config/privateer"
  out=$(spawn_in "$rec" "$id" "$outside" --mode no-mistakes --yolo off)
  case "$out" in *"outside projects/"*) fail "a home without config/privateer applied the Privateer rule: $out" ;; esac
  pass "fm-spawn.sh: only a Privateer home refuses a project directory outside projects/"
}

test_project_mode_registered_query() {
  local home out
  home="$TMP_ROOT/registered-home"
  mkdir -p "$home/data"
  printf '%s\n' '- alpha [direct-PR] - x (added 2026-01-01)' '- alphabet - y (added 2026-01-01)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --registered alpha || fail "alpha should be registered"
  FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --registered alphabet || fail "alphabet should be registered"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" --registered alph 2>&1) && fail "a name prefix must not count as registered"
  [ -z "$out" ] || fail "--registered must be silent, got: $out"
  out=$(FM_HOME="$TMP_ROOT/no-registry" "$ROOT/bin/fm-project-mode.sh" --registered alpha 2>&1) && fail "no registry means not registered"
  [ -z "$out" ] || fail "--registered must be silent without a registry, got: $out"
  pass "fm-project-mode.sh: --registered answers by exit status alone and matches whole names"
}

test_brief_refuses_keyword_ids_and_unknown_flags() {
  local home out status
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" scout --project alpha --mode no-mistakes 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--project should be refused"
  assert_contains "$out" "unknown flag '--project'" "brief did not refuse the unknown flag"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" scout alpha --mode no-mistakes 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a task id of scout should be refused"
  assert_contains "$out" "did you mean" "brief did not offer a correction"
  case "$out" in *"ship briefs require --mode"*) fail "the misleading mode error came back: $out" ;; esac
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship alpha --mode no-mistakes 2>&1)
  [ $? -ne 0 ] || fail "a task id of ship should be refused"
  assert_contains "$out" "did you mean" "brief did not offer a correction for ship"
  [ ! -e "$home/data/scout" ] && [ ! -e "$home/data/ship" ] || fail "a refused brief left a scaffold behind"
  pass "fm-brief.sh: keyword task ids and unknown flags are refused with a correction, writing nothing"
}

test_registered_name_resolves_to_its_clone
test_unknown_name_and_missing_clone_are_refused
test_unknown_flag_is_refused_not_read_as_harness
test_privateer_home_refuses_directory_outside_projects
test_project_mode_registered_query
test_brief_refuses_keyword_ids_and_unknown_flags

echo "# all fm-spawn-project-name tests passed"
