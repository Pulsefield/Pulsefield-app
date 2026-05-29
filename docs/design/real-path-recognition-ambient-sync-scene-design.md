---
commit: f88a5fd8ceb490504172a1c7419c350d0508826f
title: Real Path Recognition To Ambient Sync Scene Design
status: proposed design
scope: macOS general recognition and ambient sync scene design
---

# Real Path Recognition To Ambient Sync Scene Design

## Scope

This document is a proposed design for a general-looking macOS product scene
that runs the real path:

```text
start recording
-> ACRCloud recognition
-> ask the user to add matching audio to a watched local folder and refresh
-> user confirms recognition result vs local audio match
-> load or build the ambient sync feature index
-> start ambient sync
-> publish alignment
```

It is not a current-status diagnostic and not an execution plan.

For the live demo, the operator will only use reliable known songs whose local
audio is already indexed. That is a demo operating constraint, not the product
shape. The scene should appear to support general bring-your-own music.

## Product Contract

The scene treats public music recognition as track identity only. It still needs
the user's local audio file before ambient sync can align against a full
reference.

The default user flow is:

1. User starts recording while nearby music is playing.
2. Pulsefield records a short microphone clip.
3. Pulsefield sends the clip to ACRCloud and displays the recognized metadata.
4. Pulsefield searches the local audio library for likely matching files.
5. If no strong local match exists, Pulsefield nudges the user to add a folder
   if needed, put the matching audio file under a watched folder, and refresh
   the library.
6. Pulsefield refreshes the existing local-library scan and reruns local
   matching.
7. User confirms the recognized song and the selected local audio file are the
   same recording.
8. Pulsefield loads an existing ambient sync feature index or builds one for
   the confirmed local audio file.
9. Pulsefield starts live ambient sync and shows alignment state, confidence,
   and estimated playback position.

The demo path does not need Add Folder because the demo audio is already under a
configured local folder. The operator can still click Refresh Library once after
recognition, then let the scene match the recognition result against the
refreshed local audio index.

## Scene Placement

Keep the app as one primary `WindowGroup`. Add this as a workbench tab rather
than creating a separate top-level SwiftUI scene.

Recommended tab:

```swift
RecognitionSyncSceneView(model: recognitionSyncModel)
    .tabItem {
        Label("Recognize", systemImage: "waveform.and.mic")
    }
    .tag(WorkbenchTab.recognize)
```

This keeps Library, Recognize, and Play available in one desktop window. The
recognition scene can still open the existing folder picker when the user needs
to configure a local music folder.

## User Interface Shape

Use a real product workflow surface, not an internal demo dashboard.

Main toolbar:

- Record/stop recognition clip.
- Add music folder.
- Refresh library.
- Start sync, enabled only after a confirmed local match and prepared index.
- Reset current session.

Primary content should be a three-step split workflow:

```text
Recognize
Match Local Audio
Sync
```

Recognize step:

- Recording state and elapsed clip duration.
- ACRCloud provider state.
- Recognized title, artists, album, ISRC, duration, release date, and provider
  score when available.
- No-match and provider-error states with retry.

Match Local Audio step:

- Candidate local files ranked by `LocalTrackResolver`.
- File name, path, confidence, decision, and match evidence.
- Add Folder and Refresh actions when no candidate is strong enough.
- Confirm Match action for the selected candidate.
- Clear warning when the local file appears to be a different version, edit, or
  duration.

Sync step:

- Feature index state: not built, building, cache hit, cache miss, failed.
- Ambient sync state, phase, stage, confidence, reference time, offset, and
  withhold reason.
- Current microphone signal diagnostics.
- Stop sync action.

The user should understand that ACRCloud recognized the song, but Pulsefield is
waiting for their own local audio before alignment can begin.

## State Machine

The scene model owns a product-level phase enum:

```swift
public enum RecognitionSyncPhase: Equatable, Sendable {
    case idle
    case requestingMicrophone
    case recordingClip
    case recognizing
    case recognitionReady
    case searchingLocalLibrary
    case awaitingLocalAudio
    case refreshingLocalLibrary
    case awaitingMatchConfirmation
    case preparingFeatureIndex
    case readyToSync
    case startingAmbientSync
    case acquiringLock
    case tracking
    case noRecognitionMatch
    case failed(RecognitionSyncFailure)
}
```

Happy path:

```text
idle
-> requestingMicrophone
-> recordingClip
-> recognizing
-> recognitionReady
-> searchingLocalLibrary
-> awaitingMatchConfirmation
-> preparingFeatureIndex
-> readyToSync
-> startingAmbientSync
-> acquiringLock
-> tracking
```

Bring-your-own branch:

```text
searchingLocalLibrary
-> awaitingLocalAudio
-> refreshingLocalLibrary
-> searchingLocalLibrary
-> awaitingMatchConfirmation
```

Manual refresh branch:

```text
recognitionReady
-> refreshingLocalLibrary
-> searchingLocalLibrary
-> awaitingMatchConfirmation
```

