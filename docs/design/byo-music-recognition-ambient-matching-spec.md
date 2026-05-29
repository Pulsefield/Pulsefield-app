---
commit: 12951cfe9c716b30a06850a8215455215db72931
title: Pulsefield BYO Music Recognition And Ambient Matching Spec
---

# Pulsefield BYO Music Recognition And Ambient Matching Spec

## 0. Scope

本文档只覆盖三件事：

- Phase 1: Local audio metadata resolve
- Phase 2: Ambient music ↔ local audio matching
- Phase 3: ACRCloud public music recognition provider

明确移出本文档：

- Map generation
- Beatmap scheduling
- Gameplay timing
- ACRCloud custom library recognition
- Commercial music downloading
- ShazamKit implementation

当前 repo 已经有 `RecognitionAppModel`、`MockRecognitionService`、`RecognitionServiceProtocol`、`CascadingRecognitionService` 和 reserved beatmap boundary；后续开发应保留这些 seam，不要把 local library、ambient sync、provider implementation 全部塞进一个 model。当前 scaffold 也明确还没有 real music matching、persistence/history 和 beatmap generation。

## 1. Product Contract

### 目标用户流程

User adds local music directories
→ Pulsefield discovers audio files
→ Pulsefield builds internal metadata index
→ user manually resolves metadata, or later uses ACRCloud recognition
→ Pulsefield matches recognized/canonical metadata to a local audio asset
→ Pulsefield listens to environment music
→ Pulsefield estimates where the environment music is inside the matched local audio
→ external map-generation module consumes the match/sync output

### 核心边界

Recognition result = track identity
Local audio asset = usable full audio source
Ambient matching = current position inside local audio
Map generation = separate downstream module

Recognition provider 不拥有 local library。
Local resolver 不依赖 provider raw JSON。
Ambient sync 不依赖 map generation。
Map generation 不进入本文档。

## 2. Shared Domain

### Canonical track

`CanonicalTrack` 是 provider/manual/local metadata 的统一格式。

```swift
public struct CanonicalTrack: Equatable, Sendable {
    public let title: String
    public let artists: [String]
    public let album: String?
    public let durationMS: Int?
    public let isrc: String?
    public let providerIDs: [ProviderTrackID]
}

public struct ProviderTrackID: Equatable, Sendable {
    public enum Provider: String, Sendable {
        case manual
        case local
        case acrCloud
        case shazamKitFuture
    }

    public let provider: Provider
    public let value: String
}
```

### Local audio asset

```swift
public struct LocalAudioAsset: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let directoryID: UUID
    public let fileURLBookmark: Data?
    public let displayPath: String
    public let fileName: String
    public let fileExtension: String
    public let fileSizeBytes: Int64
    public let sha256: String
    public let durationMS: Int
    public let title: String?
    public let artists: [String]
    public let album: String?
    public let albumArtist: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let isrc: String?
    public let releaseYear: Int?
    public let indexedAt: Date
    public let lastSeenAt: Date
    public let status: LocalAudioIndexStatus
}

public enum LocalAudioIndexStatus: Equatable, Sendable {
    case ready
    case missingFile
    case unsupportedFormat
    case unreadable
    case metadataPartial
    case failed(String)
}
```

### Resolve result

```swift
public struct LocalResolveResult: Equatable, Sendable {
    public let asset: LocalAudioAsset
    public let confidence: Double
    public let evidence: [MatchEvidence]
    public let decision: LocalResolveDecision
}

public enum LocalResolveDecision: Equatable, Sendable {
    case autoAccepted
    case requiresUserConfirmation
    case rejected
}

public enum MatchEvidence: Equatable, Sendable {
    case isrcExact
    case titleExact
    case artistExact
    case albumExact
    case durationWithinTolerance(deltaMS: Int)
    case titleFuzzy(score: Double)
    case artistFuzzy(score: Double)
    case fileNameFuzzy(score: Double)
}
```

## 3. Phase 1 — Local Audio Metadata Resolve

### Goal

