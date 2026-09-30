# Badasseugi (받아쓰기)

Drop a video or audio file → get a **.smi (SAMI)** subtitle file with the same name next to it, optionally translated.
On-device and fast: Apple **SpeechAnalyzer** for recognition, **Silero VAD** (CoreML) to skip music/noise/silence,
Apple Translation / Google / LLM for translation.

동영상을 끌어다 놓으면 같은 이름의 .smi 자막을 만들어 주는 맥 앱.

- Decoding via ffmpeg (if installed) or AVFoundation — mp4, mov, mkv, webm, avi, mp3, m4a, …
- Word-level timestamps → subtitle cues (sentence ends, pauses, length limits); timing follows container PTS
- Spoken-language auto-detect; translation layouts: translation only / translation + original / original only
- Queue: several files at once (default 3), drag to reorder priority, **start now** (preempts), pause/resume,
  skip files that already have a .smi
- **Resumable**: progress is checkpointed to `name.smi.tmp` next to the video (every ~10 s and on pause/quit);
  the queue is restored after relaunch/crash and continues where it stopped
- CLI: `Badasseugi.app/Contents/MacOS/Badasseugi --cli a.mp4 b.mkv --lang auto --translate apple --to ko --layout both`

## Install

1. Download `badasseugi_<version>_macos_arm64.zip` from [Releases](https://github.com/ziozzang/badasseugi/releases/latest) and unzip.
2. Move **Badasseugi.app** to `/Applications` (or `~/Applications`).
3. The app is ad-hoc signed (not notarized). On first launch either right-click → **Open**, or run
   `xattr -dr com.apple.quarantine /Applications/Badasseugi.app`

Requirements: macOS 26 (Tahoe) or later, Apple Silicon.

## Updates

The app checks GitHub Releases once a day (and via **Check for Updates…**). Updates are verified against the
release's `SHA256SUMS`, installed in place and the app relaunches. Set `NO_UPDATE_CHECK=1` to disable.

## Build & release

```sh
./build.sh                         # → build/Badasseugi.app  (plain swiftc, no Xcode project)
scripts/release.sh 0.2.0 "notes"   # bump version, build, zip + SHA256SUMS, tag, push, GitHub release
```
Release assets follow the same scheme as [sugyeol](https://github.com/ziozzang/sugyeol):
`badasseugi_<version>_macos_arm64.zip` + `SHA256SUMS`.
## Third-party

- `Models/silero-vad-unified-256ms-v6.2.1.mlmodelc` — Silero VAD (MIT, © Silero Team), CoreML conversion by
  FluidInference ([huggingface.co/FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml), MIT).
