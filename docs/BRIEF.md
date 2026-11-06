# TC Playback — product brief (read this first)

PIXEL HAUS app (never Solotech-branded). Universal iPhone + iPad, iOS 18+, SwiftUI + AVAudioEngine,
SwiftData. Bundle `com.pixelhaus.tcplayback`. Swift 5 language mode in the app target.

## Who uses it
A live-event video/AV engineer running timecode shows. An iPad (or iPhone in a pinch) at FOH or
in the video world plays the show track: music/stems on one side, SMPTE LTC on the other, feeding
media servers (disguise, Resolume), lighting consoles (grandMA), and the band's IEMs. It has to be
trustworthy at show-time and look like pro broadcast gear.

## Must-haves (from the owner, verbatim intent)
1. **Import a track** (stereo L/R; mono OK) from Files / AirDrop / drag-drop on iPad.
2. **Per-side play/mute:** play or mute the Left source and the Right source independently.
3. **Swap:** swap which side each source plays out of.
4. **Auto-recognise TC:** if a side contains LTC, detect it automatically and show the
   **timecode clock** (lock state, rate incl. 29.97 DF, level). If none, the clock shows track time.
5. **Meters** (L/R, dBFS, peak hold, clip) and an **oscilloscope** (see the LTC waveform).
6. **Editable playlist:** drag to reorder, **renumber**, edit cue numbers, delete/duplicate.
7. **Play my TC back + my own playlists:** an LTC *generator* cue type (start TC, rate,
   duration, side), and **multiple saved playlists** that persist and play.
8. **Clean, classy, PRO GUI**, dark mode (light mode also supported), **changeable clock colour**.
   "Hella slick" — but sober, not flashy.
9. Be better than the existing apps (see docs/RESEARCH.md when it lands).

## Differentiators we're building (beyond the competition)
- Decodes LTC from *both* sides continuously, even when that side is muted (you can mute TC to
  the PA and still see it). Free-wheel across dropouts, discontinuity counter, reverse detect.
- Per-cue saved routing (mute L/R, swap, gain) — the show plays the same every night.
- Cue-list operation like QLab: standby cue, big GO, follow modes (stop / auto-continue / loop).
- Waveform overview with LTC lane marked, scrub (disabled in Show Lock).
- Show Lock: one toggle that prevents accidental edits/scrubs/stops during the show (stop needs
  a long-press when locked).
- External-input TC reader mode (read LTC from the mic/line input) — a pocket TC reader.
- Big readable clock that scales from iPhone to iPad full screen; tap the clock for full-screen
  clock mode.
- Keep-awake while playing, background audio, lock-screen/Control Centre transport, hardware
  keyboard shortcuts on iPad (Space = GO, Esc = stop, ↑/↓ = standby move).
- Route display (Speaker / Headphones / USB interface) so you know where audio is going.

## Visual direction (non-negotiable)
Broadcast control software (Lawo, Riedel, Evertz, Ross DashBoard), not "AI app".
- Flat graphite surfaces from `Theme`, hairline dividers, generous but tight spacing.
- Colour ONLY for state: lock lamp, GO/standby/stop tally, meters, clip.
- Monospaced type ONLY for numbers (TC, times, dB, cue numbers). Labels in SF Pro, sentence case.
- NO glow, neon, bloom, drop-shadow halos, decorative gradients, hazard stripes, rainbow accents,
  pill badges everywhere, ALL-CAPS letter-spaced mono labels, emoji, or developer wording in the
  UI ("engine", "tap", "buffer", "snapshot"). Operator language: "Cue", "Standby", "GO", "Lock".
- SF Symbols, thin weights. Haptics on GO/stop. Animations short and functional (≤ 0.2 s).

## Layouts
**iPad landscape (primary):** left column ≈ 340 pt = playlist (cue # · title · duration · TC
start · follow icon; standby row highlighted amber bar, playing row green bar). Right/main area:
top = big clock + status line; then waveform overview; then a row of [oscilloscope (flex) |
stereo meters | routing panel (L play/mute, R play/mute, Swap, gain)]; bottom = transport bar
(previous · stop · GO (largest) · next · elapsed / remaining · follow mode). Toolbar: playlist
picker/name, add (import / generator cue), Show Lock, settings.
**iPad portrait:** same, playlist in a collapsible sidebar (NavigationSplitView).
**iPhone portrait:** clock (top), waveform, routing + horizontal meters row, scope (collapsible),
transport pinned at bottom; playlist is a second tab or a sheet pulled up. **iPhone landscape:**
clock-forward view (clock + transport + lamps).

## Module ownership (each agent works in its own git worktree; touch ONLY your files)
| Module | Files | Owner |
|---|---|---|
| TCKit (Swift package) | `Packages/TCKit/**` | TCKit agent |
| Audio engine | `App/Audio/**` | Engine agent |
| Library + show control | `App/Library/**` | Library agent |
| Visuals | `App/UI/Visuals/**` | Visuals agent |
| App shell, screens, theme, app entry, icon | `App/UI/Screens/**`, `App/UI/Theme/**`, `App/TCPlaybackApp.swift`, `App/Resources/**` | Shell agent |
| project.yml, scripts, docs | — | Lead (main session). Ask in your final report if you need a project.yml change. |

Contract files (marked `CONTRACT FILE`) define frozen APIs between modules — implement, extend
additively, never break signatures. If a contract is genuinely wrong, work around it and say so in
your final report; the lead will reconcile at merge.

Build: `scripts/build.sh` (iPhone sim), `scripts/build.sh sim-ipad`, `scripts/build.sh test`.
TCKit: `cd Packages/TCKit && swift test`. Commit your work on your branch with clear messages.
