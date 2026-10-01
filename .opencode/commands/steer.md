---
description: Send words to a worker - /steer <task-id> <text>
---
!`bin/fm-helm.sh steer --stdin 2>&1 <<'FM_HELM_ARGUMENTS'
$ARGUMENTS
FM_HELM_AGAIN
$ARGUMENTS
FM_HELM_TOKENS
$1
FM_HELM_END_OF_ARGUMENTS
FM_HELM_ARGUMENTS`

That is the front door's own report on the captain's /steer command, which sent the captain's words to the worker.
When those words change what the task must deliver, also append them to the task's `## Captain's intent` in its instructions.
Tell the captain in one plain line whether the worker has the words, or what was refused.
