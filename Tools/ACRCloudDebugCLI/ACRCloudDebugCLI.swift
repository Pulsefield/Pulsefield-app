#if DEBUG
import AVFoundation
import Darwin
import Foundation
import PulsefieldCore

@main
struct ACRCloudDebugCLI {
    static func main() async {
        do {
            let options = try ACRCloudDebugOptions.parse(CommandLine.arguments)
            if options.showsHelp {
                print(ACRCloudDebugOptions.helpText)
                return
            }

            try await run(options: options)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            fputs("\n\(ACRCloudDebugOptions.helpText)\n", stderr)
            exit(1)
        }
    }

    private static func run(options: ACRCloudDebugOptions) async throws {
        let runtime = try options.fileScanRuntime()
        if let envFileURL = runtime.loadedEnvFileURL {
            print("Loaded .env: \(envFileURL.path)")
        }

        let outputDirectoryURL = options.outputDirectoryURL
            ?? AudioClipCaptureService.defaultOutputDirectoryURL()
        let provider = DebugACRCloudRecognitionProvider(configuration: runtime.configuration)

        let clip: RecognitionAudioClip
        if let sourceAudio = try options.sourceAudio() {
            print("Extracting \(formatSeconds(options.duration)) clip from \(sourceAudio.label)...")
            clip = try AudioFileClipper.saveClip(
                from: sourceAudio.url,
                startTime: options.clipStart,
                duration: options.duration,
                outputDirectoryURL: outputDirectoryURL
            )
        } else {
            let permissionService = MicrophonePermissionService()
            let permissionStatus = await permissionService.requestAccess()

            guard permissionStatus == .authorized else {
                throw ACRCloudDebugCLIError.message(
                    "Microphone access is \(permissionStatus.rawValue). Grant microphone access before running recognition."
                )
            }

            let captureService = AudioClipCaptureService(configuration: .init(outputDirectoryURL: outputDirectoryURL))
            print("Recording \(formatSeconds(options.duration)) from the microphone...")
            let captureResult = await captureService.captureClip(duration: options.duration)

            switch captureResult {
            case .success(let capturedClip):
                clip = capturedClip
            case .failure(let failure):
                throw ACRCloudDebugCLIError.message("\(failure.title): \(failure.message)")
            }
        }

        let byteCount = (try? FileManager.default.attributesOfItem(atPath: clip.fileURL.path)[.size] as? NSNumber)?.intValue
        print("Saved clip: \(clip.fileURL.path)")
        print("Clip duration: \(formatSeconds(clip.duration))")
        if let byteCount {
            print("Clip bytes: \(byteCount)")
        }

        let scanCommand = [runtime.configuration.executablePath] + runtime.configuration.scanArguments(for: clip.fileURL)
        print("Requesting ACRCloud via official CLI:")
        print("  \(shellCommand(scanCommand))")

        let recognitionResult = await provider.scan(clip: clip)
        switch recognitionResult {
        case .success(let execution):
            print("ACRCloud filescan state: \(execution.result.stateDescription)")
            if let containerID = execution.result.containerID {
                print("Container ID: \(containerID)")
            }
            if let fileID = execution.result.fileID {
                print("File ID: \(fileID)")
            }

            guard let music = execution.result.music else {
                print("Recognition result: no match")
                return
            }

            print("Recognition result: matched")
            print("Title: \(music.title)")
            print("Artist: \(music.artists.isEmpty ? "Unknown Artist" : music.artists.joined(separator: ", "))")
            if let album = music.album {
                print("Album: \(album)")
            }
            if let isrc = music.isrc {
                print("ISRC: \(isrc)")
            }
            if let durationMS = music.durationMS {
                print("Track duration: \(formatSeconds(TimeInterval(durationMS) / 1_000))")
            }
            if let offsetSeconds = music.offsetSeconds {
                print("Match offset: \(formatSeconds(offsetSeconds))")
            }
            if let playedDurationSeconds = music.playedDurationSeconds {
                print("Played duration: \(formatSeconds(playedDurationSeconds))")
            }
            if let score = music.score {
                print("Provider score: \(score)")
            }
            if let releaseDate = music.releaseDate {
                print("Release date: \(releaseDate)")
            }
            if let matchType = music.matchType {
                print("Match type: \(matchType)")
            }
            print("ACRCloud ID: \(music.acrid)")

        case .failure(let failure):
            throw ACRCloudDebugCLIError.message("\(failure.title): \(failure.message)")
        }
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }

