# How syncing works

The phone is not a client of the server in the usual sense. It owns its data,
and the server is somewhere it catches up with — later, eventually, or on the
train home. Every screen reads the local database, every write lands there
first, and nothing in the interface ever waits for a network.

That is the whole design. What follows is how it stays honest.

## Three rules

**Operations are named by the client.** Every change queued for the server
carries an id the phone generated. The server remembers what it did with each
one. A reply lost to a dropped connection is therefore safe to ask about again:
the second attempt gets the first attempt's answer back rather than doing the
work twice. Without this, a retried "add 25 minutes to this task" adds fifty.

**`seq` orders the world.** The server keeps one counter across every table and
stamps each row as it changes. A client's cursor is a precise position in that
sequence, not a guess about clocks. Timestamps would have been easier and wrong:
two writes land in the same millisecond all the time, and no two devices agree
about what time it is anyway.

**`updated_at` settles disputes, a row at a time.** When both sides changed the
same session, the later edit wins — and it wins the whole editable set, not
field by field. Timings are outside the contest, being set by whoever ran the
session and never revised, so what can actually conflict is the title, the
category, the notes, the rating and the task links.

The row-level part is a deliberate simplification with a real cost, worth
stating plainly: a note added on the phone at 10:00 and a rating given on the
laptop at 10:01 do not merge. The phone's op comes back `stale`, and the note
is gone. Fixing it properly needs a timestamp per field. Until then the window
is kept small — the app syncs about two seconds after any change, and on every
return to foreground.

Deletions are held to the same rule rather than being privileged: a delete
queued at 10:00 loses to an edit made at 10:05 somewhere else, because the edit
is the more recent intention. The client and the server apply that identically,
which matters — if they disagreed, a row would appear or vanish depending on
which end was asked.

## One exchange

`POST /api/sync` does both halves at once: here is everything I did while I was
away, now tell me everything that happened without me. The push runs first, so
the changes coming back already account for the client's own work rather than
describing a world just before it.

```
push ops ──▶ server applies each in its own transaction
                    │
                    ├── applied / duplicate / stale / rejected, per op
                    │
pull ◀────── rows with seq > cursor, tombstones included
```

The client drops an op on `applied`, `duplicate` **and** `stale` — all three
mean the server is finished with it. `rejected` usually carries the row that won
instead, which is what lets the phone repoint and move on rather than retrying
something that will never work.

## Deletions are things, not absences

A row that simply vanished would be invisible to a phone that was not watching
at the time: it would pull the list, not find the deletion in it, and go on
showing a session its owner threw away last Tuesday. So deleting sets
`deleted_at`, the tombstone travels like any other change, and the phone removes
its copy when it sees one.

## The timer is different

It is the one piece of state this app does not treat as replicated. The phone
runs its own timer from a start instant — nothing counts down, the remaining
time is derived from the clock whenever anyone asks — which is why sleeping,
being killed, or losing signal costs nothing at all.

It mirrors its position to the server so a laptop across the room can see it,
coalesced so only the newest position is ever queued. A timer running on another
device shows up as an offer on the Focus screen, never as something adopted:
which session you are currently in is not a thing an app should decide for you.

Local notifications are scheduled up front — at the target, then every five
minutes into overtime — so a session announces itself with no server, no push
and no network involved.

## What is not replicated

Task completions and the minutes written back are commands to Todoist and
Things, not rows. They go one at a time to their own endpoints with an
`Idempotency-Key`, and they are what the `Backoff` policy is for: a refusal is
dropped, anything that smells of weather is kept and retried.

Device-local preferences — the calendar view, how many sessions you have
finished today — stay in `UserDefaults` and are never sent. A phone should not
impose its morning on a laptop.

## Things worth knowing

- **A quarter of the existing history is filed under a session type this app had
  never heard of** (`short`, from an older version). Unknown kinds are kept
  verbatim rather than rewritten, because one unrecognised value in a page would
  otherwise cost the whole page.
- **Numbers are read leniently.** A fractional timestamp written by some other
  client once poisoned a row for everyone who pulled it. The server rounds now,
  but the client no longer trusts that it always will.
- **Category slugs are the join key.** Sessions are filed by slug, so a rename
  has to sweep them — on the server, and identically on the phone when the
  rename arrives.
