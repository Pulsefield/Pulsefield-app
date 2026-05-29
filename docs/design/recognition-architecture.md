---
commit: 4f7e18d
title: Recognition Architecture
---

# Recognition Architecture

Pulsefield should treat `ShazamKit` and `ACRCloud` as provider clients behind one shared capture pipeline.

That is the reusable lesson from [`MusicRecognizer`](https://github.com/aleksey-saenko/MusicRecognizer): its best idea is not the exact Android implementation, but the separation between:

- capture/orchestration
- provider-specific recognition clients
- normalized domain output

## Reference Takeaways

The `MusicRecognizer` repo keeps provider choice and provider configuration in domain models, then resolves them through a factory:

- [`RecognitionProvider.kt`](https://github.com/aleksey-saenko/MusicRecognizer/blob/82d2b85274c91df64f1d003a9b464150803f6f92/core/domain/src/main/java/com/mrsep/musicrecognizer/core/domain/recognition/model/RecognitionProvider.kt)
- [`RecognitionServiceConfig.kt`](https://github.com/aleksey-saenko/MusicRecognizer/blob/82d2b85274c91df64f1d003a9b464150803f6f92/core/domain/src/main/java/com/mrsep/musicrecognizer/core/domain/preferences/RecognitionServiceConfig.kt)
- [`RecognitionServiceFactoryImpl.kt`](https://github.com/aleksey-saenko/MusicRecognizer/blob/82d2b85274c91df64f1d003a9b464150803f6f92/core/recognition/src/main/java/com/mrsep/musicrecognizer/core/recognition/RecognitionServiceFactoryImpl.kt)

It also keeps recording separate from remote matching so the same captured audio can be retried across providers and fallback policies.

Pulsefield should keep that structure, but not copy the repo literally:

- `MusicRecognizer` is Android-first and modularized for a much larger product.
- Its Shazam integration is not the Apple-platform path we should follow here.
- On Apple platforms, the correct primary integration is the official `ShazamKit` framework.

## Recommended Pulsefield Shape

### 1. Capture Layer

Create one capture service responsible for microphone access, audio session setup, and writing one short temporary clip per recognition attempt.

Recommended first cut:

- use `AVAudioEngine`
- record a single shared clip of `8-10s`
- write a temporary `m4a` or `caf` file
- hand that file to every provider client

This is the seam represented by `RecognitionAudioCapturing` and `RecognitionAudioClip`.

### 2. Provider Clients

Keep each provider isolated behind a small client protocol:

- `ShazamKitRecognitionProvider`
- `ACRCloudRecognitionProvider`

Each provider should only do provider-specific work:

- `ShazamKit`: generate a `SHSignature` from the captured clip, then match it with `SHSession`
- `ACRCloud`: sign and upload the same clip to `POST /v1/identify`

This is intentionally simpler than letting every provider own its own recording flow.

### 3. Orchestration Layer

Use one coordinator service to own fallback order and shared telemetry.

Recommended default order:

1. `ShazamKit`
2. `ACRCloud`

Reasoning:

- `ShazamKit` is the official Apple-platform integration and should be the primary path on iOS/macOS.
- `ACRCloud` is the best fallback when Shazam returns no match or when you want richer third-party IDs such as `ISRC`.

The scaffold now models this with `CascadingRecognitionService`.

### 4. Domain Normalization

Both providers should map into the existing app-owned types:

- `RecognizedTrack`
- `RecognitionAnchor`
- `RecognitionSnapshot`

The app model and future beatmap pipeline should never depend on raw provider JSON or SDK models.

### 5. Configuration Store

Persist only the minimum live configuration:

- provider order
- `ACRCloud` host
- `ACRCloud` access key
- `ACRCloud` access secret
- an enabled/disabled flag for live recognition

`ShazamKit` does not need user-entered credentials, but it does require Apple capability setup and a signed build.

## Minimal Setup

### ShazamKit

Official Apple docs:

- [ShazamKit overview](https://developer.apple.com/documentation/ShazamKit)
- [Generate a signature from audio](https://developer.apple.com/documentation/shazamkit/generating-a-signature-from-an-audio-buffer)
- [Enable ShazamKit for an App ID](https://developer.apple.com/help/account/services/shazamkit/)

Minimum requirements:

- add `ShazamKit.framework` to the app target
- enable the `ShazamKit` app service for the app identifier
- build with signing/capabilities enabled for live testing
- keep `NSMicrophoneUsageDescription`

Important repo implication:

The current Pulsefield scaffold explicitly avoids Apple team/signing work. That is compatible with the mock path, but not with live `ShazamKit` recognition. Once live `ShazamKit` is enabled, the project stops being a zero-signing prototype.

### ACRCloud

Official docs:

- [Recognize Music tutorial](https://docs.acrcloud.com/tutorials/recognize-music)
- [Identification API reference](https://docs.acrcloud.com/reference/identification-api/identification-api)
- [Service Usage: Recorded Audio vs Line-in Audio](https://docs.acrcloud.com/service-usage)

Minimum project setup:

- create an `Audio & Video Recognition` project
- use the `ACRCloud Music` bucket
- choose `Recorded Audio`
- choose `Audio Fingerprinting`
- enable `3rd Party ID Integration` if Pulsefield wants `ISRC` and downstream IDs
- save `host`, `access_key`, `access_secret`

Minimum client setup:

- upload short clips with `multipart/form-data`
- use `data_type=audio`
- sign the request with `HMAC-SHA1`
- keep uploads under the documented size limit and under about `15s`

Implementation note:

`MusicRecognizer` uses the ACRCloud HTTP API directly, and that is also the recommended Pulsefield starting point. ACRCloud still documents an iOS SDK, but its iOS SDK reference page currently shows "Last updated 5 years ago", so the API route is the safer minimal integration unless a native SDK feature is specifically needed.

## Minimal Milestone For Pulsefield

Do not build the full `MusicRecognizer` product. The smallest useful milestone is:

1. Keep the current `RecognitionAppModel`.
2. Replace the single live-service seam with `capture -> provider clients -> cascade`.
3. Implement one shared capture service.
4. Implement `ShazamKitRecognitionProvider`.
5. Implement `ACRCloudRecognitionProvider`.
6. Keep `MockRecognitionService` for previews/tests.
7. Add one signed dev configuration for live iPhone testing.

That is enough to validate:

- microphone permissions
- live provider ordering
- normalized track mapping
- beatmap handoff from a real recognition snapshot

## Suggested Next Files

If this architecture is implemented fully, the next files should be:

- `Sources/PulsefieldCore/Services/Recognition/Live/AudioClipCaptureService.swift`
- `Sources/PulsefieldCore/Services/Recognition/Live/ShazamKitRecognitionProvider.swift`
- `Sources/PulsefieldCore/Services/Recognition/Live/ACRCloudRecognitionProvider.swift`
- `Sources/PulsefieldCore/Services/Recognition/Live/ACRCloudRequestSigner.swift`
- `Sources/PulsefieldCore/Services/Recognition/Live/ProviderResponseMappers.swift`
