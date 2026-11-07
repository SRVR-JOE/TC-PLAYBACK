# Crew cueing framework

Status, 2026-11-07: **foundations only**. This is for a later version. Everything is behind
`FeatureFlags.crewCueing`, which is hard `false` in Release. Nothing here is reachable in the
shipping app. Background research is in `CUEPILOT_RESEARCH.md`.

## Goal

Crew devices (camera operators, lighting, video, SFX, stage) follow the show's timecode. Each
device sees only its own role's cues: now, next, the one after, and a countdown. A master
device (the playback iPad) keeps followers in step over the LAN.

## Architecture

```
                         MASTER (playback device)
 ┌──────────────────────────────────────────────────────────────────────┐
 │ PlaybackEngine.preciseTime ──┐                                       │
 │ CuePoint (SwiftData) ────────┼─► CrewCue[] ──► CrewMasterSession ───┐ │
 │ CuePointTypeStore (lanes) ───┘                 publish(state, cues, │ │
 │ CrewRoleStore (roles) ─────────────────────►    roles), answer ping │ │
 └────────────────────────────────────────────────────────────────────┼─┘
                                                                      │
             CrewEnvelope {v, sender, seq, type, body}  (JSON)        │
             CrewTransport ── Loopback (tests) / Network (Bonjour+TCP)│
                                                                      │
                         FOLLOWER (crew device)                        ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │ CrewFollowerSession                                                  │
 │   ping/pong ─► ClockSyncEstimator (median) ─► offset                 │
 │   showState ─► FollowerClock (offset + anchor, slewed) ─► track time │
 │                     │                                                │
 │   LTC in (optional) ─► FollowMachine (follow / freewheel / lost /    │
 │                     │   manual step / nudge) ─► playhead             │
 │                     ▼                                                │
 │   CrewRole + CrewCue[] ─► CrewLaneFilter ─► now / next / after       │
 │                        ─► CountdownModel ─► seconds, bars/beats,     │
 │                                             progress, 3-2-1 schedule │
 │                        ─► CountdownCaller ─► CrewSpeaker (stub)      │
 │   CueSheetRenderer ─► per-role PDF        ShotListBuilder ─► CSV     │
 │   Rundown (Playlist + act metadata) ─► RundownTimer ─► over/under    │
 └──────────────────────────────────────────────────────────────────────┘
```

All logic types are value types or plain classes with injected clocks. Nothing reads
`Date()` or the host clock internally, so all of it is unit-tested with virtual time.

## Modules (App/Crew/)