    private static func shellCommand(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\""))) == nil {
                return argument
            }

            return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")
    }
}

private struct ACRCloudDebugRuntime {
    let configuration: ACRCloudFileScanConfiguration
    let loadedEnvFileURL: URL?
}

private struct ACRCloudDebugOptions {
    var duration: TimeInterval = 10
    var clipStart: TimeInterval = 0
    var outputDirectoryURL: URL?
    var inputAudioURL: URL?
    var fixtureSidecarURL: URL?
    var envFileURL: URL?
    var loadsEnvFile = true
    var accessToken: String?
    var acrcloudExecutablePath: String?
    var region: String?
    var containerID: Int?
    var buckets: String?
    var engine: Int?
    var audioType: String?
    var scanTimeoutSeconds: Int?
    var pollIntervalSeconds: Int?
    var showsHelp = false

    static let helpText = """
    Usage:
      PulsefieldACRCloudDebugCLI [--duration seconds] [--clip-start seconds] [--input-audio path | --fixture sidecar.json]
                                 [--output-directory path] [--env-file path] [--no-env-file]
                                 [--access-token token] [--acrcloud-cli path] [--region region] [--container-id id]
                                 [--buckets buckets] [--engine 1|2|3|4] [--audio-type linein|recorded]
                                 [--scan-timeout seconds] [--poll-interval seconds]

    Default .env:
      Loads .env from the current working directory when present.

    Environment fallback:
      ACRCLOUD_ACCESS_TOKEN              Personal access token for the official ACRCloud CLI
      ACRCLOUD_PERSONAL_ACCESS_TOKEN     Accepted alias for local .env files
      ACRCLOUD_CLI                       Optional acrcloud executable path
      ACRCLOUD_FILESCAN_REGION           eu-west-1, us-west-2, or ap-southeast-1
      ACRCLOUD_FILESCAN_CONTAINER_ID     Optional existing file scanning container
      ACRCLOUD_FILESCAN_BUCKETS          Default: 23
      ACRCLOUD_FILESCAN_ENGINE           Default: 1
      ACRCLOUD_FILESCAN_AUDIO_TYPE       Default: recorded
      ACRCLOUD_FILESCAN_TIMEOUT          Default: 600
      ACRCLOUD_FILESCAN_POLL_INTERVAL    Default: 5

    Required external tool:
      pip install acrcloud-cli
      The package installs the `acrcloud` command used as: acrcloud filescan scan <clip.wav>

    Flow:
      microphone or fixture audio -> save WAV clip -> acrcloud filescan scan -> print recognition result
    """