用户可以设置 music directories。Pulsefield 扫描目录、发现音频文件、抽取 metadata、建立内部 index，并把 `CanonicalTrack` resolve 到本地 `LocalAudioAsset`。

Phase 1 不需要 ACRCloud。
Phase 1 不需要 ambient microphone sync。
Phase 1 不涉及 map generation。

### User-facing scene

```text
Local Music Library
Directories
[Add Directory]
[Remove Directory]
[Rescan]
Index Status
discovered: ...
indexed: ...
failed: ...
missing: ...
last scan: ...
Manual Resolve Test
title
artist
album
ISRC
duration
[Resolve Against Local Library]
Resolve Result
matched file
confidence
match evidence
decision: auto / confirm / rejected
```

### Required services

```swift
public protocol LocalMusicDirectoryManaging: Sendable {
    func addDirectory(_ url: URL, recursive: Bool) async throws
    func removeDirectory(id: UUID) async throws
    func listDirectories() async -> [MusicLibraryDirectory]
}

public protocol LocalAudioLibraryIndexing: Sendable {
    func rescanAll() async
    func rescanDirectory(id: UUID) async
    func status() async -> LocalAudioLibraryStatus
}

public protocol LocalAudioMetadataExtracting: Sendable {
    func extract(from fileURL: URL) async throws -> ExtractedAudioMetadata
}

public protocol LocalTrackResolving: Sendable {
    func resolve(_ track: CanonicalTrack) async -> [LocalResolveResult]
}
```

### Storage

使用 SQLite 或等价本地数据库。不要用单个 JSON 文件扛整个 music library。

最小 tables：

- `music_directories`
- `local_audio_assets`
- `local_audio_metadata`
- `local_audio_hashes`
- `local_resolve_history`

不要把 audio blob 存进 DB。DB 只存 metadata、hash、bookmark、index status。

### Directory access

macOS 需要考虑 security-scoped bookmark。绝对路径不能作为唯一身份。

文件身份至少使用：

- security-scoped bookmark when available
- sha256
- file size
- duration
- metadata
- lastSeenAt

文件被移动或删除时，不要 silent delete。标记为：

```swift
.missingFile
```

### Supported formats

第一版建议支持：

- mp3
- m4a
- aac
- wav
- flac
- aiff

不支持的文件进入：

```swift
.unsupportedFormat
```

### Matching policy

排序规则：

1. ISRC exact
2. title + artist + duration close
3. title + artist + album
4. filename + duration
5. fuzzy fallback

默认 decision：

```text
confidence >= 0.90        → autoAccepted
0.70 <= confidence < 0.90 → requiresUserConfirmation
confidence < 0.70         → rejected
```

Duration tolerance：

```text
±2s  → strong
±8s  → weak, require confirmation
>8s  → normally reject
```

Brutal point: title-only match 不可靠。它会被 remix、live version、cover、radio edit、remaster、sped-up/slowed version 轻易打爆。

### Phase 1 files

- `Sources/PulsefieldCore/Domain/CanonicalTrackDomain.swift`
- `Sources/PulsefieldCore/Domain/LocalAudioDomain.swift`
- `Sources/PulsefieldCore/Services/LocalLibrary/LocalMusicDirectoryStore.swift`
- `Sources/PulsefieldCore/Services/LocalLibrary/LocalAudioLibraryDatabase.swift`
- `Sources/PulsefieldCore/Services/LocalLibrary/LocalAudioLibraryIndexer.swift`
- `Sources/PulsefieldCore/Services/LocalLibrary/LocalAudioMetadataExtractor.swift`
- `Sources/PulsefieldCore/Services/LocalLibrary/LocalTrackResolver.swift`
- `Sources/PulsefieldUI/Features/LocalLibrary/LocalLibraryDashboardView.swift`
- `Sources/PulsefieldUI/Features/LocalLibrary/LocalResolveDebugView.swift`

### Acceptance criteria

