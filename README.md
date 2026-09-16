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
| `Packages/SeshKit/Sources/SeshCore` | The rules, as plain values and pure functions: session arithmetic, day keys, the accent engine, insights, the sync protocol. Depends on nothing but Foundation. |
| `Packages/SeshKit/Tests/SeshCoreTests` | Unit tests, including fixtures captured from a real `sesh-web` so the wire types are held to what the server actually sends. |
| `App/` | The SwiftUI app. Apple platforms only. |
| `SeshWidgets/` | Live Activity and Dynamic Island. |

`SeshCore` is deliberately free of SwiftUI, UIKit and SQLite so it builds and
tests anywhere — including on Linux, in under a second, which is where most of
its tests were written.

## Building

The app needs Xcode on macOS:

```sh
brew install xcodegen
xcodegen generate
open sesh.xcodeproj
```

The logic package builds without Xcode:

```sh
cd Packages/SeshKit
swift build
swift test
```

## The colour rule

`Accent.swift` is a port of the web app's `lib/accent.ts`, kept faithful down
to the rounding, and its tests are that file's tests. Both clients must reach
the same hex for the same category — otherwise the same session is one colour
on the phone and another on the laptop, and the person is right to think
something is broken. The port is checked against the original's output across
the whole palette, including the awkward cases (three-digit hex, white, black,
and strings that are not colours at all).