    static func parse(_ arguments: [String]) throws -> ACRCloudDebugOptions {
        var options = ACRCloudDebugOptions()
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--help", "-h":
                options.showsHelp = true
                index += 1

            case "--duration":
                options.duration = try parseTimeInterval(valueAfter: argument, in: arguments, at: &index)

            case "--clip-start":
                options.clipStart = try parseNonNegativeTimeInterval(valueAfter: argument, in: arguments, at: &index)

            case "--input-audio":
                let path = try parseString(valueAfter: argument, in: arguments, at: &index)
                options.inputAudioURL = fileURL(path: path, isDirectory: false)

            case "--fixture":
                let path = try parseString(valueAfter: argument, in: arguments, at: &index)
                options.fixtureSidecarURL = fileURL(path: path, isDirectory: false)

            case "--output-directory":
                let path = try parseString(valueAfter: argument, in: arguments, at: &index)
                options.outputDirectoryURL = fileURL(path: path, isDirectory: true)

            case "--env-file":
                let path = try parseString(valueAfter: argument, in: arguments, at: &index)
                options.envFileURL = fileURL(path: path, isDirectory: false)
                options.loadsEnvFile = true

            case "--no-env-file":
                options.loadsEnvFile = false
                index += 1

            case "--access-token":
                options.accessToken = try parseString(valueAfter: argument, in: arguments, at: &index)

            case "--acrcloud-cli":
                options.acrcloudExecutablePath = try parseString(valueAfter: argument, in: arguments, at: &index)

            case "--region":
                options.region = try parseString(valueAfter: argument, in: arguments, at: &index)

            case "--container-id":
                options.containerID = try parsePositiveInt(valueAfter: argument, in: arguments, at: &index)

            case "--buckets":
                options.buckets = try parseString(valueAfter: argument, in: arguments, at: &index)

            case "--engine":
                options.engine = try parsePositiveInt(valueAfter: argument, in: arguments, at: &index)

            case "--audio-type":
                options.audioType = try parseString(valueAfter: argument, in: arguments, at: &index)

            case "--scan-timeout":
                options.scanTimeoutSeconds = try parsePositiveInt(valueAfter: argument, in: arguments, at: &index)

            case "--poll-interval":
                options.pollIntervalSeconds = try parsePositiveInt(valueAfter: argument, in: arguments, at: &index)

            default:
                throw ACRCloudDebugCLIError.message("Unknown argument: \(argument)")
            }
        }

        return options
    }

    func sourceAudio() throws -> SourceAudio? {
        if inputAudioURL != nil, fixtureSidecarURL != nil {
            throw ACRCloudDebugCLIError.message("Use either --input-audio or --fixture, not both.")
        }

        if let inputAudioURL {
            return SourceAudio(url: inputAudioURL, label: inputAudioURL.path)
        }

        if let fixtureSidecarURL {
            let audioURL = try FixtureSidecarAudioResolver.audioURL(from: fixtureSidecarURL)
            return SourceAudio(url: audioURL, label: "\(fixtureSidecarURL.lastPathComponent) -> \(audioURL.lastPathComponent)")
        }

        return nil
    }

    func fileScanRuntime() throws -> ACRCloudDebugRuntime {
        let loadedEnvFile = try loadEnvFile()
        var environment = loadedEnvFile?.values ?? [:]
        for (key, value) in ProcessInfo.processInfo.environment {
            environment[key] = value
        }

        let resolvedToken = accessToken
            ?? environment["ACRCLOUD_ACCESS_TOKEN"]?.trimmedNilIfEmpty
            ?? environment["ACRCLOUD_PERSONAL_ACCESS_TOKEN"]?.trimmedNilIfEmpty
        guard let resolvedToken, !resolvedToken.isEmpty else {
            throw ACRCloudDebugCLIError.message(
                "Missing ACRCloud personal access token. Set ACRCLOUD_ACCESS_TOKEN or ACRCLOUD_PERSONAL_ACCESS_TOKEN in .env, or pass --access-token."
            )
        }

        let resolvedRegion = region ?? environment["ACRCLOUD_FILESCAN_REGION"]?.trimmedNilIfEmpty ?? "eu-west-1"
        try validate(resolvedRegion, allowed: ["eu-west-1", "us-west-2", "ap-southeast-1"], argument: "region")

        let resolvedEngine = try engine ?? parseEnvironmentPositiveInt(
            environment["ACRCLOUD_FILESCAN_ENGINE"],
            key: "ACRCLOUD_FILESCAN_ENGINE",
            defaultValue: 1
        )
        guard (1...4).contains(resolvedEngine) else {
            throw ACRCloudDebugCLIError.message("--engine must be one of 1, 2, 3, or 4.")
        }

        let resolvedAudioType = audioType ?? environment["ACRCLOUD_FILESCAN_AUDIO_TYPE"]?.trimmedNilIfEmpty ?? "recorded"
        try validate(resolvedAudioType, allowed: ["linein", "recorded"], argument: "audio-type")

        let resolvedContainerID = try containerID ?? parseOptionalEnvironmentPositiveInt(
            environment["ACRCLOUD_FILESCAN_CONTAINER_ID"],
            key: "ACRCLOUD_FILESCAN_CONTAINER_ID"
        )
        let resolvedTimeout = try scanTimeoutSeconds ?? parseEnvironmentPositiveInt(
            environment["ACRCLOUD_FILESCAN_TIMEOUT"],
            key: "ACRCLOUD_FILESCAN_TIMEOUT",
            defaultValue: 600
        )
        let resolvedPollInterval = try pollIntervalSeconds ?? parseEnvironmentPositiveInt(
            environment["ACRCLOUD_FILESCAN_POLL_INTERVAL"],
            key: "ACRCLOUD_FILESCAN_POLL_INTERVAL",
            defaultValue: 5
        )

        let configuration = ACRCloudFileScanConfiguration(
            accessToken: resolvedToken,
            executablePath: acrcloudExecutablePath
                ?? environment["ACRCLOUD_CLI"]?.trimmedNilIfEmpty
                ?? ACRCloudFileScanConfiguration.defaultExecutablePath(environment: environment),
            region: resolvedRegion,
            containerID: resolvedContainerID,
            buckets: buckets ?? environment["ACRCLOUD_FILESCAN_BUCKETS"]?.trimmedNilIfEmpty ?? "23",
            engine: resolvedEngine,
            audioType: resolvedAudioType,
            timeoutSeconds: resolvedTimeout,
            pollIntervalSeconds: resolvedPollInterval,
            environment: environment
        )

        return ACRCloudDebugRuntime(
            configuration: configuration,
            loadedEnvFileURL: loadedEnvFile?.url
        )
    }

    private func loadEnvFile() throws -> LoadedEnvFile? {
        guard loadsEnvFile else {
            return nil
        }

        let explicitURL = envFileURL
        let resolvedURL = explicitURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".env")

        return try DotEnvFile.load(url: resolvedURL, required: explicitURL != nil)
    }

    private func validate(_ value: String, allowed: Set<String>, argument: String) throws {
        guard allowed.contains(value) else {
            throw ACRCloudDebugCLIError.message("\(argument) must be one of: \(allowed.sorted().joined(separator: ", ")).")
        }
    }

    private func parseEnvironmentPositiveInt(
        _ value: String?,
        key: String,
        defaultValue: Int
    ) throws -> Int {
        guard let value = value?.trimmedNilIfEmpty else {
            return defaultValue
        }

        guard let intValue = Int(value), intValue > 0 else {
            throw ACRCloudDebugCLIError.message("\(key) must be a positive integer.")
        }

        return intValue
    }

    private func parseOptionalEnvironmentPositiveInt(
        _ value: String?,
        key: String
    ) throws -> Int? {
        guard let value = value?.trimmedNilIfEmpty else {
            return nil
        }

        guard let intValue = Int(value), intValue > 0 else {
            throw ACRCloudDebugCLIError.message("\(key) must be a positive integer.")
        }

        return intValue
    }

    private static func parseTimeInterval(
        valueAfter argument: String,
        in arguments: [String],
        at index: inout Int
    ) throws -> TimeInterval {
        let value = try parseString(valueAfter: argument, in: arguments, at: &index)
        guard let duration = TimeInterval(value), duration > 0 else {
            throw ACRCloudDebugCLIError.message("\(argument) must be a positive number of seconds.")
        }
        return duration
    }

    private static func parseNonNegativeTimeInterval(
        valueAfter argument: String,
        in arguments: [String],
        at index: inout Int
    ) throws -> TimeInterval {
        let value = try parseString(valueAfter: argument, in: arguments, at: &index)
        guard let duration = TimeInterval(value), duration >= 0 else {
            throw ACRCloudDebugCLIError.message("\(argument) must be a non-negative number of seconds.")
        }
        return duration
    }

    private static func parsePositiveInt(
        valueAfter argument: String,
        in arguments: [String],
        at index: inout Int
    ) throws -> Int {
        let value = try parseString(valueAfter: argument, in: arguments, at: &index)
        guard let intValue = Int(value), intValue > 0 else {
            throw ACRCloudDebugCLIError.message("\(argument) must be a positive integer.")
        }
        return intValue
    }

    private static func parseString(
        valueAfter argument: String,
        in arguments: [String],
        at index: inout Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ACRCloudDebugCLIError.message("\(argument) requires a value.")
        }

        index += 2
        return arguments[valueIndex]
    }

    private static func fileURL(path: String, isDirectory: Bool) -> URL {
        URL(
            fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: isDirectory
        )
    }
}