- User can add/remove music directories.
- App can recursively scan selected directories.
- App persists directory access across launches.
- App extracts title, artist, album, duration, ISRC when available.
- App computes stable file hash.
- App stores index in local DB.
- App can resolve manually entered `CanonicalTrack` to local files.
- Ambiguous matches require confirmation.
- Missing files are marked stale/missing, not silently deleted.
- No recognition provider is required for Phase 1.
- No map-generation code is touched.

## 4. Phase 2 — Ambient Music ↔ Local Audio Matching

### Goal

给定一个已经 resolved 的 `LocalAudioAsset`，Pulsefield 通过 microphone 监听环境音乐，并估算：

```text
environment music is currently at referenceTimeMS inside this local audio file
```

Phase 2 只做 matching / sync estimate。
Phase 2 不生成 map。
Phase 2 不调 ACRCloud。
Phase 2 不解决 “what song is this?”，只解决 “is the environment currently matching this local file, and at what offset?”。

### Core output

```swift
public struct SyncEstimate: Equatable, Sendable {
    public let hostTime: ContinuousClock.Instant
    public let referenceTimeMS: Double
    public let confidence: Double
    public let driftPPM: Double?
    public let latencyMS: Double?
    public let source: SyncSource
}

public enum SyncSource: String, Sendable {
    case manual
    case controlledPlayback
    case localFeatureCorrelation
    case userNudge
}
```

`referenceTimeMS` 是 local audio timeline 中的位置。
`hostTime` 是系统 monotonic clock。
外部模块只应该消费 `SyncEstimate`，不要直接读 microphone buffer。

### State model

```swift
public enum AmbientSyncState: Equatable, Sendable {
    case idle
    case preparingIndex
    case listening
    case locking
    case locked(SyncEstimate)
    case drifting(SyncEstimate)
    case lost
    case failed(String)
}
```

State transition：

```text
idle
→ preparingIndex
→ listening
→ locking
→ locked
→ drifting
→ lost
```

### Sync index

```swift
public struct LocalAudioSyncIndex: Equatable, Sendable {
    public let assetID: UUID
    public let durationMS: Int
    public let sampleRate: Double
    public let frameHopMS: Double
    public let onsetEnvelopeURL: URL
    public let spectralSummaryURL: URL?
    public let chromaURL: URL?
    public let version: Int
    public let createdAt: Date
}
```

第一版不要过度复杂。推荐最小实现：

- onset envelope
- coarse spectral summary
- optional chroma

### Required services

```swift
public protocol LocalAudioSyncIndexing: Sendable {
    func buildIndex(for asset: LocalAudioAsset) async throws -> LocalAudioSyncIndex
    func loadIndex(for assetID: UUID) async -> LocalAudioSyncIndex?
}

public protocol AmbientAudioCapturing: Sendable {
    func start() async throws
    func stop() async
    func latestWindow(durationMS: Int) async -> AmbientAudioWindow?
}

public protocol AmbientSyncEstimating: Sendable {
    func start(asset: LocalAudioAsset, index: LocalAudioSyncIndex) async throws
    func stop() async
    func currentEstimate() async -> SyncEstimate?
    func currentState() async -> AmbientSyncState
}
```

### Matching algorithm

第一版使用可 debug 的 feature correlation，不要直接上复杂黑盒。

1. Build local sync index from `LocalAudioAsset`.
2. Capture rolling microphone window.
3. Convert mic window into same feature representation.
4. Search candidate offsets in local index.
5. Pick best correlation peak.
6. Convert best peak into `SyncEstimate`.
7. Smooth the estimate.
8. Expose locked/drifting/lost state.

Search policy：

```text
first lock:
  wide search over plausible track range
locked:
  narrow search around predicted reference time
lost:
  widen search again
```

Confidence policy：

```text
locked:
  high confidence for consecutive windows
drifting:
  confidence degraded but predicted timeline still plausible
lost:
  low confidence for too long
  or best offset jumps beyond hard threshold
```

Suggested defaults:

- mic rolling window: 3–8s
- soft correction threshold: 80–150ms
- hard relock threshold: 300–500ms
- lost timeout: 3–6s low confidence

