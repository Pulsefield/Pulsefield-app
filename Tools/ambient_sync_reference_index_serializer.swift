import Darwin
import Foundation
import PulsefieldCore

private struct Options {
    var roots: [URL] = []
    var overwrite = false
    var quiet = false
}

private enum ArgumentError: Error, LocalizedError {
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option):
            return "Unknown option: \(option)"
        }
    }
}

private let usage = """
Usage:
  ambient_sync_reference_index_serializer [--overwrite] [--quiet] [paths...]

If no paths are supplied, the helper scans LocalFixtures for
*.ambient-sync-reference-index.json and writes matching
*.ambient-sync-reference-index.bin files beside them.
"""

private func parseOptions(arguments: [String]) throws -> Options {
    var options = Options()

    for argument in arguments {
        switch argument {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--overwrite":
            options.overwrite = true
        case "--quiet":
            options.quiet = true
        default:
            if argument.hasPrefix("-") {
                throw ArgumentError.unknownOption(argument)
            }
            options.roots.append(URL(fileURLWithPath: argument).standardizedFileURL)
        }
    }

    if options.roots.isEmpty {
        options.roots = [URL(fileURLWithPath: "LocalFixtures").standardizedFileURL]
    }

    return options
}

private func referenceIndexJSONFiles(under root: URL) throws -> [URL] {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
        return []
    }

    if !isDirectory.boolValue {
        return isReferenceIndexJSON(root) ? [root] : []
    }

    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else {
        return []
    }

    var urls: [URL] = []
    for case let url as URL in enumerator where isReferenceIndexJSON(url) {
        urls.append(url.standardizedFileURL)
    }
    return urls.sorted { $0.path < $1.path }
}

private func isReferenceIndexJSON(_ url: URL) -> Bool {
    url.lastPathComponent.hasSuffix(".ambient-sync-reference-index.json")
}

private func run() throws {
    let options = try parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    let files = try options.roots.flatMap { root in
        try referenceIndexJSONFiles(under: root)
    }
    let uniqueFiles = Array(Set(files)).sorted { $0.path < $1.path }

    var convertedCount = 0
    var skippedCount = 0
    var failedCount = 0

    if !options.quiet {
        print("Found \(uniqueFiles.count) ambient sync reference-index JSON file(s).")
    }

    for jsonURL in uniqueFiles {
        let binaryURL = AmbientSyncReferenceIndexBuilder.binaryCacheURL(forLegacyJSONCacheURL: jsonURL)
        if FileManager.default.fileExists(atPath: binaryURL.path), !options.overwrite {
            skippedCount += 1
            if !options.quiet {
                print("skip \(jsonURL.path)")
            }
            continue
        }

        do {
            try AmbientSyncReferenceIndexBuilder.serializeCachedIndexJSON(
                at: jsonURL,
                outputURL: binaryURL
            )
            convertedCount += 1
            if !options.quiet {
                print("wrote \(binaryURL.path)")
            }
        } catch {
            failedCount += 1
            fputs("failed \(jsonURL.path): \(error.localizedDescription)\n", stderr)
        }
    }

    print("Converted: \(convertedCount), skipped: \(skippedCount), failed: \(failedCount).")
    if failedCount > 0 {
        exit(1)
    }
}

do {
    try run()
} catch {
    fputs("\(error.localizedDescription)\n\n\(usage)\n", stderr)
    exit(1)
}
