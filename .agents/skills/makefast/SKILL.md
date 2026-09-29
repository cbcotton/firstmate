---
name: makefast
description: >-
  Turn off the phone mirror when the captain invokes /makefast (Make Fast) or asks to stop sending their terminal replies to the pinnace.
  The castoff skill owns the mirror; this entry only makes Make Fast its own command.
user-invocable: true
metadata:
  internal: true
---

# makefast

Make Fast is the off switch for Cast Off's phone mirror.
Follow the "Make Fast" section of the `castoff` skill: run `bin/fm-castoff.sh off` in this same turn and tell the captain in one sentence that replies stay in the terminal again.
Like `/castoff`, a message beginning `/makefast` is neither the away-mode return signal nor a quiet-mode exit.