这些是 initial tuning values，不是 protocol guarantee。

### Manual controls

Developer scene 必须允许人工修正，否则 debug 会很痛苦。

```text
[Start Matching]
[Stop]
[Nudge -50ms]
[Nudge +50ms]
[Force Relock]
```

`userNudge` 应该进入 `SyncSource` 或 debug event log。

### Developer scene

```text
Ambient Matching
Selected Local Asset
title / artist / path / duration
Sync Index
status: missing / building / ready / failed
version
feature files
Microphone
permission
level
rolling window duration
Matching
state
reference time
confidence
drift
last correction
last peak score
Controls
[Build Index]
[Start Matching]
[Stop]
[Nudge -50ms]
[Nudge +50ms]
[Force Relock]
```

### Phase 2 files

- `Sources/PulsefieldCore/Domain/AmbientSyncDomain.swift`
- `Sources/PulsefieldCore/Services/AmbientSync/LocalAudioSyncIndexer.swift`
- `Sources/PulsefieldCore/Services/AmbientSync/AmbientAudioCaptureService.swift`
- `Sources/PulsefieldCore/Services/AmbientSync/FeatureCorrelationSyncEstimator.swift`
- `Sources/PulsefieldCore/Services/AmbientSync/SyncClockFilter.swift`
- `Sources/PulsefieldUI/Features/AmbientSync/AmbientMatchingDashboardView.swift`

### Acceptance criteria

- App can build sync index for a `LocalAudioAsset`.
- App can start microphone capture.
- App can compare environment audio against selected local audio.
- App reports idle/listening/locking/locked/drifting/lost.
- App outputs `SyncEstimate` while locked.
- `SyncEstimate.referenceTimeMS` progresses monotonically during stable playback.
- Short noise does not instantly break lock.
- Pause/seek/wrong track eventually causes drifting/lost/relock.
- No map-generation module is implemented here.
- No ACRCloud dependency is required for Phase 2.

## 5. Phase 3 — ACRCloud Public Music Recognition Provider

### Goal

接入 ACRCloud 作为 public music recognition provider。用户在 demo UI 中输入自己的 ACRCloud credentials。识别结果只输出 normalized track identity 和 coarse recognition anchor，然后交给 Phase 1 local resolver。

Phase 3 不做 custom library recognition。
Phase 3 不上传用户本地库到 ACRCloud。
Phase 3 不把 ACRCloud result 当作 playable/downloadable asset。
Phase 3 不实现 ShazamKit。

### Provider boundary

ACRCloud provider 只做三件事：

1. capture short audio clip
2. send signed request to ACRCloud Identification API
3. map provider response into app-owned domain

Repo 当前 recognition architecture 已经建议使用 shared capture service：一次录制 8-10s temporary clip，然后传给 provider clients；ACRCloud provider 只负责签名并上传同一段 clip 到 `POST /v1/identify`，不要让每个 provider 自己管理录音。

### Domain output

```swift
public struct RecognitionProviderResult: Equatable, Sendable {
    public let provider: RecognitionProvider
    public let track: CanonicalTrack
    public let anchor: RecognitionAnchor?
    public let confidence: Double
    public let rawDebugPayloadID: UUID?
}

public enum RecognitionProvider: String, Sendable {
    case mock
    case acrCloud
    case shazamKitFuture
}

public struct RecognitionAnchor: Equatable, Sendable {
    public let provider: RecognitionProvider
    public let recognizedAtHostTime: ContinuousClock.Instant
    public let capturedWindowStartHostTime: ContinuousClock.Instant
    public let capturedWindowEndHostTime: ContinuousClock.Instant
    public let providerReferenceTimeMS: Double?
    public let confidence: Double
}
```

`providerReferenceTimeMS` 是 coarse anchor，不是 Phase 2 的 final sync estimate。

### Credential model

```swift
public struct ACRCloudCredential: Equatable, Sendable {
    public let host: String
    public let accessKey: String
    public let accessSecretRef: String
}
```

Rules：