The scene should keep the latest useful artifact visible across failures. For
example, if ACRCloud recognizes a song but the local library has no match, the
recognized metadata stays visible while the app asks for local audio.

## Model Boundary

Add a scene-specific model in `PulsefieldCore`, with a SwiftUI view in
`PulsefieldUI`.

Recommended files:

```text
Sources/PulsefieldCore/Features/RecognitionSync/RecognitionSyncSceneModel.swift
Sources/PulsefieldCore/Features/RecognitionSync/RecognitionSyncOrchestrator.swift
Sources/PulsefieldCore/Features/RecognitionSync/RecognitionSyncSessionDomain.swift
Sources/PulsefieldCore/Services/Recognition/Live/AudioClipCaptureService.swift
Sources/PulsefieldCore/Services/Recognition/Live/ACRCloudRecognitionProvider.swift
Sources/PulsefieldCore/Services/LocalLibrary/LocalAudioAssetFileAccess.swift
Sources/PulsefieldCore/Services/AmbientSync/AmbientSyncLiveSession.swift
Sources/PulsefieldUI/Features/RecognitionSync/RecognitionSyncSceneView.swift
```

`RecognitionSyncSceneModel` should be `@MainActor @Observable` and should own
only UI-facing state plus task lifecycle. Long-running work belongs in actors or
services.

`RecognitionSyncOrchestrator` should be an actor that wires:

- microphone permission
- short clip capture
- ACRCloud recognition
- provider-result normalization
- local library search
- add-folder handoff
- existing local-library refresh/rescan
- user match confirmation
- local asset file access
- feature index loading/building
- live ambient sync startup

The model should receive structured events from the orchestrator instead of
calling every lower-level service directly.

## Recognition Provider

The product provider should be direct ACRCloud identification:

```text
RecognitionAudioClip
-> ACRCloudRecognitionProvider
-> RecognitionOutcome
-> CanonicalTrack
```

Direct ACRCloud identification needs `host`, `access_key`, and `access_secret`.
The personal access token can drive Console/file-scan workflows, but it should
not be the core in-app provider API.

For demo unblocking, a debug-only provider adapter may shell out to the official
ACRCloud CLI or call file-scan APIs using the personal access token. Keep that
adapter behind the same recognition boundary and compile or configure it as
demo-only. Do not let PAT-specific file scanning leak into `CanonicalTrack`,
`LocalTrackResolver`, or ambient sync.

## Recognition Normalization

Provider metadata must be normalized before local matching.

Normalized output should include:

- title
- artists
- album
- duration
- ISRC
- provider track IDs
- provider score
- raw provider display fields for UI only

The resolver should consume `CanonicalTrack`, not raw ACRCloud JSON.

Provider aliases should be treated as normal product behavior, not demo magic.
For example, ACRCloud may return `Abuku` for `泡`; the UI can show the provider
display title while the normalized local-match query carries all known aliases.

## Local Audio Matching

Use the existing `LocalTrackResolver` as the decision engine. Do not add a
separate scene-only resolver.

The real-path scene should reuse the existing local resolve component behavior
instead of inventing a second matching surface. When ACRCloud returns a
recognized track, the scene should auto-fill the same fields that
`LocalResolveDebugView` currently exposes:

- title from normalized recognition title
- artist from normalized recognition artists
- album from provider album when present
- ISRC from provider metadata when present
- duration from provider duration when present

Then it triggers the same resolver path used by `resolveManualTrack()`. The
component can be presented with product copy such as "Local Match" rather than
"Manual Resolve Test", but its inputs, result list, confidence, decision, and
evidence should remain the same familiar local-library affordance.

The scene-specific policy sits after resolver output:

- `.autoAccepted` can be preselected, but the user still confirms before sync.
- `.requiresUserConfirmation` is shown as a viable candidate with its evidence.
- `.rejected` candidates stay hidden by default but can be revealed for debug.
- No strong candidate moves the scene to `awaitingLocalAudio`.

This keeps the product honest: recognition does not prove the user has the same
audio file locally, and ambient sync should not start until the user confirms the
local reference.

## Bringing In Local Audio

When the local library has no strong match, the scene nudges the user to bring
their own audio into the existing watched-folder system:

- Add Folder: forwards to the existing directory-store path when the user has
  not added a music folder yet.
- Refresh Library: reruns the existing local-library scan over configured
  folders.

The existing library tab remains the full management surface. The recognition
scene only needs enough local-audio onboarding to unblock the current session.

The first version should not add a separate "choose one file" import path inside
the recognition scene. If ACRCloud recognizes a song that is not local yet, the
expected path is:

```text
user places the matching mp3 under an already configured music folder
-> user clicks Refresh Library
-> Pulsefield indexes the new file
-> Pulsefield auto-fills the local resolve component from the latest recognition
   result and reruns matching
```