private struct SourceAudio {
    let url: URL
    let label: String
}

private struct LoadedEnvFile {
    let url: URL
    let values: [String: String]
}

private enum FixtureSidecarAudioResolver {
    static func audioURL(from sidecarURL: URL) throws -> URL {
        let data = try Data(contentsOf: sidecarURL)
        let sidecar = try JSONDecoder().decode(FixtureSidecar.self, from: data)
        guard sidecar.audioFileName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil else {
            throw ACRCloudDebugCLIError.message("Fixture sidecar audioFileName must be a bare file name.")
        }

        let audioURL = sidecarURL
            .deletingLastPathComponent()
            .appendingPathComponent(sidecar.audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ACRCloudDebugCLIError.message("Fixture audio does not exist: \(audioURL.path)")
        }

        return audioURL
    }

    private struct FixtureSidecar: Decodable {
        let audioFileName: String
    }
}

private enum AudioFileClipper {
    static func saveClip(
        from sourceURL: URL,
        startTime: TimeInterval,
        duration: TimeInterval,
        outputDirectoryURL: URL
    ) throws -> RecognitionAudioClip {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ACRCloudDebugCLIError.message("Source audio does not exist: \(sourceURL.path)")
        }
        guard startTime >= 0, duration > 0 else {
            throw ACRCloudDebugCLIError.message("Clip start must be non-negative and duration must be positive.")
        }

