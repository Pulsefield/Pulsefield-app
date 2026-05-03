import AVFoundation
import Foundation

public struct AmbientSyncFixtureTargetAsset: Codable, Equatable, Sendable {
    public let id: UUID
    public let displayPath: String
    public let fileName: String
    public let sha256: String
    public let durationMS: Int
    public let title: String?
    public let artists: [String]
    public let album: String?
    public let isrc: String?

    public init(asset: LocalAudioAsset) {
        id = asset.id
        displayPath = asset.displayPath
        fileName = asset.fileName
        sha256 = asset.sha256
        durationMS = asset.durationMS
        title = asset.title
        artists = asset.artists
        album = asset.album
        isrc = asset.isrc
    }
}

public struct AmbientSyncFixtureRecordingRequest: Equatable, Sendable {
    public let targetAsset: LocalAudioAsset
    public let recordingGroup: String
    public let takeLabel: String
    public let notes: String?

    public init(
        targetAsset: LocalAudioAsset,
        recordingGroup: String,
        takeLabel: String,
        notes: String? = nil
    ) {
        self.targetAsset = targetAsset
        self.recordingGroup = recordingGroup
        self.takeLabel = takeLabel
        self.notes = notes
    }
}

public struct AmbientSyncFixtureRecordingSession: Equatable, Sendable {
    public let recordingID: UUID
    public let startedAt: Date
    public let audioURL: URL
    public let metadataURL: URL
    public let targetAsset: AmbientSyncFixtureTargetAsset
    public let recordingGroup: String
    public let takeLabel: String

    public init(
        recordingID: UUID,
        startedAt: Date,
        audioURL: URL,
        metadataURL: URL,
        targetAsset: AmbientSyncFixtureTargetAsset,
        recordingGroup: String,
        takeLabel: String
    ) {
        self.recordingID = recordingID
        self.startedAt = startedAt
        self.audioURL = audioURL
        self.metadataURL = metadataURL
        self.targetAsset = targetAsset
        self.recordingGroup = recordingGroup
        self.takeLabel = takeLabel
    }
}

public struct AmbientSyncFixtureRecordingMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recordingID: UUID
    public let createdAt: Date
    public let stoppedAt: Date
    public let durationMS: Int
    public let audioFileName: String
    public let recordingGroup: String
    public let takeLabel: String
    public let sampleRate: Double
    public let channelCount: Int
    public let targetAsset: AmbientSyncFixtureTargetAsset
    public let notes: String?

    public init(
        schemaVersion: Int = 1,
        recordingID: UUID,
        createdAt: Date,
        stoppedAt: Date,
        durationMS: Int,
        audioFileName: String,
        recordingGroup: String,
        takeLabel: String,
        sampleRate: Double,
        channelCount: Int,
        targetAsset: AmbientSyncFixtureTargetAsset,
        notes: String?
    ) {
        self.schemaVersion = schemaVersion
        self.recordingID = recordingID
        self.createdAt = createdAt
        self.stoppedAt = stoppedAt
        self.durationMS = durationMS
        self.audioFileName = audioFileName
        self.recordingGroup = recordingGroup
        self.takeLabel = takeLabel
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.targetAsset = targetAsset
        self.notes = notes
    }
}

public enum AmbientSyncFixtureRecordingError: Error, Equatable, Sendable {
    case alreadyRecording
    case notRecording
    case unsupportedInputFormat
    case writeFailed(String)
}

extension AmbientSyncFixtureRecordingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A fixture recording is already running."
        case .notRecording:
            return "No fixture recording is running."
        case .unsupportedInputFormat:
            return "The microphone input format is not supported."
        case .writeFailed(let message):
            return "Could not write fixture recording: \(message)"
        }
    }
}

