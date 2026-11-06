# TC Playback: competitive research report

**Limits of this research:** Reddit blocks this crawler, so I have no posts from r/livesound or r/lightingdesign. The forum evidence below comes from the QLab Google Group, ETC/Hog, Resolume, Dataton, Liberation, the MA manuals and App Store reviews. I couldn't find an app called "AppBand". I also couldn't confirm that Tentacle has a current iOS "Timecode Tool"; the app found under that name is by a different developer. The disguise forum returned nothing.

## 1. Feature matrix

| App | LTC gen | LTC read | Per-side routing | Cue list | Follow modes | Multi-out | Waveform | Price | Platform |
|---|---|---|---|---|---|---|---|---|---|
| **QLab 5** | Yes (Timecode cue, several streams) | Yes (triggers) | Full patch matrix | Yes, the reference | Auto-continue / auto-follow | Yes | Yes | Paid licences | Mac (iPad remote only) |
| **Go Button** (Figure 53) | Not documented | No | Basic | Yes | Crossfade, ducking | Limited | – | Free / Pro (needed to save multiple shows) | iOS |
| **Playback** (MultiTracks) | Yes, SMPTE bus, **Premium seat only** | No | Global bus routing (can't set per song) | Setlist | Autoplay | Yes | Yes | Subscription | iPad |
| **Prime** (Loop Community) | Not documented | No | Routing behind subscription | Setlist | Autoplay | Yes | Yes | Free + subscription | iOS / Mac / Android |
| **Stage Traxx 4** | No (MIDI timecode only) | No | 16 buses | Setlist / sets | Autoplay | Yes | Yes | $29.99 once | iOS |
| **TimeCode Generator** (Haute Technique) | LTC, MIDI TC, Art-Net, multichannel | No | – | No | – | Yes | No | $16.99 | iOS / Mac / visionOS |
| **4:20 LTC Reader & Generator** | Yes | Yes (lock, fps, DF, level, direction) | – | No | – | No | No | $4.99 | iOS |
| **Ableton + AbleSet + LTC Display** | Striped WAV only (Live has no native LTC) | Yes (Max for Live add-on) | Full | Setlist from locators | Yes | Yes | Yes | Live + add-ons | Mac |

The gap: no iOS app combines LTC-aware playback, a QLab-grade cue list, an LTC generator cue and a real signal-health display.

## 2. Top 10 operator pain points

1. **LTC level wrong, so the console drops out.** A grandMA lost lock after about 5 s; the advice was to send about −16 dBFS to land near 0 dBu. The MA manual gives −11 to +15 dBu. https://groups.google.com/d/msgid/qlab/DB3E746B-6DBD-44B0-B7CE-4CA49F229737%40mac.com · https://help.malighting.com/grandMA3/2.0/HTML/fs_connect_smpte_ltc.html
2. **Drop-frame and frame-rate mismatches.** MA reads 29.97 DF as 30 fps. QLab won't trigger on a rate other than the one it's set to. https://help2.malighting.com/grandMA2/en/help/key_fs_connect_smpte_ltc.html · https://groups.google.com/g/qlab/c/yYlughmxNhY
3. **Sample-rate drift.** One user saw 1:05:26 on Arena's counter after 5 minutes of QLab LTC; a reply blamed a 44.1/48 kHz mismatch. https://resolume.com/forum/viewtopic.php?p=80886
4. **LTC reaching the PA.** MultiTracks warns that SMPTE is "white-noise-like… high volume" and must not share an output with audio. https://helpcenter.multitracks.com/en/articles/6371444-how-to-smpte-timecode-in-playback
5. **Crosstalk from music, or processing on the LTC line** (EQ, limiters) causes stutter. https://community.etcconnect.com/control_consoles/hog-lighting-controls/f/hog-os-software-discussion/42080/roadhog4-timecode---how-to/129142
6. **Updates break timecode.** QLab 5.5.2's change log says "Timecode cues will now generate LTC output again." A Playback reviewer: "After every update there are new issues." https://reference.qlab.app/docs/v5/general/change-log/ · https://apps.apple.com/us/app/playback/id751755884
7. **Unreliable generator apps.** LTC-Generator is rated 1.7 stars; reviewers report a "half-second burst" instead of continuous code. https://apps.apple.com/us/app/ltc-generator/id1467829287
8. **iOS interruptions.** Airplane mode doesn't block local notifications. Go Button had to fix interruptions from system alert sounds. https://forscore.co/?p=660
9. **Files go "missing"** when they're linked from iCloud or the Music library. https://apps.apple.com/us/app/go-button/id454017315
10. **Mistaken GO.** The playhead still advances and the operator has to re-select the next cue. Separately, Playback's timecode silently shifts when someone edits the song arrangement. https://groups.google.com/g/qlab/c/KjGM77pPYDQ · https://helpcenter.multitracks.com/en/articles/6371444-how-to-smpte-timecode-in-playback

Two smaller complaints: timecode behind a paywall (Playback Premium), and Bluetooth MIDI pedals that won't pair with Playback.

## 3. Recommendations (prioritised)

1. **Clock status block (v1).** Show a large HH:MM:SS:FF readout with a status word: LOCKED, FREEWHEEL, LOST, or GEN for internal generation. Under it show detected rate as "29.97 DF", direction, and source (file L/R, input, or generator). Turn the readout amber when freewheeling and red after more than 2 frames of loss. Ignore one-frame glitches.
2. **LTC health strip (v1).** Show peak dBFS with a target band of −20 to −10 dBFS and the estimated dBu at the interface. Add frame-error and dropout counters for the session, and a "rate drift" warning when decoded rate and file sample rate disagree.
3. **Show-safety interlock (v1).** In a SHOW lock mode, LTC can't be routed to the same output as music. Warn when the LTC side has gain, EQ or a limiter applied. Warn when the file sample rate differs from the device rate (44.1 vs 48 kHz).
4. **GO / standby model (v1).** Highlight one standby cue. GO fires it and advances. Add double-GO protection with a configurable window (default 1 s) and a red ring on GO while it's active. After a mis-fire, offer a one-tap "back one" that re-arms the previous cue.
5. **Locked stop (v1).** When the screen is locked, STOP and PANIC need a 1 s long-press with a progress ring. Panic uses a configurable fade, never a hard cut on the music side.
6. **Interruption hardening (v1).** Re-assert the audio session after an interruption and log it with timecode. Show a pre-show checklist: Do Not Disturb, Airplane mode, battery and charger, auto-lock off, Guided Access hint.
7. **Self-contained media (v1).** Copy files into the app sandbox and hash them. A playlist with any missing or changed file shows red before showtime, never at GO.
8. **LTC generator cue (v1).** Settings: start TC, rate (23.976 / 24 / 25 / 29.97 DF / 29.97 ND / 30), level, output channel, optional pre-roll. It must generate continuously; do a 2-hour soak test before each release.
9. **Swap L/R and per-side mute (v1).** Make them obvious latching buttons that show state in the transport bar and need confirmation while playing.
10. **Reorder and renumber (v1).** Drag to reorder without changing cue numbers. Renumber is an explicit action ("Renumber selected…", with start and increment, skipping existing numbers, like QLab). Allow decimal inserts (2.5).
11. **Follow modes (v1).** Offer manual, auto-continue (next cue starts immediately) and auto-follow (next cue starts when this one ends), each with a post-wait. Show an arrow glyph in the list.
12. **External display (v1.1).** A full-screen clock on HDMI or AirPlay, with cue name and remaining time for FOH, video and lighting positions.
13. **Multichannel interface out (v1.1).** Route the music pair and LTC to separate channels on a USB interface, with a test-tone/LTC output-ident button.
14. **Network timecode and remote (later).** Art-Net TC and MIDI timecode out, OSC/MIDI GO, and a second-device follower mirroring the clock.
15. **Show report (later).** Export a per-show log of GOs, LTC dropouts, interruptions and level history for advancing with the lighting and video teams.

## 4. UX conventions crews expect

- One standby cue in a high-contrast bar. Playing cues show elapsed and remaining time; the next cue's name is always visible.
- GO on the space bar, plus a hardware keyboard or Bluetooth pedal. ESC means panic or stop-all.
- Long-press to stop when locked. Edit mode is visually distinct from Show mode.
- Frame-rate labels written as "23.976 / 24 / 25 / 29.97 DF / 29.97 ND / 30". Drop frame uses a semicolon separator (`01:00:00;00`).
- A lock-state word plus colour, never colour alone.
- Cue numbers that stay fixed when reordered, prefix support (e.g. "TC1"), and QLab-style notes and memo cues as spacers.
- A sober dark UI: no glow, and a tabular monospace font only for the clock.