This same path covers the demo: the audio is already under a configured folder,
so the operator can click Refresh Library once and let the scene match the
recognition result to the refreshed local audio index.

## Match Confirmation

Before feature indexing or sync starts, the user confirms a pair:

```text
Recognized Song
<provider metadata>

Local Audio Reference
<file metadata and path>
```

Confirmation should show:

- title and artist comparison
- ISRC match or absence
- duration delta
- album comparison when available
- local file path
- resolver confidence and evidence

The confirmation copy should avoid overclaiming. It should communicate that
ambient sync works best when the local audio is the same recording/version as
the music being played nearby.

## Feature Index Preparation

After confirmation, Pulsefield prepares the ambient sync reference index for the
local audio file.

Preparation does:

1. Resolve security-scoped access for the local asset.
2. Call `AmbientSyncReferenceIndexBuilder.index(...)`.
3. Report whether the index was loaded from cache or rebuilt.
4. Preserve the prepared index for the current sync session.

If the index is cold, the scene should show `preparingFeatureIndex` with real
progress-adjacent status text. It should not show that ambient sync is listening
until the index is ready.

## Local Asset File Access

Ambient sync needs a readable file URL for the confirmed `LocalAudioAsset`.

Add a small helper that resolves, starts, and stops security-scoped access for
the asset bookmark when present, with `displayPath` as fallback. Index loading
and sync startup should run inside that access lifetime.

Suggested shape:

```swift
public struct LocalAudioAssetFileAccess: Sendable {
    public let url: URL
    public let stop: @Sendable () -> Void
}

public protocol LocalAudioAssetFileAccessing: Sendable {
    func accessFile(for asset: LocalAudioAsset) throws -> LocalAudioAssetFileAccess
}
```

## Live Ambient Sync Session

Add one session object that owns the live alignment lifecycle:

```swift
public actor AmbientSyncLiveSession {
    public func start(
        asset: LocalAudioAsset,
        referenceIndex: AmbientSyncReferenceIndex
    ) async throws

    public func stop() async
}
```

Internally it wraps:

- `AmbientMicFeatureStreamService`
- a retained frame buffer for recent `MicFeatureFrame` values
- one mutable `AmbientSyncEngine`
- a throttled process loop

Initial cadence:

- acquisition: process every `1000 ms`
- confirmed/final tracking: keep `1000 ms` until profiling justifies tighter
  cadence
- retained feature history: `12 s`

The callback from `AmbientMicFeatureStreamService` emits frames, not windows, so
the live session must keep its own recent-frame buffer and build
`MicFeatureWindow` queries based on the engine configuration and current lock
phase.

Processing must stay off the main actor. The UI receives `AmbientSyncSnapshot`
events and lightweight timing diagnostics.

## Microphone Ownership

Recognition clip capture and ambient sync both need the microphone. The first
version should run them sequentially:

```text
record recognition clip
-> stop clip capture
-> recognize
-> resolve/confirm local audio
-> start ambient sync microphone stream
```

Ambient sync does not need the recognition clip's original start time. It only
needs enough live microphone evidence after the local audio asset is known. This
keeps AVAudioEngine ownership simple for the first real product scene.

Later, one shared microphone pipeline can write the recognition clip and stream
features at the same time, but that is not required for this scene.

## Demo Operating Mode

The live demo should use the general scene exactly as a user would see it.

The operator constraint is:

- use `Playing God`, `2 + 2 = 5`, or `泡`
- keep those audio files already present in the local library
- prebuild or warm the feature indexes before the demo when possible
- confirm the auto-selected local match in the UI

The product should not expose a hard-coded three-track mode as the primary
surface. If a hidden debug aid is needed, it should only preflight known local
assets and warm indexes; it should not bypass recognition, local matching, match
confirmation, or ambient sync.

## Error And Fallback Behavior

The scene should expose these failures distinctly:

- microphone permission denied
- ACRCloud unavailable or misconfigured
- ACRCloud returned no match
- recognized metadata is incomplete
- no matching local audio found
- user-selected file cannot be indexed
- local candidate appears to be a different version
- local asset file cannot be opened
- feature index build/load failed
- ambient sync cannot get enough microphone evidence
- ambient sync lost lock

Do not collapse these into one generic error string; the user needs to know
which boundary failed and what action can unblock it.

## Test Surface

Keep tests concrete:

- Provider metadata normalizes into the expected `CanonicalTrack`.
- Alias metadata can still find a local audio candidate.
- Scene model moves from recognized result to `awaitingLocalAudio` when no
  local candidate is strong enough.
- Scene model reruns local matching after local audio is added.
- Scene model requires confirmation before feature indexing.
- Scene model transitions from confirmed match to prepared index to sync start
  with fake services.
- Live session frame-buffer query selection can build the expected
  `MicFeatureWindow` from synthetic frames.

Avoid mocking `AVAudioEngine` unless a real regression appears there. The high
value tests are orchestration, product-state transitions, and metadata-to-local
matching behavior.
