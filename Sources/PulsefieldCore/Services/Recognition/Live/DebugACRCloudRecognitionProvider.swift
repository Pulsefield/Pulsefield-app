#if DEBUG
import CryptoKit
import Foundation

public struct ACRCloudFileScanConfiguration: Equatable, Sendable {
    public let accessToken: String
    public let executablePath: String
    public let region: String
    public let containerID: Int?
    public let buckets: String
    public let engine: Int
    public let audioType: String
    public let timeoutSeconds: Int
    public let pollIntervalSeconds: Int
    public let environment: [String: String]

    public init(
        accessToken: String,
        executablePath: String = ACRCloudFileScanConfiguration.defaultExecutablePath(),
        region: String = "eu-west-1",
        containerID: Int? = nil,
        buckets: String = "23",
        engine: Int = 1,
        audioType: String = "recorded",
        timeoutSeconds: Int = 600,
        pollIntervalSeconds: Int = 1,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.accessToken = accessToken
        self.executablePath = executablePath
        self.region = region
        self.containerID = containerID
        self.buckets = buckets
        self.engine = engine
        self.audioType = audioType
        self.timeoutSeconds = timeoutSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.environment = environment
    }

    public var isComplete: Bool {
        !accessToken.trimmed.isEmpty
    }

    public func scanArguments(for fileURL: URL) -> [String] {
        var arguments = [
            "filescan",
            "scan",
            fileURL.path,
            "--region",
            region,
            "--engine",
            String(engine),
            "--buckets",
            buckets,
            "--audio-type",
            audioType,
            "--timeout",
            String(timeoutSeconds),
            "--poll-interval",
            String(pollIntervalSeconds),
            "--output",
            "json"
        ]

        if let containerID {
            arguments.append(contentsOf: ["--container-id", String(containerID)])
        }

        return arguments
    }

    public func processEnvironment() -> [String: String] {
        var resolvedEnvironment = Self.defaultProcessEnvironment(base: environment)
        resolvedEnvironment["ACRCLOUD_ACCESS_TOKEN"] = accessToken
        return resolvedEnvironment
    }

    public static func defaultExecutablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let resolvedEnvironment = defaultProcessEnvironment(base: environment)

        if let configuredPath = environment["ACRCLOUD_CLI"]?.trimmedNilIfEmpty {
            let expandedPath = expandedExecutablePath(configuredPath)
            return resolveExecutablePath(expandedPath, environment: resolvedEnvironment) ?? expandedPath
        }

        return resolveExecutablePath("acrcloud", environment: resolvedEnvironment) ?? "acrcloud"
    }

    public static func defaultProcessEnvironment(
        base environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var resolvedEnvironment = environment
        resolvedEnvironment["PATH"] = executableSearchPath(environment: environment).joined(separator: ":")
        return resolvedEnvironment
    }

    public static func resolveExecutablePath(
        _ executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let expandedPath = expandedExecutablePath(executablePath)
        guard !expandedPath.isEmpty else {
            return nil
        }

        if expandedPath.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expandedPath) ? expandedPath : nil
        }

        for directory in executableSearchPath(environment: environment) {
            let candidatePath = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(expandedPath)
                .path

            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return candidatePath
            }
        }

        return nil
    }

    private static func executableSearchPath(environment: [String: String]) -> [String] {
        var directories = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            ?? []

        directories.append(contentsOf: commonExecutableDirectories())

        var seen: Set<String> = []
        return directories.compactMap { directory in
            let expandedDirectory = NSString(string: directory).expandingTildeInPath
            guard !expandedDirectory.isEmpty, seen.insert(expandedDirectory).inserted else {
                return nil
            }

            return expandedDirectory
        }
    }

    private static func commonExecutableDirectories() -> [String] {
        #if os(macOS)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let pythonVersions = ["3.13", "3.12", "3.11", "3.10", "3.9", "3.8"]
        let userPythonDirectories = pythonVersions.map { "\(homePath)/Library/Python/\($0)/bin" }

        return [
            "\(homePath)/.local/bin"
        ] + userPythonDirectories + [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        #else
        return []
        #endif
    }

    private static func expandedExecutablePath(_ executablePath: String) -> String {
        NSString(string: executablePath.trimmed).expandingTildeInPath
    }
}

