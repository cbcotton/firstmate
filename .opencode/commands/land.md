---
description: Land a ready local-only branch - /land <task-id>
---
!`bin/fm-helm.sh land --stdin 2>&1 <<'FM_HELM_ARGUMENTS'
$ARGUMENTS
FM_HELM_END_OF_ARGUMENTS
FM_HELM_ARGUMENTS`

That is the front door's own report on the captain's /land command.
Tell the captain in one plain line whether the branch landed, or what was refused and what it needs.
