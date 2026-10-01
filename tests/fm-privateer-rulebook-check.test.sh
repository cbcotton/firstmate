#!/usr/bin/env bash
# tests/fm-privateer-rulebook-check.test.sh - the Privateer helm's tracked
# sources meet bin/fm-privateer-rulebook-check.sh, and the check refuses each
# rule it owns: this checkout's rulebook and skills pass, within their size
# caps; a fixture copy of them, beside this checkout's bin/, is broken one rule
# at a time and must be refused naming that rule; and a shown command is only
# parsed, never run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-privateer-rulebook-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-privateer-rulebook-check)

# fixture <name>: a checkout holding a copy of this checkout's Privateer
# sources and a link to its bin/; prints its path.
fixture() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/privateer" "$dir/docs/privateer"
  ln -s "$ROOT/bin" "$dir/bin"
  printf '%s\n' "$dir"
}

# run_check <root>: the check's output and exit status, as "<status>\n<output>".
run_check() {
  local out status
  out=$("$CHECK" --root "$1" 2>&1)
  status=$?
  printf '%s\n%s\n' "$status" "$out"
}

# expect_refusal <root> <needle> <label>: the check exits 1 naming <needle>.
expect_refusal() {
  local result
  result=$(run_check "$1")
  assert_equals 1 "$(printf '%s\n' "$result" | head -1)" "$3: the check must refuse"$'\n'"$result"
  assert_contains "$result" "$2" "$3: the refusal must name the broken rule"
}