| File | Responsibility |
|---|---|
| `FeatureFlags.swift` | `FeatureFlags.crewCueing`. Release: always false. DEBUG: `-crewCueing`, `-crewPreview`, or the `feature.crewCueing` default. |
| `Roles/CrewCue.swift` | `CrewCue`, the Codable value copy of a cue point (lane resolved, shot fields). Built from `CuePoint` or `CuePointRow`. It is also the wire format for cue lists. |
| `Roles/CrewRole.swift` | `CrewRole` (id, name, kind, camera number, colour, lane ids) with `matches(_:)`. `CrewLaneFilter`: pure now/next/next+1 via binary search, plus lane suggestions by type name. `CrewRoleStore`: JSON in UserDefaults (`crew.roles`) with prune and starter roles. |
| `ShotScript/ShotList.swift` | `ShotSize` presets, `ShotRow`, `ShotListBuilder`: per-lane durations to the next cut, last shot to the track end, camera totals, CSV. |
| `Rundown/Rundown.swift` | `Rundown`/`Act` derived from Playlist + Cue, with an additive `RundownMetadata` layer (planned start/duration, skip, notes, title, running order) stored per playlist in UserDefaults (`crew.rundown.<id>`). |
| `Rundown/RundownTimer.swift` | Pure planned vs actual: per-act state, drift, over/under, projected show end, running time. Skip and reorder are handled because starts chain in running order. |
| `Countdown/CountdownModel.swift` | Seconds to next, bars/beats to next (BeatGrid), countdown-bar progress, spoken 3-2-1 schedule (seconds, or beats with a grid). `CrewSpeaker` protocol, `SilentCrewSpeaker` stub, `CountdownCaller` (fires each count once, never on a seek). |
| `Follow/FollowState.swift` | `FollowMachine`: following, freewheel (configurable limit), lost, manual step, nudge. Handles LTC dropout and return. Manual step doesn't give way to returning LTC until `resumeFollowing`. |
| `Sync/CrewMessage.swift` | Versioned schema: hello, showState (track id, transport, track-time anchor at master host time, rate, epoch), cueList (cues for every lane, plus lane names), roles, heartbeat, ping/pong. `CrewCodec` checks the version before decoding the body (`versionTooNew` / `versionTooOld` / `malformed`). An unknown type at the same version decodes to `.unknown` and is ignored. |
| `Sync/CrewClockSync.swift` | `ClockSample` (NTP four timestamps), `ClockSyncEstimator` (median of offsets after dropping slow round trips), `FollowerClock` (local + offset → track time; slews corrections under 50 ms at 10 %, snaps large ones, seeks, transport and track changes). |
| `Sync/CrewTransport.swift` | `CrewTransport` protocol (unicast, `to: nil` = all peers). `LoopbackHub`/`LoopbackTransport`: an in-memory network with a virtual clock and per-message delay. `CrewMasterSession`/`CrewFollowerSession`: protocol logic, independent of the transport. A master re-sends roles, cues and state to late joiners. `CrewLoopbackDemo`: a deterministic jitter simulation. |
| `Sync/CrewNetworkTransport.swift` | **Skeleton.** NWListener advertising `_tcplayback._tcp`, NWBrowser, TCP with 4-byte length framing. |
| `Sync/CrewJoinCode.swift` | QR payload `tcplayback-crew://join?d=<base64url JSON>` (session id, service name, optional host/port/pin, version), with encode/decode. `CrewQRImage` is a stub. |
| `CueSheets/CueSheetRenderer.swift` | US Letter PDF via UIGraphicsPDFRenderer: title block, a TC-ordered table of every cue, this role's rows bold on a grey band and everyone else's grey, and page footers. |
| `Preview/CrewPreviewScreen.swift` | DEBUG only, `-crewPreview`. A bare developer screen: role picker, follow state with LTC on/off, step, resume, nudge; the countdown; a loopback sync run; a sample PDF. Simulated playhead by default, or the engine's `preciseTime`. It never starts playback. |

### Decisions

- **Rundown is derived, not a SwiftData model.** A playlist already is the ordered list of
  acts, each with a track and its cue points, and `Playlist`/`Cue` are frozen contract
  models. The rundown only adds small per-playlist metadata, so that lives in a JSON side
  layer. The library schema doesn't change, orphaned entries are ignored, and the layer can
  later move into the `.tcshow` file without a migration.
- **Shot fields live on `CuePoint`** as additive defaulted columns, so a shot is just a cue in
  a "Shots" lane. The existing timeline, lanes, exports and trigger clock keep working on it.
- **`CrewCue` is the single value type** for filtering, countdowns, shotlists, PDFs and the
  wire. SwiftData stays out of every pure function.
- **Unicast + Bonjour, not multicast.** UDP multicast/broadcast on iOS needs Apple's
  `com.apple.developer.networking.multicast` entitlement, which has to be requested.
  Followers find the master by Bonjour (or the QR host/port) and talk unicast. Followers run
  their own clock from an anchor and offset, so the master sends state changes plus periodic
  re-anchors, not a frame stream.
- **Clock sync is our own small implementation.** The Watch work (WatchLink) has its own on
  another branch. **TODO: merge the two into one shared clock-sync module** when both land.

## Model changes

`CuePoint` (SwiftData) gained five fields, all defaulted so existing stores migrate with
lightweight migration. `CrewShotScriptTests.testOldStoreOpensWithNewSchema` opens a store
written with the old schema and checks it.