public final class AmbientSyncFixtureRecorder: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public let outputDirectoryURL: URL
        public let fileExtension: String
        public let tapBufferSizeFrames: AVAudioFrameCount

        public init(
            outputDirectoryURL: URL = AmbientSyncFixtureRecorder.defaultFixtureDirectoryURL(),
            fileExtension: String = "caf",
            tapBufferSizeFrames: AVAudioFrameCount = 4_096
        ) {
            precondition(!fileExtension.isEmpty, "fileExtension must not be empty.")
            precondition(tapBufferSizeFrames > 0, "tapBufferSizeFrames must be positive.")

            self.outputDirectoryURL = outputDirectoryURL
            self.fileExtension = fileExtension
            self.tapBufferSizeFrames = tapBufferSizeFrames
        }
    }

    private struct ActiveRecording {
        let session: AmbientSyncFixtureRecordingSession
        let request: AmbientSyncFixtureRecordingRequest
        let audioFile: AVAudioFile
        let sampleRate: Double
        let channelCount: Int
        var frameCount: AVAudioFramePosition
        var writeError: Error?
    }

    public let configuration: Configuration

    private let engine: AVAudioEngine
    private let encoder: JSONEncoder
    private let activeRecordingLock = NSLock()
    private var activeRecording: ActiveRecording?

    public init(
        configuration: Configuration = Configuration(),
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.configuration = configuration
        self.engine = engine
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    deinit {
        stopDiscardingMetadata()
    }

    public func startRecording(request: AmbientSyncFixtureRecordingRequest) throws -> AmbientSyncFixtureRecordingSession {
        guard readActiveRecording() == nil else {
            throw AmbientSyncFixtureRecordingError.alreadyRecording
        }

        try FileManager.default.createDirectory(
            at: configuration.outputDirectoryURL,
            withIntermediateDirectories: true
        )

        let inputNode = engine.inputNode
        let inputBus: AVAudioNodeBus = 0
        let inputFormat = inputNode.inputFormat(forBus: inputBus)
        guard inputFormat.commonFormat == .pcmFormatFloat32,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0
        else {
            throw AmbientSyncFixtureRecordingError.unsupportedInputFormat
        }

        let startedAt = Date()
        let recordingID = UUID()
        let fileStem = Self.fileStem(
            group: request.recordingGroup,
            takeLabel: request.takeLabel,
            fallbackName: request.targetAsset.fileName,
            timestamp: startedAt
        )
        let audioURL = configuration.outputDirectoryURL
            .appendingPathComponent(fileStem)
            .appendingPathExtension(configuration.fileExtension)
        let metadataURL = configuration.outputDirectoryURL
            .appendingPathComponent(fileStem)
            .appendingPathExtension("ambient-sync-fixture.json")
        let session = AmbientSyncFixtureRecordingSession(
            recordingID: recordingID,
            startedAt: startedAt,
            audioURL: audioURL,
            metadataURL: metadataURL,
            targetAsset: AmbientSyncFixtureTargetAsset(asset: request.targetAsset),
            recordingGroup: Self.normalizedLabel(request.recordingGroup, fallback: "ambient-sync"),
            takeLabel: Self.normalizedLabel(request.takeLabel, fallback: "take")
        )
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: audioURL, settings: inputFormat.settings)
        } catch {
            throw AmbientSyncFixtureRecordingError.writeFailed(error.localizedDescription)
        }

        replaceActiveRecording(ActiveRecording(
            session: session,
            request: request,
            audioFile: audioFile,
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(inputFormat.channelCount),
            frameCount: 0,
            writeError: nil
        ))

        inputNode.installTap(
            onBus: inputBus,
            bufferSize: configuration.tapBufferSizeFrames,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: inputBus)
            engine.stop()
            replaceActiveRecording(nil)
            throw AmbientSyncFixtureRecordingError.writeFailed(error.localizedDescription)
        }

        return session
    }

    public func stopRecording() throws -> AmbientSyncFixtureRecordingMetadata {
        guard readActiveRecording() != nil else {
            throw AmbientSyncFixtureRecordingError.notRecording
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        guard let recording = takeActiveRecording() else {
            throw AmbientSyncFixtureRecordingError.notRecording
        }

        if let writeError = recording.writeError {
            throw AmbientSyncFixtureRecordingError.writeFailed(writeError.localizedDescription)
        }

        let stoppedAt = Date()
        let durationMS = Int((Double(recording.frameCount) / recording.sampleRate * 1_000).rounded())
        let metadata = AmbientSyncFixtureRecordingMetadata(
            recordingID: recording.session.recordingID,
            createdAt: recording.session.startedAt,
            stoppedAt: stoppedAt,
            durationMS: durationMS,
            audioFileName: recording.session.audioURL.lastPathComponent,
            recordingGroup: recording.session.recordingGroup,
            takeLabel: recording.session.takeLabel,
            sampleRate: recording.sampleRate,
            channelCount: recording.channelCount,
            targetAsset: recording.session.targetAsset,
            notes: recording.request.notes?.trimmedNilIfEmpty
        )

        do {
            let data = try encoder.encode(metadata)
            try data.write(to: recording.session.metadataURL, options: .atomic)
        } catch {
            throw AmbientSyncFixtureRecordingError.writeFailed(error.localizedDescription)
        }

        return metadata
    }

    public static func defaultFixtureDirectoryURL() -> URL {
        if let repoURL = repositoryRootURL() {
            return repoURL
                .appendingPathComponent("LocalFixtures", isDirectory: true)
                .appendingPathComponent("ambient-sync-voice-memos", isDirectory: true)
        }

        #if os(macOS)
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
        #else
        let baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #endif

        return baseURL
            .appendingPathComponent("PulsefieldLocalFixtures", isDirectory: true)
            .appendingPathComponent("ambient-sync-voice-memos", isDirectory: true)
    }

    public static func suggestedRecordingGroup(for asset: LocalAudioAsset) -> String {
        let candidates = [
            asset.title,
            URL(fileURLWithPath: asset.fileName).deletingPathExtension().lastPathComponent
        ].compactMap { $0 }

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return "ambient-sync"
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        activeRecordingLock.lock()
        defer {
            activeRecordingLock.unlock()
        }

        guard var recording = activeRecording else {
            return
        }

        do {
            try recording.audioFile.write(from: buffer)
            recording.frameCount += AVAudioFramePosition(buffer.frameLength)
        } catch {
            recording.writeError = error
        }

        activeRecording = recording
    }

    private func stopDiscardingMetadata() {
        guard readActiveRecording() != nil else {
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        replaceActiveRecording(nil)
    }

    private func readActiveRecording() -> ActiveRecording? {
        activeRecordingLock.lock()
        defer {
            activeRecordingLock.unlock()
        }

        return activeRecording
    }

    private func takeActiveRecording() -> ActiveRecording? {
        activeRecordingLock.lock()
        defer {
            activeRecordingLock.unlock()
        }

        let recording = activeRecording
        activeRecording = nil
        return recording
    }

    private func replaceActiveRecording(_ recording: ActiveRecording?) {
        activeRecordingLock.lock()
        defer {
            activeRecordingLock.unlock()
        }

        activeRecording = recording
    }

    private static func repositoryRootURL() -> URL? {
        var candidates: [URL] = [
            URL(fileURLWithPath: #filePath),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ]

        if let bundleResourceURL = Bundle.main.resourceURL {
            candidates.append(bundleResourceURL)
        }

        for candidate in candidates {
            if let root = firstAncestorWithFixtureDirectory(from: candidate) {
                return root
            }
        }

        return nil
    }

    private static func firstAncestorWithFixtureDirectory(from url: URL) -> URL? {
        var current = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let fixtureDirectory = current
                .appendingPathComponent("LocalFixtures", isDirectory: true)
                .appendingPathComponent("ambient-sync-voice-memos", isDirectory: true)
            if FileManager.default.fileExists(atPath: fixtureDirectory.path) {
                return current
            }

            current.deleteLastPathComponent()
        }

        return nil
    }

    private static func fileStem(
        group: String,
        takeLabel: String,
        fallbackName: String,
        timestamp: Date
    ) -> String {
        let groupSlug = slugify(group)
        let fallbackSlug = slugify(fallbackName)
        let takeSlug = slugify(takeLabel)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        return [
            groupSlug.isEmpty ? fallbackSlug : groupSlug,
            takeSlug.isEmpty ? "take" : takeSlug,
            formatter.string(from: timestamp)
        ]
        .map { $0.isEmpty ? "ambient-sync" : $0 }
        .joined(separator: "-")
    }

    private static func normalizedLabel(_ label: String, fallback: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func slugify(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        var scalars: [UnicodeScalar] = []
        var previousWasSeparator = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append("-")
                previousWasSeparator = true
            }
        }

        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
