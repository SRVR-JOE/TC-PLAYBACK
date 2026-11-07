# Spectrum analyser

A measurement-grade spectrum analyser on the Scope page (Spectrum tab) and in the Input
analyzer. It is built for live-event system checks: is the signal clean, what is ringing,
what did the system and room do to what we sent, and how late does it come back.

## What the pro tools do (short survey)

| Tool | What we took from it |
| --- | --- |
| [Rational Acoustics Smaart](https://www.rationalacoustics.com/pages/smaart-rt-features) | The model for the whole page. A single-channel RTA up to 1/48 octave; a dual-channel **transfer function** with magnitude, phase and coherence; a **delay finder** that reads the arrival off the impulse response and "inserts" it as the measurement delay; Fast / Slow / Infinite averaging. See the [feature list](https://support.rationalacoustics.com/support/solutions/articles/150000069194-smaart-rt-feature-list) and the [delay finder guide](https://support.rationalacoustics.com/support/solutions/articles/150000188314). |
| [Smaart v8 user guide](https://www.rationalacoustics.com/download/Smaart-v8-User-Guide.pdf) | Fractional-octave smoothing vs banding, temporal averaging, coherence as a "quality of each data point" indicator, blanking low-coherence data. |
| [FabFilter analyser (Pro-MB help)](https://www.fabfilter.com/help/pro-mb/using/analyzer) | **Tilt** about 1 kHz in dB per octave, 4.5 dB/oct default because it looks like how music is heard; peak hold; spectrum grab. |
| [FabFilter forum on tilt](https://prod.fabfilter.com/forum/add-comment/6750) | Pro-Q 3 shipped with 4.5 dB/oct; Pro-Q 4 started at 0 — operators expect to choose. |
| [iZotope Insight](https://izotope.com/products/insight) | Scrolling **spectrogram** next to the spectrum; loudness and sound field (not repeated here: the app already has meters and an X/Y scope). |
| [SignalScope X (iOS)](https://apps.apple.com/us/app/signalscope-x/id1304775893) | What a phone analyser is expected to have: adjustable FFT, RTA, 2D spectrogram, mic input. |
| Voxengo SPAN, Waves PAZ | Overlay of two channels / mid-side, peak and RMS traces, readout of frequency and note under the cursor. |

## Chosen features and why

- **FFT size 4k / 8k / 16k / 32k, Blackman-Harris or Hann.** Big FFTs resolve the low end
  (2.9 Hz per bin at 16k, 48 kHz); small ones update fastest. Blackman-Harris is the default
  because its side lobes (−92 dB) never mask a quiet tone next to a loud one; Hann is there
  for transfer work and for people used to it.
- **Fractional-octave bands, base-ten (IEC 61260-1): 1/1, 1/3, 1/6, 1/12, 1/24, 1/48.**
  Two ways to show them, as Smaart does:
  - *Bars* = band energy (RTA). Pink noise reads flat, a tone reads its true level.
  - *Line* = smoothed spectrum (mean density). Pink noise falls 3 dB per octave; the
    3 dB/oct slope makes it flat, 4.5 dB/oct matches the FabFilter look for music.
- **Averaging: None, Fast (0.25 s), Slow (1.5 s), Infinite.** Exponential, in seconds, so it
  feels the same at every FFT size. Infinite is a true running mean (for pink-noise checks).
- **Peak hold** (1.5 s hold, then 20 dB/s fall) and a **maximum** trace since Reset.
- **Peak labels** on the three strongest tones: interpolated frequency and level corrected
  for the window (a −12 dBFS sine reads −12 dB wherever it falls between bins).
- **Cursor readout**: frequency, nearest note and cents, level of each trace (and of stored
  traces). Drag on iPhone, pointer on iPad, double tap to clear.
- **Spectrogram**: scrolling 1/48-octave heat map, newest at the top, colour from near-black
  through brown and amber to warm white — readable in a dark FOH, no rainbow.
- **Channels**: left and right, mid and side, or one of them. Input and output can be
  overlaid (Scope page, "Both"): what we sent against what came back.
- **Transfer function** (output = reference, input = measurement): magnitude and phase in
  the chosen smoothing, coherence over the magnitude plot, low-coherence data dimmed below
  0.7 and hidden below 0.3 (switchable). Delay compensation follows the Scope's own
  round-trip measurement by default; **Find delay** reads the arrival from the
  phase-transform impulse response of the last 2.7 s and locks it in, as Smaart's delay
  finder does. "Follow round trip" goes back to automatic.
- **Store A / Store B**: freeze the live trace (spectrum or transfer) and compare against it.

Left out on purpose: loudness (LUFS) and correlation meters already exist elsewhere in the
app; weighting curves, multi-time-window FFT and mic calibration files are possible next
steps.

## How it is built

- `App/Tools/Spectrum/SpectrumDSP.swift` — pure maths (tested): vDSP real FFT, windows,
  band maps, averaging, tilt, peaks, transfer accumulator, delay finder.
- `SpectrumEngine.swift` — one worker thread per analyser. Analyses the newest N samples
  every hop = max(N/8, fs/60): 60 updates a second at 4k, about 12 at 32k. The views read the
  latest frame (a few small arrays) at display rate; no FFT on the main thread.
- Feeds: the Scope page reads `ScopeCore`'s host-timed input and output history (the same
  one the scope overlay and round-trip measurement use); the Input analyzer reads its own
  input history. Capture runs only while the analyser is on screen; nothing ever plays.
- `-spectrumDemo` (DEBUG) feeds a synthetic programme and a pretend room straight into the
  analyser for screenshots; `-spectrumView spectrogram|transfer` picks the view.
