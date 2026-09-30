---
description: Start a local-only ship - /ship <project> <ask>, or /ship <task-id> for queued work
---
!`bin/fm-helm.sh ship --stdin 2>&1 <<'FM_HELM_ARGUMENTS'
$ARGUMENTS
FM_HELM_END_OF_ARGUMENTS
FM_HELM_ARGUMENTS`

That is the front door's own report on the captain's /ship command, and every step it names is already done, so repeat none of them by hand.
Tell the captain in one or two plain lines what started, what waits in the queue and why, or what was refused and what the captain needs to decide.
When it asks for a dispatch rule, choose the rule by judgment and run the call it shows.