public struct ACRCloudFileScanExecution: Equatable, Sendable {
    public let command: [String]
    public let exitCode: Int32
    public let output: String
    public let result: ACRCloudFileScanResult

    public init(
        command: [String],
        exitCode: Int32,
        output: String,
        result: ACRCloudFileScanResult
    ) {
        self.command = command
        self.exitCode = exitCode
        self.output = output
        self.result = result
    }
}

public struct ACRCloudFileScanResult: Equatable, Sendable {
    public let fileID: String?
    public let containerID: Int?
    public let state: Int?
    public let stateDescription: String
    public let fileName: String?
    public let durationSeconds: TimeInterval?
    public let music: ACRCloudMusicMatch?

    public init(
        fileID: String?,
        containerID: Int?,
        state: Int?,
        stateDescription: String,
        fileName: String?,
        durationSeconds: TimeInterval?,
        music: ACRCloudMusicMatch?
    ) {
        self.fileID = fileID
        self.containerID = containerID
        self.state = state
        self.stateDescription = stateDescription
        self.fileName = fileName
        self.durationSeconds = durationSeconds
        self.music = music
    }
}

public struct ACRCloudMusicMatch: Equatable, Sendable {
    public let acrid: String
    public let title: String
    public let artists: [String]
    public let album: String?
    public let durationMS: Int?
    public let isrc: String?
    public let score: Int?
    public let releaseDate: String?
    public let offsetSeconds: TimeInterval?
    public let playedDurationSeconds: TimeInterval?
    public let matchType: String?
    public let audioID: String?

    public init(
        acrid: String,
        title: String,
        artists: [String],
        album: String? = nil,
        durationMS: Int? = nil,
        isrc: String? = nil,
        score: Int? = nil,
        releaseDate: String? = nil,
        offsetSeconds: TimeInterval? = nil,
        playedDurationSeconds: TimeInterval? = nil,
        matchType: String? = nil,
        audioID: String? = nil
    ) {
        self.acrid = acrid
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
        self.isrc = isrc
        self.score = score
        self.releaseDate = releaseDate
        self.offsetSeconds = offsetSeconds
        self.playedDurationSeconds = playedDurationSeconds
        self.matchType = matchType
        self.audioID = audioID
    }

    public var canonicalTrack: CanonicalTrack {
        CanonicalTrack(
            title: title,
            artists: artists,
            album: album,
            durationMS: durationMS,
            isrc: isrc,
            providerIDs: [.init(provider: .acrCloud, value: acrid)]
        )
    }
}

