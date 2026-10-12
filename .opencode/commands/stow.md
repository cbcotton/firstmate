---
description: Stow - file what only this conversation knows before the session stops
---
!`bin/fm-helm.sh queue 2>&1`

That is this home's backlog, shown for the captain's /stow.
The session may stop right after this turn, and this conversation is lost then.
Do these steps now, in order:

1. For each open item that lives only in this conversation, such as an ask not yet started or a promise to the captain, file a row: `bin/fm-tasks-axi.sh add '<title>' --mint --body '<what is open and why>'`.
2. For each row above whose state or note is now wrong, correct its note: `bin/fm-tasks-axi.sh update <id> --body '<the current note>' --archive-body`.
3. For each lasting fact about this home that you learned in this session, append one line to `$FM_HOME/data/learnings.md`.
4. Start no work, steer no worker, and ask the captain nothing.
5. Reply in one line that says stowed, for example `Captain, stowed: 1 row filed, 2 corrected.`
