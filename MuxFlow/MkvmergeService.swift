import Foundation

enum MkvmergeServiceError: LocalizedError {
    case missingBundledExecutable
    case noTsFilesFound
    case noTracksSelected
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledExecutable:
            "没有找到内置 mkvmerge。"
        case .noTsFilesFound:
            "没有找到 .ts 文件。"
        case .noTracksSelected:
            "至少需要保留一条轨道。"
        case .processFailed(let message):
            message
        }
    }
}

final class MkvmergeService: @unchecked Sendable {
    static let progressStepsPerFile = 5

    private var bundledMkvmerge: URL? {
        Bundle.main.url(forResource: "mkvmerge", withExtension: nil)
    }

    func outputPath(for file: URL, in outputDir: URL) -> URL {
        outputDir
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("mkv")
    }

    func scan(inputPaths: [URL], outputDir: URL) async throws -> [MediaFile] {
        let files = try collectTsFiles(from: inputPaths)
        var mediaFiles: [MediaFile] = []

        for file in files {
            let outputPath = outputPath(for: file, in: outputDir)

            do {
                let tracks = try await identify(file)
                mediaFiles.append(
                    MediaFile(
                        path: file,
                        fileName: file.lastPathComponent,
                        outputPath: outputPath,
                        status: .ready,
                        warnings: [],
                        tracks: tracks
                    )
                )
            } catch {
                mediaFiles.append(
                    MediaFile(
                        path: file,
                        fileName: file.lastPathComponent,
                        outputPath: outputPath,
                        status: .warning,
                        warnings: [error.localizedDescription],
                        tracks: []
                    )
                )
            }
        }

        return mediaFiles
    }

    func outputConflicts(for files: [MediaFile]) -> [URL] {
        files
            .filter { !$0.tracks.isEmpty && FileManager.default.fileExists(atPath: $0.outputPath.path) }
            .map(\.outputPath)
    }

    func convert(_ file: MediaFile, overwrite: Bool, onProgress: @escaping @Sendable (Int) -> Void) async -> ConversionResult {
        do {
            try await convertOne(file, overwrite: overwrite, onProgress: onProgress)
            return ConversionResult(filePath: file.path, outputPath: file.outputPath, success: true, message: "完成")
        } catch {
            return ConversionResult(
                filePath: file.path,
                outputPath: file.outputPath,
                success: false,
                message: error.localizedDescription
            )
        }
    }

    private func identify(_ file: URL) async throws -> [MediaTrack] {
        let output = try await runMkvmerge(arguments: [
            "--identify",
            "--identification-format",
            "json",
            file.path,
        ])
        return try parseTracks(from: output.stdout)
    }