public actor DebugACRCloudRecognitionProvider: RecognitionProviderClient {
    public nonisolated let provider: RecognitionProvider = .acrCloud
    public nonisolated let backendLabel = "ACRCloud Debug filescan CLI"

    private let configuration: ACRCloudFileScanConfiguration
    private let client: ACRCloudFileScanClient

    public init(
        configuration: ACRCloudFileScanConfiguration,
        client: ACRCloudFileScanClient = ACRCloudFileScanClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    public func prepare() async {}

    public func recognize(clip: RecognitionAudioClip) async -> RecognitionOutcome {
        let result = await scan(clip: clip)

        switch result {
        case .success(let execution):
            guard let music = execution.result.music else {
                return .noMatch
            }

            return .matched(ACRCloudFileScanNormalizer.snapshot(from: music, clip: clip))

        case .failure(let failure):
            return .failed(failure)
        }
    }

    public func scan(clip: RecognitionAudioClip) async -> Result<ACRCloudFileScanExecution, RecognitionFailure> {
        guard configuration.isComplete else {
            return .failure(.providerConfigurationMissing(
                providerName: RecognitionProvider.acrCloud.displayName,
                missingFields: ["ACRCLOUD_ACCESS_TOKEN"]
            ))
        }

        do {
            let execution = try client.scan(clip: clip, configuration: configuration)

            if [-2, -3].contains(execution.result.state ?? 0) {
                return .failure(RecognitionFailure(
                    title: "ACRCloud File Scan Failed",
                    message: "acrcloud filescan scan finished with state \(execution.result.stateDescription).",
                    recoverySuggestion: "Check the file scanning container, bucket permissions, and ACRCloud Console API limits."
                ))
            }

            return .success(execution)
        } catch let failure as RecognitionFailure {
            return .failure(failure)
        } catch {
            return .failure(RecognitionFailure(
                title: "ACRCloud File Scan Failed",
                message: error.localizedDescription,
                recoverySuggestion: "Check that acrcloud-cli is installed and that ACRCLOUD_ACCESS_TOKEN is valid."
            ))
        }
    }

    public func cancelRecognition() async {}
}

public struct ACRCloudIdentificationExecution: Equatable, Sendable {
    public let endpoint: URL
    public let httpStatusCode: Int?
    public let response: ACRCloudIdentificationResult

    public init(
        endpoint: URL,
        httpStatusCode: Int?,
        response: ACRCloudIdentificationResult
    ) {
        self.endpoint = endpoint
        self.httpStatusCode = httpStatusCode
        self.response = response
    }
}

public struct ACRCloudIdentificationResult: Equatable, Sendable {
    public let statusCode: Int
    public let statusMessage: String
    public let music: ACRCloudMusicMatch?

    public init(
        statusCode: Int,
        statusMessage: String,
        music: ACRCloudMusicMatch?
    ) {
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.music = music
    }

    public var isNoResult: Bool {
        statusCode == 1001
    }
}

public actor ACRCloudIdentificationProvider: RecognitionProviderClient {
    public nonisolated let provider: RecognitionProvider = .acrCloud
    public nonisolated let backendLabel = "ACRCloud Identification API"

    private let configuration: ACRCloudConfiguration
    private let client: ACRCloudIdentificationClient

    public init(
        configuration: ACRCloudConfiguration,
        client: ACRCloudIdentificationClient = ACRCloudIdentificationClient()
    ) {
        self.configuration = configuration
        self.client = client
    }

    public func prepare() async {}

    public func recognize(clip: RecognitionAudioClip) async -> RecognitionOutcome {
        let result = await identify(clip: clip)

        switch result {
        case .success(let execution):
            guard let music = execution.response.music else {
                return .noMatch
            }

            return .matched(ACRCloudFileScanNormalizer.snapshot(from: music, clip: clip))

        case .failure(let failure):
            return .failed(failure)
        }
    }

    public func identify(clip: RecognitionAudioClip) async -> Result<ACRCloudIdentificationExecution, RecognitionFailure> {
        let missingFields = missingConfigurationFields()
        guard missingFields.isEmpty else {
            return .failure(.providerConfigurationMissing(
                providerName: RecognitionProvider.acrCloud.displayName,
                missingFields: missingFields
            ))
        }

        do {
            let execution = try await client.identify(clip: clip, configuration: configuration)
            if execution.response.statusCode == 0 || execution.response.isNoResult {
                return .success(execution)
            }

            return .failure(RecognitionFailure(
                title: "ACRCloud Identification Failed",
                message: "ACRCloud returned status \(execution.response.statusCode): \(execution.response.statusMessage).",
                recoverySuggestion: "Check the ACRCloud Identification host, access key, secret, and project region."
            ))
        } catch let failure as RecognitionFailure {
            return .failure(failure)
        } catch {
            return .failure(RecognitionFailure(
                title: "ACRCloud Identification Failed",
                message: error.localizedDescription,
                recoverySuggestion: "Check network access and the ACRCloud Identification API credentials."
            ))
        }
    }

    public func cancelRecognition() async {}

    private func missingConfigurationFields() -> [String] {
        var fields: [String] = []
        if configuration.host.trimmed.isEmpty {
            fields.append("ACRCLOUD_IDENTIFICATION_HOST")
        }
        if configuration.accessKey.trimmed.isEmpty {
            fields.append("ACRCLOUD_ACCESS_KEY")
        }
        if configuration.accessSecret.trimmed.isEmpty {
            fields.append("ACRCLOUD_ACCESS_SECRET")
        }
        return fields
    }
}

public struct ACRCloudIdentificationClient: Sendable {
    public init() {}

    public func identify(
        clip: RecognitionAudioClip,
        configuration: ACRCloudConfiguration
    ) async throws -> ACRCloudIdentificationExecution {
        let sample = try Data(contentsOf: clip.fileURL)
        let endpoint = try Self.endpointURL(host: configuration.host)
        let request = try Self.makeRequest(
            endpoint: endpoint,
            configuration: configuration,
            clip: clip,
            sample: sample,
            timestamp: String(Int(Date().timeIntervalSince1970))
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpStatusCode = (response as? HTTPURLResponse)?.statusCode

        guard let httpStatusCode, (200..<300).contains(httpStatusCode) else {
            throw RecognitionFailure(
                title: "ACRCloud Identification Failed",
                message: "HTTP request failed with status \(httpStatusCode.map(String.init) ?? "unknown").",
                recoverySuggestion: "Check network access and the ACRCloud Identification host."
            )
        }

        let result = try ACRCloudIdentificationNormalizer.result(from: data)
        return ACRCloudIdentificationExecution(
            endpoint: endpoint,
            httpStatusCode: httpStatusCode,
            response: result
        )
    }

    public static func makeRequest(
        endpoint: URL,
        configuration: ACRCloudConfiguration,
        clip: RecognitionAudioClip,
        sample: Data,
        timestamp: String,
        boundary: String = "PulsefieldBoundary-\(UUID().uuidString)"
    ) throws -> URLRequest {
        let signature = signature(
            accessKey: configuration.accessKey,
            accessSecret: configuration.accessSecret,
            timestamp: timestamp
        )
        let fields = [
            ("access_key", configuration.accessKey),
            ("sample_bytes", String(sample.count)),
            ("timestamp", timestamp),
            ("signature", signature),
            ("data_type", "audio"),
            ("signature_version", "1")
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            fields: fields,
            sample: sample,
            fileName: clip.fileURL.lastPathComponent,
            mimeType: clip.mimeType,
            boundary: boundary
        )
        return request
    }

    public static func signature(
        method: String = "POST",
        path: String = "/v1/identify",
        accessKey: String,
        accessSecret: String,
        dataType: String = "audio",
        signatureVersion: String = "1",
        timestamp: String
    ) -> String {
        let stringToSign = [
            method,
            path,
            accessKey,
            dataType,
            signatureVersion,
            timestamp
        ].joined(separator: "\n")
        let key = SymmetricKey(data: Data(accessSecret.utf8))
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return Data(code).base64EncodedString()
    }

    public static func endpointURL(host: String) throws -> URL {
        var trimmedHost = host.trimmed
        if trimmedHost.hasPrefix("https://") {
            trimmedHost.removeFirst("https://".count)
        } else if trimmedHost.hasPrefix("http://") {
            trimmedHost.removeFirst("http://".count)
        }

        guard !trimmedHost.isEmpty,
              let url = URL(string: "https://\(trimmedHost)/v1/identify")
        else {
            throw RecognitionFailure(
                title: "ACRCloud Identification Host Invalid",
                message: "Could not build an Identification API URL from the configured host.",
                recoverySuggestion: "Use a host such as identify-ap-southeast-1.acrcloud.com."
            )
        }

        return url
    }

    private static func multipartBody(
        fields: [(String, String)],
        sample: Data,
        fileName: String,
        mimeType: String,
        boundary: String
    ) -> Data {
        var body = Data()

        for (name, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"sample\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(sample)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }
}

public struct ACRCloudFileScanClient: Sendable {
    public init() {}

    public func scan(
        clip: RecognitionAudioClip,
        configuration: ACRCloudFileScanConfiguration
    ) throws -> ACRCloudFileScanExecution {
        let scanArguments = configuration.scanArguments(for: clip.fileURL)
        let environment = configuration.processEnvironment()
        let resolvedExecutablePath = ACRCloudFileScanConfiguration.resolveExecutablePath(
            configuration.executablePath,
            environment: environment
        ) ?? configuration.executablePath
        let processCommand = [resolvedExecutablePath] + scanArguments
        let processOutput = try Self.runProcess(
            executablePath: configuration.executablePath,
            arguments: scanArguments,
            environment: environment
        )

        guard processOutput.exitCode == 0 else {
            throw RecognitionFailure(
                title: "acrcloud filescan scan Failed",
                message: "Command exited with status \(processOutput.exitCode).\n\(Self.trimmedOutput(processOutput.output))",
                recoverySuggestion: Self.recoverySuggestion(for: processOutput.output)
            )
        }

        let result = try ACRCloudFileScanNormalizer.result(fromCLIOutput: processOutput.output)
        return ACRCloudFileScanExecution(
            command: processCommand,
            exitCode: processOutput.exitCode,
            output: processOutput.output,
            result: result
        )
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (exitCode: Int32, output: String) {
        #if os(macOS)
        guard let resolvedExecutablePath = ACRCloudFileScanConfiguration.resolveExecutablePath(
            executablePath,
            environment: environment
        ) else {
            throw RecognitionFailure(
                title: "acrcloud CLI Not Available",
                message: "Could not find executable `\(executablePath)` on the app process PATH.",
                recoverySuggestion: "Install the official CLI with `pip install acrcloud-cli`, or set ACRCLOUD_CLI to the full executable path in .env."
            )
        }

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedExecutablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw RecognitionFailure(
                title: "acrcloud CLI Not Available",
                message: error.localizedDescription,
                recoverySuggestion: "Install the official CLI with `pip install acrcloud-cli`, or set ACRCLOUD_CLI to the full executable path in .env."
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8)
            ?? String(decoding: outputData, as: UTF8.self)

        return (process.terminationStatus, output)
        #else
        throw RecognitionFailure(
            title: "ACRCloud CLI Not Available",
            message: "The filescan command-line client requires macOS.",
            recoverySuggestion: "Use the ACRCloud Identification API on this platform."
        )
        #endif
    }

    private static func recoverySuggestion(for output: String) -> String {
        if output.contains("No such file") || output.contains("not found") {
            return "Install the official CLI with `pip install acrcloud-cli`, or set ACRCLOUD_CLI to the full executable path in .env."
        }

        if output.localizedCaseInsensitiveContains("Access token") ||
            output.localizedCaseInsensitiveContains("Unauthorized") {
            return "Set a valid ACRCloud personal access token in ACRCLOUD_ACCESS_TOKEN."
        }

        return "Run `acrcloud filescan scan --help` to verify the installed CLI and arguments."
    }

    private static func trimmedOutput(_ output: String) -> String {
        let trimmed = output.trimmed
        guard trimmed.count > 2_000 else {
            return trimmed
        }

        return "\(trimmed.prefix(2_000))..."
    }
}

public enum ACRCloudIdentificationNormalizer {
    public static func result(from data: Data) throws -> ACRCloudIdentificationResult {
        let response = try JSONDecoder().decode(ACRCloudIdentificationResponse.self, from: data)
        return ACRCloudIdentificationResult(
            statusCode: response.status.code,
            statusMessage: response.status.message,
            music: response.metadata?.music?.first.flatMap(musicMatch(from:))
        )
    }

    private static func musicMatch(from match: ACRCloudIdentificationMusicDTO) -> ACRCloudMusicMatch? {
        guard let acrid = match.acrid?.trimmedNilIfEmpty,
              let title = match.title?.trimmedNilIfEmpty
        else {
            return nil
        }

        let artists = match.artists?
            .compactMap { $0.name?.trimmedNilIfEmpty }
            .filter { !$0.isEmpty } ?? []

        return ACRCloudMusicMatch(
            acrid: acrid,
            title: title,
            artists: artists,
            album: match.album?.name?.trimmedNilIfEmpty,
            durationMS: match.durationMS,
            isrc: match.externalIDs?.isrc?.trimmedNilIfEmpty,
            score: match.score,
            releaseDate: match.releaseDate?.trimmedNilIfEmpty,
            offsetSeconds: match.playOffsetMS.map { TimeInterval($0) / 1_000 },
            playedDurationSeconds: nil,
            matchType: nil,
            audioID: nil
        )
    }
}

public enum ACRCloudFileScanNormalizer {
    public static func result(fromCLIOutput output: String) throws -> ACRCloudFileScanResult {
        let jsonData = try finalJSONPayload(from: output)
        return try result(from: jsonData)
    }

    public static func result(from data: Data) throws -> ACRCloudFileScanResult {
        let response = try JSONDecoder().decode(ACRCloudFileScanResponse.self, from: data)

        guard let file = response.data?.first else {
            return ACRCloudFileScanResult(
                fileID: nil,
                containerID: nil,
                state: nil,
                stateDescription: "No file result",
                fileName: nil,
                durationSeconds: nil,
                music: nil
            )
        }

        let music = file.results?.music?.first.flatMap(musicMatch(from:))
        return ACRCloudFileScanResult(
            fileID: file.id?.trimmedNilIfEmpty,
            containerID: file.containerID,
            state: file.state,
            stateDescription: stateDescription(file.state),
            fileName: file.name?.trimmedNilIfEmpty,
            durationSeconds: file.duration,
            music: music
        )
    }

    public static func snapshot(
        from match: ACRCloudMusicMatch,
        clip: RecognitionAudioClip
    ) -> RecognitionSnapshot {
        let matchedRange: Range<TimeInterval>?
        if let offsetSeconds = match.offsetSeconds,
           let playedDurationSeconds = match.playedDurationSeconds,
           playedDurationSeconds > 0 {
            matchedRange = offsetSeconds..<(offsetSeconds + playedDurationSeconds)
        } else {
            matchedRange = nil
        }

        let track = RecognizedTrack(
            id: "acrcloud:\(match.acrid)",
            title: match.title,
            artist: match.artists.joined(separator: ", "),
            externalIDs: ExternalIDs(isrc: match.isrc),
            source: .acrCloud
        )
        let anchor = RecognitionAnchor(
            recognizedAt: Date(),
            predictedMatchOffset: match.offsetSeconds,
            matchedRanges: matchedRange.map { [$0] } ?? []
        )

        return RecognitionSnapshot(track: track, anchor: anchor)
    }

    private static func finalJSONPayload(from output: String) throws -> Data {
        let bytes = Array(output.utf8)
        let objectStart = UInt8(ascii: "{")

        for startIndex in bytes.indices where bytes[startIndex] == objectStart {
            let candidate = Data(bytes[startIndex...])
            if (try? JSONSerialization.jsonObject(with: candidate)) is [String: Any] {
                return candidate
            }
        }

        throw RecognitionFailure(
            title: "ACRCloud File Scan Output Was Not JSON",
            message: "acrcloud filescan scan did not print a final JSON result.\n\(output.trimmed)",
            recoverySuggestion: "Use --scan-timeout with a larger value, then retry or inspect the saved clip with acrcloud filescan get-file."
        )
    }

    private static func stateDescription(_ state: Int?) -> String {
        switch state {
        case 0:
            return "Processing"
        case 1:
            return "Ready"
        case -1:
            return "No results"
        case -2, -3:
            return "Error"
        case let state?:
            return "Unknown(\(state))"
        case nil:
            return "Unknown"
        }
    }

    private static func musicMatch(from match: ACRCloudFileScanMusicMatchDTO) -> ACRCloudMusicMatch? {
        guard let result = match.result,
              let acrid = result.acrid?.trimmedNilIfEmpty,
              let title = result.title?.trimmedNilIfEmpty
        else {
            return nil
        }

        let artists = result.artists?
            .compactMap { $0.name?.trimmedNilIfEmpty }
            .filter { !$0.isEmpty } ?? []

        return ACRCloudMusicMatch(
            acrid: acrid,
            title: title,
            artists: artists,
            album: result.album?.name?.trimmedNilIfEmpty,
            durationMS: result.durationMS,
            isrc: result.externalIDs?.isrc?.trimmedNilIfEmpty,
            score: result.score ?? match.score,
            releaseDate: result.releaseDate?.trimmedNilIfEmpty,
            offsetSeconds: match.offset,
            playedDurationSeconds: match.playedDuration,
            matchType: match.type?.trimmedNilIfEmpty,
            audioID: result.audioID?.trimmedNilIfEmpty
        )
    }
}

private struct ACRCloudFileScanResponse: Decodable {
    let data: OneOrMany<ACRCloudFileScanFileDTO>?
}

private struct ACRCloudIdentificationResponse: Decodable {
    let status: ACRCloudIdentificationStatusDTO
    let metadata: ACRCloudIdentificationMetadataDTO?
}

private struct ACRCloudIdentificationStatusDTO: Decodable {
    let code: Int
    let message: String

    enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
    }
}

private struct ACRCloudIdentificationMetadataDTO: Decodable {
    let music: [ACRCloudIdentificationMusicDTO]?
}

private struct ACRCloudIdentificationMusicDTO: Decodable {
    let acrid: String?
    let title: String?
    let artists: [ACRCloudNamedDTO]?
    let album: ACRCloudNamedDTO?
    let durationMS: Int?
    let externalIDs: ACRCloudExternalIDsDTO?
    let score: Int?
    let releaseDate: String?
    let playOffsetMS: Int?

    enum CodingKeys: String, CodingKey {
        case acrid
        case title
        case artists
        case album
        case durationMS = "duration_ms"
        case externalIDs = "external_ids"
        case score
        case releaseDate = "release_date"
        case playOffsetMS = "play_offset_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        acrid = try? container.decode(String.self, forKey: .acrid)
        title = try? container.decode(String.self, forKey: .title)
        artists = try? container.decode([ACRCloudNamedDTO].self, forKey: .artists)
        album = try? container.decode(ACRCloudNamedDTO.self, forKey: .album)
        durationMS = try container.decodeFlexibleIntIfPresent(forKey: .durationMS)
        externalIDs = try? container.decode(ACRCloudExternalIDsDTO.self, forKey: .externalIDs)
        score = try container.decodeFlexibleIntIfPresent(forKey: .score)
        releaseDate = try? container.decode(String.self, forKey: .releaseDate)
        playOffsetMS = try container.decodeFlexibleIntIfPresent(forKey: .playOffsetMS)
    }
}

private enum OneOrMany<Element: Decodable>: Decodable {
    case one(Element)
    case many([Element])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([Element].self) {
            self = .many(values)
        } else {
            self = .one(try container.decode(Element.self))
        }
    }

    var first: Element? {
        switch self {
        case .one(let element):
            return element
        case .many(let elements):
            return elements.first
        }
    }
}

private struct ACRCloudFileScanFileDTO: Decodable {
    let id: String?
    let containerID: Int?
    let state: Int?
    let name: String?
    let duration: TimeInterval?
    let results: ACRCloudFileScanResultsDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case containerID = "cid"
        case state
        case name
        case duration
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        containerID = try container.decodeFlexibleIntIfPresent(forKey: .containerID)
        state = try container.decodeFlexibleIntIfPresent(forKey: .state)
        name = try? container.decode(String.self, forKey: .name)
        duration = try container.decodeFlexibleDoubleIfPresent(forKey: .duration)
        results = try? container.decode(ACRCloudFileScanResultsDTO.self, forKey: .results)
    }
}

private struct ACRCloudFileScanResultsDTO: Decodable {
    let music: [ACRCloudFileScanMusicMatchDTO]?
}

private struct ACRCloudFileScanMusicMatchDTO: Decodable {
    let offset: TimeInterval?
    let playedDuration: TimeInterval?
    let type: String?
    let score: Int?
    let result: ACRCloudFileScanMusicResultDTO?

    enum CodingKeys: String, CodingKey {
        case offset
        case playedDuration = "played_duration"
        case type
        case score
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = try container.decodeFlexibleDoubleIfPresent(forKey: .offset)
        playedDuration = try container.decodeFlexibleDoubleIfPresent(forKey: .playedDuration)
        type = try? container.decode(String.self, forKey: .type)
        score = try container.decodeFlexibleIntIfPresent(forKey: .score)
        result = try? container.decode(ACRCloudFileScanMusicResultDTO.self, forKey: .result)
    }
}

private struct ACRCloudFileScanMusicResultDTO: Decodable {
    let acrid: String?
    let title: String?
    let artists: [ACRCloudNamedDTO]?
    let album: ACRCloudNamedDTO?
    let durationMS: Int?
    let externalIDs: ACRCloudExternalIDsDTO?
    let score: Int?
    let releaseDate: String?
    let audioID: String?

    enum CodingKeys: String, CodingKey {
        case acrid
        case title
        case artists
        case album
        case durationMS = "duration_ms"
        case externalIDs = "external_ids"
        case score
        case releaseDate = "release_date"
        case audioID = "audio_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        acrid = try? container.decode(String.self, forKey: .acrid)
        title = try? container.decode(String.self, forKey: .title)
        artists = try? container.decode([ACRCloudNamedDTO].self, forKey: .artists)
        album = try? container.decode(ACRCloudNamedDTO.self, forKey: .album)
        durationMS = try container.decodeFlexibleIntIfPresent(forKey: .durationMS)
        externalIDs = try? container.decode(ACRCloudExternalIDsDTO.self, forKey: .externalIDs)
        score = try container.decodeFlexibleIntIfPresent(forKey: .score)
        releaseDate = try? container.decode(String.self, forKey: .releaseDate)
        audioID = try? container.decode(String.self, forKey: .audioID)
    }
}

private struct ACRCloudNamedDTO: Decodable {
    let name: String?

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            name = value
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directName = try? container.decode(String.self, forKey: .name)
        let localizedName = (try? container.decode([ACRCloudNamedDTO].self, forKey: .langs))?.first?.name
        name = directName ?? localizedName
    }

    enum CodingKeys: String, CodingKey {
        case name
        case langs
    }
}

private struct ACRCloudExternalIDsDTO: Decodable {
    let isrc: String?
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        if let intValue = try? decode(Int.self, forKey: key) {
            return intValue
        }
        if let doubleValue = try? decode(Double.self, forKey: key) {
            return Int(doubleValue)
        }
        if let stringValue = try? decode(String.self, forKey: key) {
            return Int(stringValue)
        }
        return nil
    }

    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let doubleValue = try? decode(Double.self, forKey: key) {
            return doubleValue
        }
        if let intValue = try? decode(Int.self, forKey: key) {
            return Double(intValue)
        }
        if let stringValue = try? decode(String.self, forKey: key) {
            return Double(stringValue)
        }
        return nil
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedNilIfEmpty: String? {
        let trimmed = self.trimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
