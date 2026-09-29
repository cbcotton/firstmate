---
name: castoff
description: >-
  Turn on the phone mirror when the captain invokes /castoff (Cast Off) or asks for their terminal replies on the pinnace, and load it whenever `state/.castoff` exists.
  While the mirror is on, every turn's final message also reaches the pinnace chat, so the first mate keeps its replies extra concise; /makefast (Make Fast) turns it off.
user-invocable: true
metadata:
  internal: true
---

# castoff

Cast Off mirrors what the first mate tells the captain in the terminal to the pinnace, the crowsnest phone channel.
Make Fast (`/makefast`) stops it.
The mirror is a flag, `state/.castoff`, written and removed only by `bin/fm-castoff.sh` in the turn that receives the command; nothing infers it from chat.
`bin/fm-castoff.sh --help` owns the flag, the hook writer, and what gets stamped; `bin/fm-inbox.sh --help` owns the mirrored-message record and how the phone reads it.

## Cast Off: `/castoff`

1. Run `bin/fm-castoff.sh on` in this same turn, before any other work.
   A `/castoff` while the mirror is already on is a refresh and changes nothing.
2. Tell the captain in one short sentence that their replies now reach the phone too, and that Make Fast turns it off.
   Pass on its no-pinnace line when it prints one.
   This turn's own reply is the first message the phone receives.

## While the mirror is on

Each turn's final message is recorded by the harness's turn-end hook, never by you, and read on the phone.
Tool output, mid-turn text, thinking, and the captain's own prompts are never mirrored.
A turn the captain started is stamped `captain` and notifies the phone; a turn fleet machinery started (a wake, a guard follow-up, a daemon digest) is stamped `operational` and is drawn quieter there.
A message past 8000 characters loses its middle.

Keep every final message extra concise, because it is read on a small screen:

- Lead with the outcome in the first sentence, then only what the captain needs to act on.
- Use a few short plain sentences; avoid tables, long lists, headings, and code blocks.
- Put detail in the report, PR, or file, and give its full URL or path instead of restating it.
- Keep an operational turn to a line or two, or nothing beyond `Captain, shipshape.` when nothing changed.
- Never drop a decision, failure, credential need, or URL to save words: `AGENTS.md` section 9's standalone final-message rule still binds, and concise means fewer words, not less information.

When a turn answers a phone note with `bin/fm-inbox.sh reply <id>`, end the turn with those same words, so the phone shows one message instead of two.

Only a Claude or Cursor primary has the writer; on any other primary the flag is harmless but nothing reaches the phone, so say so when turning it on there.
While a Pi or supervision-host home is away, main is parked and its engine's turns fire no hook here, so nothing new is mirrored until main speaks again.

## Make Fast: `/makefast`

Run `bin/fm-castoff.sh off` in the same turn and tell the captain in one sentence that replies stay in the terminal again.
That turn ends with the flag gone, so its own reply is not mirrored.

## Boundaries

- A message beginning `/castoff` or `/makefast` is neither the away-mode return signal nor a quiet-mode exit (`AGENTS.md` section 8).
- `/afk` never turns the mirror on; the captain chooses it with Cast Off.
- The mirror is presentation only: it changes where the captain reads the first mate's replies, never who approves what.
- Mirrored messages stay owner-only in this home's state and reach the phone only through the pinnace server's authenticated channel.
