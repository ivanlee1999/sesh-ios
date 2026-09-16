# sesh for iOS

A native SwiftUI client for [sesh](https://sesh.liyifan.us) — the focus timer,
task queue, calendar and insights — with one thing the installed web app cannot
do: **it works with no network, and reconciles later.**

## Why it exists

The web app keeps the running timer in a single row on the server and posts a
session when it finishes. That is fine at a desk and wrong on a phone, which
spends its life asleep, in tunnels, and on aeroplanes. Here the phone owns its
own timer, writes every session to its own database first, and treats the
server as somewhere to catch up with rather than somewhere to ask permission.

Nothing is lost while offline and nothing is applied twice when the signal
returns. See `docs/sync.md` (and `sesh-web`'s `/api/sync`) for how.

## Layout

| Path | What it is |
|---|---|
| `Packages/SeshCore` | The rules, as plain values and pure functions: session arithmetic, day keys, the accent engine, insights, the sync protocol and engine. Depends on nothing but Foundation. |
| `Packages/SeshStore` | Persistence — the GRDB schema, the records, and the repository every write goes through. |
| `App/` | The SwiftUI app. Apple platforms only. |
| `SeshWidgets/` | Live Activity and Dynamic Island. |

`SeshCore` has no dependencies at all, which is the point: it builds and tests
anywhere in about a second, including on Linux, which is where most of its tests
were written. Its tests include fixtures captured from a real running
`sesh-web`, so the wire types are held to what the server actually sends rather
than to a hand-written idea of it.

See [`docs/sync.md`](docs/sync.md) for how offline and syncing actually work.

## Building

The app needs Xcode on macOS:

```sh
brew install xcodegen
xcodegen generate
open sesh.xcodeproj
```

The logic package builds without Xcode, on any platform:

```sh
cd Packages/SeshCore
swift test
```

`SeshStore` needs SQLite headers (`libsqlite3-dev` on Linux; already present in
any Xcode toolchain).

### Testing against a real server

Most tests need nothing. The ones in `LiveServerTests` drive an actual
`sesh-web` and are skipped unless you point them at one:

```sh
# in sesh-web
APP_AUTH_USERNAME=you APP_AUTH_PASSWORD=secret NEXTAUTH_SECRET=dev npx next dev -p 3099

# in Packages/SeshCore
SESH_TEST_SERVER=http://127.0.0.1:3099 SESH_TEST_USER=you SESH_TEST_PASSWORD=secret swift test
```

They are the only tests that prove this client agrees with the server rather
than with itself — and they have already earned their keep twice, catching a
session type and a fractional timestamp that would each have broken the very
first sync against real data.

## The colour rule

`Accent.swift` is a port of the web app's `lib/accent.ts`, kept faithful down
to the rounding, and its tests are that file's tests. Both clients must reach
the same hex for the same category — otherwise the same session is one colour
on the phone and another on the laptop, and the person is right to think
something is broken. The port is checked against the original's output across
the whole palette, including the awkward cases (three-digit hex, white, black,
and strings that are not colours at all).