        try FileManager.default.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )

        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = sourceFile.processingFormat
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw ACRCloudDebugCLIError.message("Source audio has an unsupported format.")
        }

        let startFrame = AVAudioFramePosition((startTime * sourceFormat.sampleRate).rounded(.down))
        guard startFrame < sourceFile.length else {
            throw ACRCloudDebugCLIError.message("Clip start \(startTime)s is beyond the source duration.")
        }

        let requestedFrameCount = AVAudioFrameCount((duration * sourceFormat.sampleRate).rounded(.toNearestOrAwayFromZero))
        let availableFrames = sourceFile.length - startFrame
        var remainingFrames = AVAudioFrameCount(min(Int64(requestedFrameCount), availableFrames))
        guard remainingFrames > 0 else {
            throw ACRCloudDebugCLIError.message("No source audio frames available for the requested clip.")
        }

        let startedAt = Date()
        let outputURL = outputDirectoryURL
            .appendingPathComponent(fileStem(sourceURL: sourceURL, timestamp: startedAt))
            .appendingPathExtension("wav")
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: sourceFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: sourceFormat.commonFormat,
            interleaved: sourceFormat.isInterleaved
        )

        sourceFile.framePosition = startFrame
        var writtenFrames: AVAudioFrameCount = 0
        while remainingFrames > 0 {
            let frameCount = min(remainingFrames, 16_384)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                throw ACRCloudDebugCLIError.message("Could not allocate audio buffer for clip extraction.")
            }

            try sourceFile.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else {
                break
            }

            try outputFile.write(from: buffer)
            writtenFrames += buffer.frameLength
            remainingFrames -= buffer.frameLength
        }

        let measuredDuration = Double(writtenFrames) / sourceFormat.sampleRate
        return RecognitionAudioClip(
            fileURL: outputURL,
            mimeType: "audio/wav",
            duration: measuredDuration,
            recordedAt: startedAt
        )
    }

    private static func fileStem(sourceURL: URL, timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let slug = baseName.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let normalizedSlug = String(slug)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return [
            "acrcloud-debug",
            normalizedSlug.isEmpty ? "fixture" : normalizedSlug,
            formatter.string(from: timestamp)
        ].joined(separator: "-")
    }
}

private enum DotEnvFile {
    static func load(url: URL, required: Bool) throws -> LoadedEnvFile? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            if required {
                throw ACRCloudDebugCLIError.message("Env file does not exist: \(url.path)")
            }
            return nil
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]

        for (lineNumber, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            let assignment = line.hasPrefix("export ")
                ? String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                : line

            guard let separatorIndex = assignment.firstIndex(of: "=") else {
                throw ACRCloudDebugCLIError.message(".env line \(lineNumber + 1) is not KEY=VALUE.")
            }

            let key = assignment[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            let rawValue = assignment[assignment.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else {
                throw ACRCloudDebugCLIError.message(".env line \(lineNumber + 1) has an empty key.")
            }

            values[String(key)] = cleanedValue(String(rawValue))
        }

        return LoadedEnvFile(url: url, values: values)
    }

    private static func cleanedValue(_ rawValue: String) -> String {
        let withoutComment = removeInlineComment(from: rawValue).trimmingCharacters(in: .whitespaces)

        if withoutComment.count >= 2,
           let first = withoutComment.first,
           let last = withoutComment.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            let start = withoutComment.index(after: withoutComment.startIndex)
            let end = withoutComment.index(before: withoutComment.endIndex)
            return String(withoutComment[start..<end])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
        }

        return withoutComment
    }

    private static func removeInlineComment(from value: String) -> String {
        var quote: Character?
        var previous: Character?

        for index in value.indices {
            let character = value[index]
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            }

            if character == "#",
               quote == nil,
               previous?.isWhitespace != false {
                return String(value[..<index])
            }

            previous = character
        }

        return value
    }
}

private enum ACRCloudDebugCLIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#else
import Darwin
import Foundation

@main
struct ACRCloudDebugCLI {
    static func main() {
        fputs("PulsefieldACRCloudDebugCLI is only available in Debug builds.\n", stderr)
        exit(2)
    }
}
#endif