test_this_checkout_passes() {
  local result f size
  result=$(run_check "$ROOT")
  assert_equals "0" "$result" "this checkout's Privateer sources must pass the rulebook check"
  size=$(wc -c < "$ROOT/docs/privateer/AGENTS.md" | tr -d ' ')
  [ "$size" -le 12000 ] || fail "the rulebook is $size bytes, over its 12,000-byte cap"
  for f in "$ROOT"/docs/privateer/skills/*/SKILL.md; do
    size=$(wc -c < "$f" | tr -d ' ')
    [ "$size" -le 6000 ] || fail "${f#"$ROOT"/} is $size bytes, over its 6,000-byte cap"
  done
  pass "this checkout's rulebook, agent, and skills pass the check within their size caps"
}

test_size_caps() {
  local dir
  dir=$(fixture big-rulebook)
  head -c 12001 /dev/zero | tr '\0' 'a' >> "$dir/docs/privateer/AGENTS.md"
  expect_refusal "$dir" "the rulebook may be at most 12000" "an oversized rulebook"
  dir=$(fixture big-skill)
  head -c 6001 /dev/zero | tr '\0' 'a' >> "$dir/docs/privateer/skills/ship-landing/SKILL.md"
  expect_refusal "$dir" "docs/privateer/skills/ship-landing/SKILL.md is" "an oversized skill"
  pass "the check refuses a rulebook over 12,000 bytes and a skill over 6,000 bytes"
}

test_skill_frontmatter() {
  local dir
  dir=$(fixture misnamed)
  sed -i.bak 's/^name: ship-landing$/name: landing/' "$dir/docs/privateer/skills/ship-landing/SKILL.md"
  expect_refusal "$dir" "names itself 'landing', but its directory is ship-landing" "a skill named other than its directory"
  dir=$(fixture undescribed)
  sed -i.bak '/^description:/d' "$dir/docs/privateer/skills/ship-landing/SKILL.md"
  expect_refusal "$dir" "ship-landing/SKILL.md has no description" "a skill without a description"
  dir=$(fixture badname)
  mv "$dir/docs/privateer/skills/ship-landing" "$dir/docs/privateer/skills/Ship_Landing"
  sed -i.bak 's/^name: ship-landing$/name: Ship_Landing/' "$dir/docs/privateer/skills/Ship_Landing/SKILL.md"
  expect_refusal "$dir" "OpenCode needs lowercase words joined by single hyphens" "a skill name OpenCode would refuse"
  pass "the check refuses a skill whose frontmatter name or description OpenCode would not load"
}

test_agent_allowlist() {
  local dir
  dir=$(fixture extra-skill)
  mkdir -p "$dir/docs/privateer/skills/extra"
  printf -- '---\nname: extra\ndescription: Load never.\n---\nBody.\n' > "$dir/docs/privateer/skills/extra/SKILL.md"
  expect_refusal "$dir" "docs/privateer/skills/extra is not allowed" "a skill the agent does not allow"
  dir=$(fixture missing-skill)
  rm -r "$dir/docs/privateer/skills/ship-landing"
  expect_refusal "$dir" "allows skill ship-landing, which docs/privateer/skills/ does not hold" "an allowed skill that does not exist"
  dir=$(fixture open-agent)
  sed -i.bak '/"\*": deny/d' "$dir/docs/privateer/agents/privateer.md"
  expect_refusal "$dir" 'must deny every skill with "*": deny' "an agent that does not deny other skills"
  pass "the check refuses an agent whose skill permission is not exactly deny-all plus the helm's skills"
}

# shellcheck disable=SC2016 # The Markdown written here is literal: backticks and $(...) must not expand.
test_named_scripts_and_commands() {
  local dir marker
  dir=$(fixture missing-script)
  printf '\nThen run bin/fm-nope.sh.\n' >> "$dir/docs/privateer/AGENTS.md"
  expect_refusal "$dir" "docs/privateer/AGENTS.md names bin/fm-nope.sh, which is not in this checkout" "prose naming a missing script"
  dir=$(fixture unparsed)
  printf '\nAnswer with `bin/fm-send.sh <id> "<answer>` now.\n' >> "$dir/docs/privateer/skills/ask-user-authority/SKILL.md"
  expect_refusal "$dir" "which does not parse as a shell command" "a shown command that does not parse"
  dir=$(fixture fenced)
  printf '\n```sh\nbin/fm-send.sh <id> ( <text>\n```\n' >> "$dir/docs/privateer/AGENTS.md"
  expect_refusal "$dir" "shows \`bin/fm-send.sh <id> ( <text>\`" "a fenced command that does not parse"
  dir=$(fixture library)
  printf '\nNever run `bin/fm-privateer-lib.sh x`.\n' >> "$dir/docs/privateer/AGENTS.md"
  expect_refusal "$dir" "bin/fm-privateer-lib.sh is not an executable script" "a shown command whose script is a library"
  dir=$(fixture parse-only)
  marker="$TMP_ROOT/ran"
  printf '\nRun `bin/fm-send.sh x "$(touch %s)"`.\n' "$marker" >> "$dir/docs/privateer/AGENTS.md"
  assert_equals "0" "$(run_check "$dir")" "a parseable command must pass"
  [ ! -e "$marker" ] || fail "the check ran a shown command instead of only parsing it"
  pass "the check refuses a missing script, an unparseable or non-executable command, and runs nothing it shows"
}

test_missing_sources_and_usage() {
  local dir status
  dir=$(fixture no-rulebook)
  rm "$dir/docs/privateer/AGENTS.md" "$dir/docs/privateer/agents/privateer.md"
  expect_refusal "$dir" "docs/privateer/AGENTS.md is missing" "a checkout without the rulebook"
  expect_refusal "$dir" "docs/privateer/agents/privateer.md is missing" "a checkout without the agent"
  "$CHECK" --root "$TMP_ROOT/absent" >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a root that does not exist is a usage error"
  pass "the check refuses a checkout without the rulebook or the agent, and a bad root is a usage error"
}

test_this_checkout_passes
test_size_caps
test_skill_frontmatter
test_agent_allowlist
test_named_scripts_and_commands
test_missing_sources_and_usage

echo "# all fm-privateer-rulebook-check tests passed"