- `access_secret` 存 Keychain
- `host/access_key` 可以存普通 config
- 不要 commit credentials
- 不要 log `access_secret`
- 不要把 secret 放 `rawDebugPayload`
- 提供 clear/reset/test config

当前 repo recognition architecture 也建议只持久化 minimal live config：provider order、ACRCloud host、access key、access secret、enabled flag。

### ACRCloud API implementation

ACRCloud Identification API 使用 `multipart/form-data`，可提交 audio 或 fingerprint；官方建议不要上传大文件，少于 15 秒的文件通常更好。请求字段包括 `sample`、`access_key`、`sample_bytes`、`timestamp`、`signature`、`data_type`、`signature_version`，并且 `sample_bytes` 文档要求 file size below 5M Bytes。

Signature 使用：

- HMAC-SHA1
- Base64

`string_to_sign`：

```text
http_method + "\n"
+ http_uri + "\n"
+ access_key + "\n"
+ data_type + "\n"
+ signature_version + "\n"
+ timestamp
```

ACRCloud 文档中的 API reference 明确要求 signed request，并给出上述 string/signature structure。

### Required services

```swift
public protocol RecognitionAudioCapturing: Sendable {
    func captureClip(durationMS: Int) async throws -> RecognitionAudioClip
}

public struct RecognitionAudioClip: Equatable, Sendable {
    public let fileURL: URL
    public let durationMS: Int
    public let byteCount: Int
    public let capturedWindowStartHostTime: ContinuousClock.Instant
    public let capturedWindowEndHostTime: ContinuousClock.Instant
}

public protocol RecognitionProviderClient: Sendable {
    func recognize(_ clip: RecognitionAudioClip) async -> RecognitionProviderResult
}

public protocol RecognitionCredentialStoring: Sendable {
    func saveACRCloudCredential(_ credential: ACRCloudCredential) async throws
    func loadACRCloudCredential() async -> ACRCloudCredential?
    func clearACRCloudCredential() async throws
}
```

### ACRCloud files

- `Sources/PulsefieldCore/Services/Recognition/Live/AudioClipCaptureService.swift`
- `Sources/PulsefieldCore/Services/Recognition/Live/ACRCloudRecognitionProvider.swift`
- `Sources/PulsefieldCore/Services/Recognition/Live/ACRCloudRequestSigner.swift`
- `Sources/PulsefieldCore/Services/Recognition/Live/ACRCloudResponseMapper.swift`
- `Sources/PulsefieldCore/Services/Recognition/Live/RecognitionCredentialStore.swift`
- `Sources/PulsefieldUI/Features/Recognition/ACRCloudCredentialView.swift`
- `Sources/PulsefieldUI/Features/Recognition/RecognitionProviderDebugView.swift`

### Phase 3 flow

User enters ACRCloud host/access_key/access_secret
→ app stores secret safely
→ user taps Recognize
→ app captures short clip
→ ACRCloud provider signs request
→ ACRCloud provider uploads clip
→ response mapper creates `CanonicalTrack` + `RecognitionAnchor`
→ Phase 1 `LocalTrackResolver` searches local library
→ if matched, user can start Phase 2 Ambient Matching
→ if not matched, UI asks user to import/resolve owned audio

### Developer scene

```text
Recognition Provider
Provider
[Mock]
[ACRCloud]
ACRCloud Config
host
access_key
access_secret
[Test Config]
[Clear Credentials]
Recognition
[Capture & Recognize]
Result
provider
title
artist
album
ISRC
duration
confidence
coarse provider offset if available
Local Resolve
[Resolve Against Local Library]
matched / ambiguous / no local asset
Next
[Start Ambient Matching]
```

### Acceptance criteria

- User can enter ACRCloud host/access_key/access_secret.
- Secret is stored securely.
- App can clear credentials.
- App captures one short temporary clip.
- App sends signed `multipart/form-data` request to ACRCloud `/v1/identify`.
- App maps response into `CanonicalTrack`.
- App maps provider timing into `RecognitionAnchor` when available.
- Raw response is available only in debug-safe storage.
- Recognition result can be resolved against Phase 1 local index.
- No custom library recognition exists in this phase.
- No local library upload exists in this phase.
- No map-generation code is touched.
- Mock provider remains available.

