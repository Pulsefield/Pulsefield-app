---
commit: 3a45fbf4419d28b6264c2f83c84df48f3948faaa
---

# Pulsefield

Pulsefield is the app side of a "play the music around you" rhythm game. The intended experience is not to open a local beatmap player, choose a file, and press play. The intended experience is that music is already playing in the room, Pulsefield listens through the microphone, locks onto the track and playback position, asks `Pulsefield/Pulsefield-model` for a real-time 4-key mania chart, and lets the player follow the surrounding music as the chart streams in.

This repository contains the SwiftUI/Xcode client: microphone capture, recognition, local reference resolution, ambient sync, gameplay rendering, and the websocket client that talks to the model endpoint. `Pulsefield/Pulsefield-model` is the companion inference side that produces hit-object tokens for the live chart stream.

## Product target

The core loop is:

1. Music plays outside the app.
2. Pulsefield captures a short microphone window.
3. Recognition identifies the track.
4. The app resolves that track to a local reference audio asset.
5. Ambient sync aligns the live microphone stream to the reference playback position.
6. The app sends the audio path and locked reference time to `Pulsefield/Pulsefield-model`.
7. The model streams hit-object tokens back over websocket.
8. Pulsefield renders a 4-key mania chart that stays aligned with the music happening around the player.

The local library and manual beatmap loading paths exist to support and verify this loop. They are not the main product pitch.

## Current app state

- `PulsefieldMac` and `PulsefieldiOS` both launch `PulsefieldWorkbenchView`.
- macOS debug builds expose the real end-to-end prototype through `Recognition Sync Flow`, available from the toolbar or `Debug > Open Recognition Sync Flow`.
- The recognition sync flow connects microphone capture, ACRCloud recognition, local reference resolution, ambient sync, and the model websocket at `ws://localhost:8765`.
- The workbench also has `Library` and `Play` tabs, but those are support surfaces for indexing reference audio and validating gameplay rendering.
- Shared UI lives in `PulsefieldUI`; domain models and services live in `PulsefieldCore`.

## What is built

### Ambient recognition and sync

- Request real microphone permission through AVFoundation.
- Capture growing microphone clips and submit them to the ACRCloud Identification API.
- Normalize ACRCloud matches into Pulsefield recognition snapshots and canonical track queries.
- Resolve the recognized track against the local library and require confirmation when the match is ambiguous.
- Build an ambient sync reference index from the selected local asset.
- Run live microphone feature extraction and multi-stage ambient sync until a final lock is reached.
- Send the selected audio path and locked reference time to the configured inference websocket.
- Receive and buffer hit-object tokens from the inference endpoint for streaming readiness diagnostics.

### Real-time play renderer

- Render a dark 4-lane mania play scene with live lane input, judgement feedback, combo, accuracy, score, and chart metadata.
- Support keyboard input on macOS and lane touch input on touch platforms.
- Configure scroll speed, audio and visual offsets, judge difficulty, and macOS key bindings.
- Stream hit objects through the gameplay model rather than treating the chart as static UI state.

### Support infrastructure

- Index local reference audio in SQLite so recognized public tracks can be matched to playable local assets.
- Extract audio duration and common metadata with AVFoundation.
- Track file identity with SHA-256, file size, bookmarks, and index status.
- Resolve a recognized or manually entered canonical track to local assets using ISRC, title, artist, album, duration, and fuzzy filename evidence.
- Load `.osu` beatmaps and separate audio files as a renderer/gameplay validation path.
- Record ambient sync fixtures from indexed local assets on macOS debug builds.

### Debug tools

- `PulsefieldACRCloudDebugCLI` can capture microphone audio or clip fixture audio, call the official ACRCloud filescan CLI, and print the normalized result.
- `RecognitionAppModel` and `RecognitionDashboardView` remain as the mock recognition/beatmap handoff seam used by tests and previews.
- `CascadingRecognitionService` models the provider fallback contract, but the production ShazamKit provider is not implemented.
- `BeatmapGenerationProviding` exists for the older reserved beatmap handoff, but the live product direction is the model websocket token stream.

## Project layout

- `Apps/PulsefieldMac` - macOS app entry point and debug recognition window wiring.
- `Apps/PulsefieldiOS` - iOS app entry point.
- `Sources/PulsefieldCore` - domain models, local library services, recognition clients, ambient sync engine, mania4k session model, and inference websocket client.
- `Sources/PulsefieldUI` - SwiftUI workbench, library, recognition, ambient fixture, and mania4k play surfaces.
- `Tests/PulsefieldCoreTests` - focused unit tests for core model transitions, parsing, local resolution, ambient sync, inference tokens, and gameplay behavior.
- `Tools/ACRCloudDebugCLI` - debug-only command line recognition helper.
- `docs` - design notes, current-status writeups, and execution plans.

## Requirements

- Xcode with a Swift 6 compiler.
- XcodeGen `2.45.0` or newer.
- macOS 14.0 and iOS 17.0 are the configured deployment targets.
- Optional for recognition debugging: ACRCloud credentials and, for filescan CLI flows, the `acrcloud` command.
- Optional for the full live-chart loop: the companion `Pulsefield/Pulsefield-model` websocket service.

## Open the project

```sh
xcodegen generate
open Pulsefield.xcodeproj
```

Build the `PulsefieldMac` scheme for macOS or the `PulsefieldiOS` scheme for an iOS simulator.

## Verification commands

```sh
xcodebuild -scheme PulsefieldMac -destination 'platform=macOS' test
xcodebuild -scheme PulsefieldiOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -scheme PulsefieldACRCloudDebugCLI -destination 'platform=macOS' build
```

## Recognition configuration

The macOS debug recognition window loads values from the process environment or from the first `.env` file it finds in the current working directory or project root.

For the live Identification API flow, set:

```sh
ACRCLOUD_IDENTIFICATION_HOST=identify-ap-southeast-1.acrcloud.com
ACRCLOUD_ACCESS_KEY=...
ACRCLOUD_ACCESS_SECRET=...
```

For filescan CLI debugging, set:

```sh
ACRCLOUD_ACCESS_TOKEN=...
ACRCLOUD_CLI=acrcloud
ACRCLOUD_FILESCAN_REGION=eu-west-1
ACRCLOUD_FILESCAN_BUCKETS=23
ACRCLOUD_FILESCAN_ENGINE=1
ACRCLOUD_FILESCAN_AUDIO_TYPE=recorded
```

The filescan helper expects the official CLI to be installed and available on `PATH`:

```sh
pip install acrcloud-cli
```

## Inference endpoint

`InferenceEndpointWebSocketClient` connects to `ws://localhost:8765` by default. That endpoint is expected to be served by the companion `Pulsefield/Pulsefield-model` process during the live-chart prototype. The app sends:

- an `audio_path` message with the selected local audio path
- a `reference_time` message after ambient sync reaches a final lock
- a `stop` message when the debug session is stopped

Incoming `hitobject_tokens` are parsed into mania4k hit objects and buffered until the stream has enough ready-window coverage for rendering diagnostics. The generated token stream is the intended chart source for "play the music around you"; it is not yet wired into the normal `Play` tab as the primary user-facing play path.

## Not done yet

- ShazamKit is still design-only and not wired into the app target.
- The generated token stream from `Pulsefield/Pulsefield-model` is not yet wired into the main `Play` tab as the default gameplay source.
- The normal `Play` tab still plays imported `.osu` charts for renderer validation, not as the main product experience.
- The recognition sync window is debug-only and expects developer-supplied ACRCloud credentials.
- The UI is prototype-grade and does not include account sync, packaging, onboarding, or app-store signing work.
