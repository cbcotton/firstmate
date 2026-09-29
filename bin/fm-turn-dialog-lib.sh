#!/usr/bin/env bash
# Shared reading of a primary's turn-dialog hook payloads, for the writers that
# record what the captain and the first mate said from code-owned turn
# surfaces, never from the model: the supervision host's dialog mirror
# (bin/fm-host-mirror.sh) and the phone mirror (bin/fm-castoff.sh).
# This file is sourced by those writers and has no side effects on source.
# One owner for the payload fields and the writer scope keeps the two writers
# from drifting apart.

FM_TURN_DIALOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print one hook payload as three fields, one per line - tag (captain for a
# submitted prompt, main for the turn's final assistant message), id (the
# prompt or generation id, possibly empty), then the text as the remainder -
# with only the whitespace at the very end of the text trimmed. Prints nothing
# for any other event, a payload that is not an object, or an empty text.
# Measured payload fields (docs/verification/supervision.md "Dialog mirror
# writers"): Claude UserPromptSubmit .prompt and Stop .last_assistant_message,
# Cursor beforeSubmitPrompt .prompt and afterAgentResponse .text.
# The payload travels on stdin, so dialog text never enters a process argument.
fm_turn_dialog_parse() {  # payload on stdin
  jq -r '
    if type != "object" then empty else
      ((.hook_event_name // "") | tostring) as $event
      | if ($event == "UserPromptSubmit" or $event == "beforeSubmitPrompt") then
          ["captain", ((.prompt_id // .generation_id // "") | tostring), ((.prompt // "") | tostring)]
        elif $event == "Stop" then
          ["main", ((.prompt_id // .generation_id // "") | tostring),
           ((.last_assistant_message // "") | tostring)]
        elif $event == "afterAgentResponse" then
          ["main", ((.generation_id // "") | tostring), ((.text // "") | tostring)]
        else empty end
      | .[2] |= sub("\\s+\\z"; "")
      | select(.[2] != "")
      | "\(.[0])\n\(.[1])\n\(.[2])"
    end' 2>/dev/null
}

# A writer records only the lock-owning primary session's dialog: a crewmate
# worktree and a read-only second session write nothing.
fm_turn_dialog_writer_in_scope() {  # <root> <state>
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$FM_TURN_DIALOG_LIB_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$FM_TURN_DIALOG_LIB_DIR/fm-session-lock-lib.sh"
  fm_primary_scope_matches "$1" "$2" && fm_session_lock_owned_by_self "$2"
}

# A submitted prompt that is fleet machinery rather than the captain's words:
# one opening with the wrapper a harness puts around a turn it started itself
# (Claude submits its Stop-hook rewake inside <task-notification>, with no
# other field to tell it from a typed prompt; tests/fm-host-mirror-live-e2e.test.sh
# proves it), or one the shared operational-input protocol classifies
# (bin/fm-operational-input.sh: watcher wakes, guard follow-ups, launch briefs).
fm_turn_dialog_prompt_is_machinery() {  # <text>
  case "${1#"${1%%[![:space:]]*}"}" in
    '<task-notification>'*) return 0 ;;
  esac
  printf '%s' "$1" | "$FM_TURN_DIALOG_LIB_DIR/fm-operational-input.sh" classify >/dev/null 2>&1
}