## 6. App-level Composition

### Recommended ownership

```text
PulsefieldAppModel
  ├─ LocalLibraryModel
  │    ├─ LocalMusicDirectoryStore
  │    ├─ LocalAudioLibraryIndexer
  │    └─ LocalTrackResolver
  │
  ├─ AmbientMatchingModel
  │    ├─ LocalAudioSyncIndexer
  │    ├─ AmbientAudioCaptureService
  │    └─ FeatureCorrelationSyncEstimator
  │
  └─ RecognitionProviderModel
       ├─ MockRecognitionService
       ├─ AudioClipCaptureService
       └─ ACRCloudRecognitionProvider
```

### Dependency direction

```text
RecognitionProviderModel
  outputs CanonicalTrack
LocalLibraryModel
  consumes CanonicalTrack
  outputs LocalAudioAsset / LocalResolveResult
AmbientMatchingModel
  consumes LocalAudioAsset
  outputs SyncEstimate
External map module
  may consume LocalAudioAsset + SyncEstimate
  is not specified here
```

This direction matters. If Phase 3 starts calling ambient matching directly, or Phase 2 starts depending on ACRCloud response JSON, the architecture is already drifting.

## 7. Implementation Order

1. Add `CanonicalTrackDomain` and `LocalAudioDomain`.
2. Add local DB schema.
3. Add directory add/remove/rescan.
4. Add metadata extraction and file hashing.
5. Add `LocalTrackResolver` and manual resolve UI.
6. Add `LocalAudioSyncIndex` format.
7. Add sync index builder.
8. Add ambient microphone rolling capture.
9. Add feature-correlation estimator.
10. Add `AmbientMatchingDashboardView`.
11. Add ACRCloud credential storage.
12. Add `AudioClipCaptureService` for recognition.
13. Add `ACRCloudRequestSigner`.
14. Add `ACRCloudRecognitionProvider`.
15. Map ACRCloud result into `CanonicalTrack`.
16. Connect recognition result → local resolver → ambient matching.

## 8. Key Design Considerations

### 1. Local asset is the source of truth

`CanonicalTrack` can identify a song, but only `LocalAudioAsset` can be used as full audio source.

### 2. Ambient matching is not recognition

Recognition answers:

```text
what track is this?
```

Ambient matching answers:

```text
where is the environment playback inside this known local track?
```

Keep these two separate.

### 3. Provider offset is not enough

ACRCloud timing, when available, should be treated as a coarse anchor. Phase 2 must produce its own `SyncEstimate`.

### 4. Matching must be explainable

Every resolve result needs `MatchEvidence`. Without it, duplicate titles and alternate versions will be impossible to debug.

### 5. Keep Mock alive

`MockRecognitionService` is not throwaway. It is required for UI previews, local resolver tests, and provider-free development.

### 6. No custom recognition in Phase 3

Do not add custom bucket, local fingerprint upload, or “recognize against user library” in Phase 3. That is a separate future project.

### 7. No map-generation coupling

This spec ends at:

- `LocalAudioAsset`
- `SyncEstimate`
- `AmbientSyncState`

Anything after that belongs to the separate map-generation module.

## 9. Minimal End-to-End Demo

The first useful demo should be:

User adds a music directory.
Pulsefield indexes local audio files.
User manually enters title/artist/ISRC/duration.
Pulsefield resolves metadata to one local file.
Pulsefield builds sync index for that file.
User plays the same song externally.
Pulsefield listens through microphone.
Pulsefield enters locked state.
Pulsefield displays current `referenceTimeMS` with confidence.

Then Phase 3 upgrades the first half:

```text
manual metadata input
→ ACRCloud recognition result
→ same LocalTrackResolver
→ same AmbientMatchingModel
```

That is the clean route. It keeps the system testable and prevents recognition, local storage, ambient matching, and downstream generation from collapsing into one fragile feature.
