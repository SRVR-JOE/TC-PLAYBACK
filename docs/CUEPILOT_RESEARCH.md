# Crew cueing research (CuePilot and similar tools)

Research notes, 2026-11-07. CuePilot is a third-party product and a pending US trademark
(serial 79450026). Don't use its names (CuePilot, CueApp, CueScreen) or its feature labels
(Box View, Step Mode), and don't copy its UI.

## What it is
- Danish desktop tool. The director scripts every camera cut of an act on a timeline that
  follows the show's LTC.
- A studio server follows the LTC and cuts the vision switcher over RS422, and also drives
  GPI, OSC, MIDI and PTZ presets.
- A free phone/tablet app gives each camera operator or department their own countdown to
  their next cue.
- Used at Eurovision since 2013.
- Sources:
  - https://www.cuepilot.com/en/software.html
  - https://www.cuepilot.com/en/quick_start.html
  - https://www.smpte.org/blog/camera-automation-live-orchestra-performances
  - https://escinsight.com/2020/08/07/spirit-in-the-screen-cuepilot-and-the-power-of-camerawork-at-eurovision
  - https://apps.apple.com/app/id1080772988

## What TC Playback already covers
- LTC-following timeline
- Typed cue lanes
- Reference video sync
- Beat grid
- Cue flashes
- Clock and marks strip

TC Playback also has things CuePilot doesn't: console exports, a spectrum analyzer and a
latency scope.

## Ranked additions

| # | Feature | Effort |
|---|---|---|
| 1 | LAN master/follower mode: followers join by QR code or Bonjour and run their own clock, kept in step with small offset corrections rather than a frame stream. The Watch becomes a follower. | L |
| 2 | Per-role view ("I am Cam 3" / "I am SFX"): my lane only, with now, next and the one after. | S |
| 3 | Camera/shot script lane: camera, shot number, shot size, note, and a duration that runs to the next cut. Shotlist table and CSV export. | M |
| 4 | Countdown-first displays: a big bar to my next cue, a grid of every role, an optional spoken 3-2-1, and countdowns in seconds or bars/beats. | S |
| 5 | Rundown: acts in order, each with its own cue set, planned vs actual times, over/under, skip and reorder live. | M |
| 6 | PDF cue sheets per role, with that role's rows highlighted. | S–M |
| 7 | Manual step / timecode-lost handling: next-cue button, freewheel, a lost-TC state, and nudging the follow point. | S–M |
| 8 | Rehearsal takes: record against TC, keep takes per act, A/B them with marks overlaid. | M–L |

Lower priority:
- Personal notes per operator
- Resume following after a restart
- Lyrics lane
- Live OSC/MIDI cue output

## Constraints
- Switcher RS422 and GPI need hardware, so stay with network outputs (OSC, IP switchers).
- UDP multicast on iOS needs Apple's multicast entitlement. Use unicast and Bonjour instead.
- The Local Network permission prompt is unavoidable.

## Related tools
- ShotDriver (closest; per-camera receivers, printed sheets)
- Stagetimer (controller and viewer links)
- Cuez Automator
- Rundown Creator
- Ross OverDrive
- QLab 5 (LTC/MTC chase)