```swift
var camera: Int? = nil
var shotNumber: String = ""
var shotSize: String = ""
var shotNote: String = ""      // named shotNote: `callNote` is the cue caller's field
var holdUntilNext: Bool = true
```

`holdUntilNext` defaults to `true` because a held shot is the normal case. It has no effect
on non-shot cues.

Info.plist (project.yml): `NSLocalNetworkUsageDescription` and
`NSBonjourServices = [_tcplayback._tcp]` were added. Neither triggers a prompt until the
network transport is actually started, which can't happen with the flag off.

## Done (with tests)

- Roles: matching, now/next/after, store persistence and pruning, tolerant decoding, starter roles.
- Shot script: migration from the old schema, `CrewCue` from `CuePoint`, per-lane durations, CSV.
- Rundown: derive, reorder, skip, explicit starts, planned vs actual, projection, store.
- Countdown: seconds, progress, bars/beats, the spoken schedule, and the caller (once only, never on a seek).
- Follow state: dropout → freewheel → lost, return from each state, manual step, resume, nudge.
- Sync: schema round trip, version mismatch, unknown types, clock maths, median filter,
  slew/snap, late joiner, loopback under 3–11 ms jittered one-way delay kept **within 5 ms**
  of master track time (four seeds).
- PDF: valid PDF, US Letter, 100 rows → 3 pages, role rows highlighted.

## Stubbed or skeleton

- `CrewNetworkTransport`: compiles, but has no reconnect, timeouts, pairing check or TLS. It
  is not thread-safe yet (the connection map is touched from two queues), and it hasn't been
  tested on devices.
- `CrewQRImage.make` returns nil (later: `CIFilter.qrCodeGenerator`).
- `CrewSpeaker` has only the silent stub. The real one should reuse the studio voices in
  `App/Resources/Voices`.
- Nothing is wired to live data. No code yet turns `PlaybackEngine` + `ShowController` into
  `CrewShowState` on the master, and the follower's playhead isn't fed by LTC input.
- Shot fields aren't in the `.tcshow` export/import, the CSV/MA3/disguise importers, or the cue editor.

## Next steps (full version)

1. Master publisher: observe `PlaybackEngine` (transport, `preciseTime`, seeks → epoch) and
   `ShowController` (active cue → track id), publish state on change plus a re-anchor about
   every 2 s, and cue lists when points change.
2. Follower runtime: a CADisplayLink driver (like `CueTriggerClock`) that reads
   `CrewFollowerSession.trackTime()` into `FollowMachine` and `CountdownModel` and triggers
   flashes and haptics for the role's cues. Merge clock sync with WatchLink and make the
   Watch a follower.
3. Harden the network transport: UDP for pings, reconnect, a session/pin check, TLS-PSK,
   multi-follower load test, and the Local Network permission flow.
4. Persist rundown actuals per show night, write them into the show file, and export a report.
5. Put shot fields and rundown metadata into `.tcshow`, and add a shot CSV import.
6. Speech: a voice-pack `CrewSpeaker`, with output routed away from the show output.
7. Rehearsal takes (research item 8) on top of the rundown.

## Remaining UI work

None of this exists yet. The developer preview is not a starting point for it.

- Role picker / "I am…" onboarding on a follower, including joining by QR scan or Bonjour list.
- Follower main screen: big now/next/after, countdown bar, seconds or bars/beats toggle,
  lost-timecode and freewheel banners, and step/nudge controls.
- An all-roles grid on the master: every role's next cue and countdown.
- Shot script editing in the timeline: a shot lane style, camera/size/number/note fields in the
  point inspector, camera colours, and a shotlist table with CSV export.
- Role management: create, edit and delete roles, map them to lanes, choose a colour.
- Rundown screen: acts in running order, drag to reorder, skip toggle, planned vs actual
  and over/under, notes.
- Master "Crew" panel: session on/off, QR code, connected followers with their role,
  latency and version warnings.
- Cue sheet export: role picker, preview, share.
- Settings: freewheel limit, spoken count on/off, voice, countdown window.
- Accessibility and dark/light review in the house style (sober, broadcast-gear).