    private func convertOne(_ file: MediaFile, overwrite: Bool, onProgress: @escaping @Sendable (Int) -> Void) async throws {
        if FileManager.default.fileExists(atPath: file.outputPath.path), !overwrite {
            throw MkvmergeServiceError.processFailed("输出文件已存在，未授权覆盖。")
        }

        try FileManager.default.createDirectory(
            at: file.outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let selectedTracks = file.tracks.filter(\.include)
        guard !selectedTracks.isEmpty else { throw MkvmergeServiceError.noTracksSelected }

        var arguments = ["-o", file.outputPath.path]
        addSelectionArguments(to: &arguments, tracks: file.tracks)

        for track in selectedTracks {
            arguments.append(contentsOf: ["--language", "\(track.id):\(track.language.isEmpty ? "und" : track.language)"])
            arguments.append(contentsOf: ["--track-name", "\(track.id):\(track.name)"])
            arguments.append(contentsOf: ["--default-track", "\(track.id):\(yesNo(track.defaultTrack))"])
            arguments.append(contentsOf: ["--forced-display-flag", "\(track.id):\(yesNo(track.forcedDisplay))"])
            arguments.append(contentsOf: ["--track-enabled-flag", "\(track.id):\(yesNo(track.enabled))"])
        }

        arguments.append(file.path.path)
        arguments.append("--track-order")
        arguments.append(selectedTracks.map { "0:\($0.id)" }.joined(separator: ","))

        _ = try await runMkvmerge(arguments: arguments, onProgress: onProgress)
    }

    private func addSelectionArguments(to arguments: inout [String], tracks: [MediaTrack]) {
        for group in [
            ("video", "--video-tracks", "--no-video"),
            ("audio", "--audio-tracks", "--no-audio"),
            ("subtitles", "--subtitle-tracks", "--no-subtitles"),
        ] {
            let typedTracks = tracks.filter { $0.trackType == group.0 }
            guard !typedTracks.isEmpty else { continue }

            let selected = typedTracks.filter(\.include).map { String($0.id) }
            if selected.isEmpty {
                arguments.append(group.2)
            } else if selected.count != typedTracks.count {
                arguments.append(contentsOf: [group.1, selected.joined(separator: ",")])
            }
        }
    }

    private func runMkvmerge(arguments: [String], onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> (stdout: Data, stderr: Data) {
        guard let executable = bundledMkvmerge else {
            throw MkvmergeServiceError.missingBundledExecutable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let output = MkvmergeProcessOutput()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                output.append(handle.availableData, isStandardOutput: true, onProgress: onProgress)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                output.append(handle.availableData, isStandardOutput: false, onProgress: onProgress)
            }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                output.append(stdout.fileHandleForReading.readDataToEndOfFile(), isStandardOutput: true, onProgress: onProgress)
                output.append(stderr.fileHandleForReading.readDataToEndOfFile(), isStandardOutput: false, onProgress: onProgress)

                let finalOutput = output.snapshot()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: finalOutput)
                } else {
                    let message = String(data: finalOutput.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: MkvmergeServiceError.processFailed(message?.isEmpty == false ? message! : "mkvmerge 执行失败。"))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func collectTsFiles(from urls: [URL]) throws -> [URL] {
        var files: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                while let item = enumerator?.nextObject() as? URL {
                    if item.pathExtension.lowercased() == "ts" {
                        files.append(item)
                    }
                }
            } else if url.pathExtension.lowercased() == "ts" {
                files.append(url)
            }
        }

        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !files.isEmpty else { throw MkvmergeServiceError.noTsFilesFound }
        return files
    }

    private func parseTracks(from data: Data) throws -> [MediaTrack] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any],
              let tracks = root["tracks"] as? [[String: Any]]
        else {
            return []
        }

        var indexes: [String: Int] = [:]
        return tracks.map { item in
            let trackType = item["type"] as? String ?? "unknown"
            let typeIndex = indexes[trackType, default: 0]
            indexes[trackType] = typeIndex + 1

            let properties = item["properties"] as? [String: Any] ?? [:]
            return MediaTrack(
                id: item["id"] as? Int ?? 0,
                trackType: trackType,
                typeIndex: typeIndex,
                codec: item["codec"] as? String ?? "unknown",
                language: properties["language"] as? String ?? "und",
                name: properties["track_name"] as? String ?? "",
                include: true,
                defaultTrack: properties["default_track"] as? Bool ?? false,
                forcedDisplay: properties["forced_track"] as? Bool ?? false,
                enabled: properties["enabled_track"] as? Bool ?? true
            )
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}

private final class MkvmergeProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var lastProgress = -1

    func append(_ data: Data, isStandardOutput: Bool, onProgress: (@Sendable (Int) -> Void)?) {
        guard !data.isEmpty else { return }

        lock.lock()
        if isStandardOutput {
            stdout.append(data)
        } else {
            stderr.append(data)
        }

        let progress = onProgress.flatMap { _ in
            Self.latestProgressPercent(from: stdout) ?? Self.latestProgressPercent(from: stderr)
        }
        let shouldReport = progress.map { $0 > lastProgress } ?? false
        if let progress, shouldReport {
            lastProgress = progress
        }
        lock.unlock()

        if let progress, shouldReport {
            onProgress?(progress)
        }
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.lock()
        let output = (stdout: stdout, stderr: stderr)
        lock.unlock()
        return output
    }

    private static func latestProgressPercent(from data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let pattern = #"Progress:\s*(\d{1,3})%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let percentRange = Range(match.range(at: 1), in: text),
              let percent = Int(text[percentRange])
        else {
            return nil
        }

        return min(max(percent, 0), 100)
    }
}
