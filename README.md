# Pulsefield

Pulsefield is a SwiftUI scaffold for a future music-reactive rhythm app. The current milestone is intentionally limited to:

- a compile-correct iOS/macOS project shell
- real microphone permission handling
- a mock recognition flow for UI and architecture work
- app-owned domain models and service abstractions
- a reserved beatmap-generation interface for future `mania4k` work
- documented live-provider architecture for a future `ShazamKit -> ACRCloud` pipeline

## Current milestone

Real ShazamKit matching is intentionally gated. This repo does **not** require:

- an Apple Developer team
- ShazamKit capability setup
- signing or entitlement work for the recognition prototype

The live-recognition seam is reserved behind `RecognitionServiceProtocol`. The app currently boots with `MockRecognitionService`, while microphone permission still uses AVFoundation so the permission UX is real.

## Open the project

1. Run `xcodegen generate`
2. Open `Pulsefield.xcodeproj`
3. Build the `Pulsefield` scheme for macOS or an iOS simulator

## What is implemented

- `RecognitionAppModel` coordinates permission state, mock listening state, recognition snapshots, and beatmap reservation state.
- `MicrophonePermissionService` uses `AVCaptureDevice` for real authorization checks and prompts.
- `MockRecognitionService` simulates a recognition round-trip and returns a stable sample song.
- `UnavailableLiveRecognitionService` marks the future live-recognition milestone without blocking today’s prototype.
- `CascadingRecognitionService` and related provider-domain models define the intended live architecture: capture once, then try `ShazamKit` followed by `ACRCloud`.
- `BeatmapGenerationProviding` and related models reserve the handoff boundary for future `mania4k` generation work.

See [`docs/recognition-architecture.md`](docs/recognition-architecture.md) for the provider architecture and minimal live-setup checklist.

## What is not implemented yet

- ShazamKit capability or entitlements
- real music matching
- beatmap generation
- persistence and history

## Verification

The scaffold is intended to pass:

- `xcodebuild -scheme Pulsefield -destination 'platform=macOS' test`
- `xcodebuild -scheme Pulsefield -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
