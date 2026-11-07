# Song analysis ("Find moments")

"Find moments" in the Cue points timeline bar listens to a track's programme audio and suggests the
musical moments that usually get cues: **hits**, **drops**, **builds**, **breakdowns**, **stops** and
**section changes** (with a Verse / Chorus guess). Suggestions are ghost marks in a Suggestions lane.
Nothing becomes a cue point until someone accepts it.

Everything runs on device with Accelerate (vDSP / vForce). There is no server, no third-party package
and no Core ML model. Code: `App/Tools/CuePoints/Analysis/`. Tests: `AppTests/ToolsSongAnalyzerTests.swift`.

## What the established tools do (short survey)

| Source | Technique | What we took |
| --- | --- | --- |
| [Bello et al., *A Tutorial on Onset Detection in Music Signals*](https://www.cs.bu.edu/fac/snyder/cs583/Literature%20and%20Resources/bello_onset_tutorial.pdf) (IEEE TSAP 2005) | Spectral flux, HFC, phase and complex-domain detection functions; peak picking against an adaptive threshold | Detection functions are combined after normalising each one; peaks are picked against a local context, not a global threshold. |
| [Masri & Bateman HFC, as in Essentia `OnsetDetection`](https://essentia.upf.edu/reference/std_OnsetDetection.html) | High-frequency content: weight each bin by its frequency | An HFC-weighted flux is one of the three curves. It is what makes a crash or a stab stand out from a kick. |
| [Duxbury/Bello complex-domain onsets](https://dafx.de/paper-archive/2004/P_207.PDF) | Magnitude and phase prediction, good for soft tonal onsets | **Not used.** Cue-worthy hits are percussive and loud; soft tonal onsets are the opposite of what we want, and the phase term doubles the cost. |
| [Böck & Widmer, *Maximum Filter Vibrato Suppression* (SuperFlux, DAFx 2013)](https://dafx.de/paper-archive/details/0oee-99Z88WL7pSo749gcA), [reference code](https://github.com/CPJKU/SuperFlux), [madmom](https://madmom.readthedocs.io/en/v0.16/modules/features/onsets.html) | Log-magnitude flux against a max-filtered (3 bins) spectrum a couple of frames back | Used as the main onset curve. Vibrato vocals and synth wobble stop producing false hits. |
| [Foote, *Automatic audio segmentation using a measure of audio novelty* (ICME 2000)](https://audiolabs-erlangen.de/resources/MIR/FMP/C4/C4S4_NoveltySegmentation.html) (FMP notebook) | Self-similarity matrix, Gaussian checkerboard kernel slid along the diagonal; novelty peaks = boundaries | Used for section boundaries, on beat-synchronous features, with a four-bar kernel. |
| [McFee & Ellis, Laplacian segmentation (librosa)](https://librosa.org/doc/latest/auto_examples/plot_segmentation.html) | Recurrence + path graph, spectral clustering of eigenvectors, beat-synchronous CQT | Beat-synchronous features and the idea of labelling repeats by clustering. The spectral-clustering step itself is **not** used (eigen-decomposition and a cluster count to choose; too much machinery for a guess the operator overrides anyway). |
| [Yadati et al., *Detecting Drops in EDM* (ISMIR 2014)](https://scrapbox.io/DancePedia/Detecting%20Drops%20in%20Electronic%20Dance%20Music%3A%20Content%20based%20approaches%20to%20a%20socially%20significant%20music%20event) and [follow-up](https://github.com/felixmeyer6/drop-detector) | Compare energy after a candidate point with the build before it | Drops = an energy jump into a loud passage, scored higher after a build or a stop. |
| [Krebs, Böck & Widmer downbeat RNN + DBN (ISMIR 2016)](https://archives.ismir.net/ismir2016/paper/000249.pdf), madmom | Neural beat/downbeat activations decoded with a dynamic Bayesian network | **Not used.** madmom's model files are CC BY-NC-SA (non-commercial). The app keeps `TempoDetector`'s DSP downbeat (the beat-in-bar with the most kick energy). |
| [Beat This!](https://huggingface.co/cstr/beat-this-GGUF) (MIT code and weights) | Transformer beat/downbeat tracker | The one permissively licensed model worth considering for Core ML. Not adopted: it is tens of MB, needs conversion and a spectrogram front end, and the gain is in hard tempo cases the operator fixes in one tap (×2 / ÷2, set downbeat). Worth revisiting if downbeats turn out to be the weak point on real shows. |

## The pipeline

Input: every channel except the LTC one (`Track.ltcChannel`), summed to mono and decimated to about
11 kHz (`TempoDetector.readProgramme`, the same reader the tempo detector uses). The LTC side is never
read, and a test proves it: a silent programme with hot LTC on the other side gives **no** suggestions.

1. **Tempo grid.** `TempoDetector` (spectral-flux tempogram × autocorrelation comb, least-squares phase,
   kick-weighted downbeat). If the track already has a grid, that grid is used instead and no new one is offered.
2. **Fine STFT** (512 points, hop 64, ≈ 5.8 ms), giving three onset curves:
   - SuperFlux: positive differences of log-magnitude against a 3-bin maximum filter of the frame two back.
   - HFC-weighted flux: positive log-magnitude differences, each bin weighted by its frequency.
   - Low-band flux below 150 Hz (the kick).

   Each curve has a 0.25 s moving floor removed and is divided by its 99th percentile. The onset
   curve is their sum, with the low band at half weight. The hop level (dBFS) is kept too.
3. **Coarse STFT** (4096 points, hop 1024, ≈ 93 ms), giving loudness, level below 150 Hz, spectral
   centroid, 12-bin chroma (80 Hz to 3 kHz) and 12 cepstral coefficients (DCT of 24 log bands,
   50 Hz to 5 kHz, as a cheap stand-in for MFCCs). The chroma and band sums are two `vDSP_mmul` per block.

### Hits
Peaks in the onset curve (local maximum over ±50 ms). The strength is mostly **contrast**: the
peak divided by the 80th percentile of the other onset peaks within ±4 s (the level of the regular
loud events, kick and snare), plus a little absolute size and a bonus on a downbeat. A crash and
kick on the one stands out; the groove under it doesn't. With a grid, a hit within 35 ms of an
eighth-note line moves onto it, so accepted hits are on the music. Off-grid stabs stay where they are.

### Stops
Runs of at least 0.25 s below the silence floor inside the music. The floor is the louder of
−62 dBFS and the track's 95th-percentile level minus 45 dB. The strength comes from how deep the
cut is and how long it lasts. The time is when the sound ends (hop-accurate, about 6 ms).

### Builds
A tension curve: loudness (dB) plus 6 × brightness (octaves of spectral centroid), smoothed over
1 s. For every start point, linear fits over 3, 5, 8, 12 and 20 s. It's a build when the curve
rises at least 5 dB with R² ≥ 0.75 **and** no single second carries more than half the rise. That
last test is what separates a ramp from a step into a loud chorus. The strongest ramps that don't
overlap are kept. A build starts on the nearest bar (or beat).

### Drops
The mean loudness of the next 2 s minus the previous 2 s. A drop is a peak of at least 4 dB that
lands in a loud passage (within 4 dB of the track's 75th percentile). It scores higher with a bass
jump, after a build that was still rising, or straight after a stop. The time is the strongest
onset within ±0.35 s, then the nearest bar line if it is within a beat (else the nearest beat).

### Breakdowns
The same comparison over ±4 s, falling by at least 5 dB. It doesn't count if the level after is
near silence (that's a stop), or if the fall is in the last few seconds (that's the ending). The
time is the sharpest fall, moved onto a bar.

### Sections and labels
1. Features averaged per beat (0.5 s steps without a grid), z-scored per dimension, smoothed over
   about a bar. Chroma and cepstrum are L2-normalised separately, so harmony and timbre count equally.
2. Self-similarity S = F·Fᵀ (`vDSP_mmul`). Foote novelty with a Gaussian-tapered checkerboard
   kernel four bars each side (`vDSP_dotpr` per kernel row).
3. Boundaries are novelty peaks above 20 % of the track's highest, at least three bars apart,
   moved onto the nearest bar line.
4. Labels: each segment's mean feature vector joins the most similar earlier group if the cosine
   similarity is ≥ 0.55; otherwise it starts a new group (A, B, C…). The most repeated group is
   **Chorus**, and a tie goes to the louder group. Other repeated groups are **Verse**. One-off
   sections are **Intro** (first), **Outro** (last) or **Bridge**. Song sections are numbered from
   1 in time order (Verse 1, Chorus 1, Verse 2), matching the label presets. The UI says plainly
   that these are guesses, and each row shows its repeat letter.
5. "Accept sections" adds the section marks and writes the sections into the beat grid. When the
   track has no grid, it creates one from the detected tempo.

### Vocal entry: skipped
On a full mix there is no spectral cue that reliably says "a voice starts here" without source
separation. Harmonicity, the 4–7 Hz vibrato modulation and formant-band energy all fire on leads,
guitars and pads too, and many vocals enter at the same moment as a section change, which is
already suggested. A wrong "Vocal in" would cost more trust than a missing one, so it is left out.
A small permissive vocal-activity model would be the way to add it later.

## Review UI
- **Find moments** in the timeline bar opens the panel (a popover on iPad, a sheet on iPhone). The
  analysis keeps running if the panel is closed, and the button shows "Listening 40%".
- **Suggestions** lane under the cue lanes. Each suggestion is a thin line whose height and opacity
  follow its strength, with an outlined name flag when there is room (hits are lines only). No
  glow, no fill colour.
- The **Fewer / More** slider sets the strength threshold. Kind filters are check boxes with counts.
- Tapping a suggestion (in the lane or the list) **seeks** there and never starts playback. The
  chosen suggestion gets **Accept** and **Reject** in the lane; the list has both on every row.
  **Accept all shown** and **Accept sections** are at the bottom.
- Accepting goes through `MomentAcceptance`, which follows the same rules as a live mark. The time
  snaps to a frame. The type is matched by name (Hits → Lights, Drops → Special FX, Sections →
  Cue), falling back to the default type. Ripple cue numbers apply once a type has typed numbers.
  Repeated labels are numbered as "Number repeated labels" says. Accepting the same moment twice
  adds nothing.
- **Cache**: `Application Support/SongAnalysis/<track id>-<hash>.json`. The hash covers the file
  size, modification date, first and last 256 KB, LTC side and analyser version. Rejected and
  accepted suggestions are saved with it.

## Measured results
See "Accuracy" below. These numbers come from the test suite on synthetic audio, plus a run on
real show tracks.

## Accuracy
_Filled in from the test run._

## Limits
- **Constant tempo.** Hits snap to and sections are counted on one tempo grid. Songs with tempo
  changes, rubato intros or live drift get the grid's errors; the snap only moves a hit 35 ms or
  less, so it never drags a hit far.
- **Downbeat** is the DSP guess from `TempoDetector` (kick on the one). In half-time feels,
  reggae, or songs whose loudest kick is on 3, bar lines, and so section starts, can be off by
  two beats. Fix the downbeat in the Tempo panel and run Find moments again.
- **Section labels are guesses.** The algorithm only knows "this sounds like that". A pre-chorus
  that sounds like the chorus joins it; a chorus with a new arrangement on its last pass can split
  off as a Bridge. Intro/Outro only mean "doesn't repeat, at the edge".
- **Energy moments** follow loudness, so heavily limited masters (little dynamic range) give
  fewer drops and breakdowns. Lower the sensitivity threshold (More) to see the smaller ones.
- **Hits** are judged against the beat around them, so a song made entirely of big hits (a drum
  feature) shows only the ones that stand out. That's by design.
- **No vocal entries** (see above).
- **Mono analysis.** Stereo effects (a hit panned hard on one side) count the same as centred ones.
