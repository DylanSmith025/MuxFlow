import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var inputPaths: [URL] = []
    @Published var outputDir: URL?
    @Published var files: [MediaFile] = []
    @Published var languagePresets: [LanguagePreset] = []
    @Published var selectedFileGroupKey: String?
    @Published var isScanning = false
    @Published var isConverting = false
    @Published var notice = ""
    @Published var conflictPaths: [URL] = []
    @Published var showingConflictAlert = false
    @Published var selectedFileID: String?
    @Published var conversionCompleted = 0
    @Published var conversionTotal = 0
    @Published var conversionCurrentStep = 0

    private let store = PresetStore()
    private let service = MkvmergeService()
    private var conversionTask: Task<Void, Never>?

    var readyFiles: [MediaFile] {
        files.filter { !$0.tracks.isEmpty }
    }

    var selectedFile: MediaFile? {
        if let selectedFileID,
           let file = files.first(where: { $0.id == selectedFileID }) {
            return file
        }
        return sortedFiles.first
    }

    var sortedFiles: [MediaFile] {
        files.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    var fileGroups: [FileGroup] {
        let grouped = Dictionary(grouping: files, by: fileGroupKey(for:))
        return grouped.map { key, files in
            FileGroup(key: key, files: files.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending })
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var conversionProgress: Double {
        guard conversionTotal > 0 else { return 0 }
        let totalSteps = conversionTotal * MkvmergeService.progressStepsPerFile
        let completedSteps = conversionCompleted * MkvmergeService.progressStepsPerFile + conversionCurrentStep
        return Double(completedSteps) / Double(totalSteps)
    }

    var conversionProgressText: String {
        "\(Int((conversionProgress * 100).rounded()))%"
    }

    var selectedGroupFiles: [MediaFile] {
        guard let selectedFileGroupKey else {
            return selectedFile.map { [$0] } ?? []
        }
        return files.filter { fileGroupKey(for: $0) == selectedFileGroupKey }
    }

    init() {
        let settings = store.load()
        outputDir = settings.lastOutputDir
        inputPaths = settings.recentInputPaths
        languagePresets = sortedLanguagePresets(settings.languagePresets ?? PresetStore.defaultLanguagePresets)
    }

    func persist() {
        store.save(outputDir: outputDir, recentInputPaths: inputPaths, languagePresets: languagePresets)
    }

    func addDropped(urls: [URL]) {
        inputPaths = urls
        files = []
        selectedFileID = nil
        selectedFileGroupKey = nil
        persist()
        notice = "已添加 \(urls.count) 个输入，选择输出文件夹后可以扫描。"
    }

    func clearInputPaths() {
        inputPaths = []
        files = []
        selectedFileID = nil
        selectedFileGroupKey = nil
        conversionCompleted = 0
        conversionTotal = 0
        conversionCurrentStep = 0
        persist()
        notice = "已清空输入。"
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDir
        panel.prompt = "选择"

        if panel.runModal() == .OK {
            guard let selectedOutputDir = panel.url else { return }
            outputDir = selectedOutputDir
            refreshOutputPaths(in: selectedOutputDir)
            conflictPaths = []
            showingConflictAlert = false
            persist()
        }
    }

    func scan() {
        guard let outputDir else {
            notice = "请先选择输出文件夹。"
            return
        }
        guard !inputPaths.isEmpty else {
            notice = "请把 .ts 文件或文件夹拖进窗口。"
            return
        }

        isScanning = true
        notice = "正在扫描轨道..."

        Task {
            do {
                let scanned = try await service.scan(
                    inputPaths: inputPaths,
                    outputDir: outputDir
                )
                files = scanned
                let initialFile = preferredInitialFile(in: scanned)
                selectedFileID = initialFile?.id
                selectedFileGroupKey = initialFile.map { fileGroupKey(for: $0) }
                notice = "扫描完成：\(scanned.count) 个文件。"
            } catch {
                notice = error.localizedDescription
            }
            isScanning = false
        }
    }

    func requestConvert() {
        guard !readyFiles.isEmpty else {
            notice = "没有可转换的文件。"
            return
        }

        conflictPaths = service.outputConflicts(for: readyFiles)
        if conflictPaths.isEmpty {
            convert(overwrite: false)
        } else {
            showingConflictAlert = true
        }
    }

    func convert(overwrite: Bool) {
        let batch = readyFiles
        conversionTask?.cancel()
        isConverting = true
        conversionCompleted = 0
        conversionTotal = batch.count
        conversionCurrentStep = 0
        notice = "正在转换..."

        conversionTask = Task {
            for file in batch {
                guard !Task.isCancelled else { break }
                conversionCurrentStep = 0
                setStatus(for: file.path, status: .running)
                let result = await service.convert(file, overwrite: overwrite) { [weak self] percent in
                    Task { @MainActor in
                        guard let self,
                              self.isConverting,
                              self.files.first(where: { $0.path == file.path })?.status == .running
                        else { return }
                        self.conversionCurrentStep = Self.progressStep(for: percent)
                    }
                }
                guard !Task.isCancelled else { break }
                if result.success {
                    setStatus(for: result.filePath, status: .done)
                    conversionCurrentStep = MkvmergeService.progressStepsPerFile
                } else {
                    setStatus(for: result.filePath, status: .failed, warning: result.message)
                }
                conversionCompleted += 1
                conversionCurrentStep = 0
            }
            isConverting = false
            conversionCurrentStep = 0
            notice = Task.isCancelled ? "已取消转换：完成 \(conversionCompleted) / \(conversionTotal) 个文件。" : "批量转换完成。"
            conversionTask = nil
        }
    }

    private static func progressStep(for percent: Int) -> Int {
        min(max(percent / 20, 0), MkvmergeService.progressStepsPerFile - 1)
    }

    func cancelConversion() {
        guard isConverting else { return }
        conversionTask?.cancel()
        notice = "正在取消转换..."
    }

    func update(track: MediaTrack, in file: MediaFile, patch: (inout MediaTrack) -> Void) {
        let targetIDs = selectedFileGroupKey == nil ? Set([file.id]) : Set(selectedGroupFiles.map(\.id))
        var changed = 0
        for fileIndex in files.indices where targetIDs.contains(files[fileIndex].id) {
            if let trackIndex = files[fileIndex].tracks.firstIndex(where: { $0.id == track.id }) {
                patch(&files[fileIndex].tracks[trackIndex])
                changed += 1
            }
        }
        if selectedFileGroupKey != nil, let selectedFile {
            self.selectedFileGroupKey = fileGroupKey(for: selectedFile)
        }
        if changed > 1 {
            notice = "已同步修改 \(changed) 个文件的 \(track.trackType) #\(track.typeIndex + 1)。"
        }
    }

    func updateSingle(track: MediaTrack, in file: MediaFile, patch: (inout MediaTrack) -> Void) {
        guard let fileIndex = files.firstIndex(where: { $0.id == file.id }),
              let trackIndex = files[fileIndex].tracks.firstIndex(where: { $0.id == track.id })
        else { return }

        patch(&files[fileIndex].tracks[trackIndex])
    }

    func select(file: MediaFile) {
        selectedFileID = file.id
        selectedFileGroupKey = fileGroupKey(for: file)
    }

    func select(group: FileGroup) {
        selectedFileGroupKey = group.key
        selectedFileID = group.files.first?.id
    }

    func addLanguagePreset(name: String, tag: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedTag.isEmpty else { return }

        if let index = languagePresets.firstIndex(where: { $0.name == trimmedName }) {
            languagePresets[index].tag = trimmedTag
        } else {
            languagePresets.append(LanguagePreset(id: UUID(), name: trimmedName, tag: trimmedTag))
        }
        languagePresets = sortedLanguagePresets(languagePresets)
        persist()
        notice = "已添加语言预设：\(trimmedName)-\(trimmedTag)"
    }

    func updateLanguagePreset(_ preset: LanguagePreset, name: String? = nil, tag: String? = nil) {
        guard let index = languagePresets.firstIndex(where: { $0.id == preset.id }) else { return }

        if let name {
            languagePresets[index].name = name
        }
        if let tag {
            languagePresets[index].tag = tag
        }

        languagePresets = sortedLanguagePresets(languagePresets)
        persist()
    }

    func deleteLanguagePreset(_ preset: LanguagePreset) {
        languagePresets.removeAll { $0.id == preset.id }
        languagePresets = sortedLanguagePresets(languagePresets)
        persist()
    }

    func languagePreset(forName name: String) -> LanguagePreset? {
        languagePresets.first { $0.name == name }
    }

    func applyToMatchingTracks(_ source: MediaTrack) {
        for fileIndex in files.indices {
            for trackIndex in files[fileIndex].tracks.indices {
                if TrackMatcher.matches(files[fileIndex].tracks[trackIndex], source) {
                    files[fileIndex].tracks[trackIndex].include = source.include
                    files[fileIndex].tracks[trackIndex].language = source.language
                    files[fileIndex].tracks[trackIndex].name = source.name
                    files[fileIndex].tracks[trackIndex].defaultTrack = source.defaultTrack
                    files[fileIndex].tracks[trackIndex].forcedDisplay = source.forcedDisplay
                    files[fileIndex].tracks[trackIndex].enabled = source.enabled
                }
            }
        }
        notice = "已应用到所有 \(source.trackType) #\(source.typeIndex + 1) \(source.codec) 轨道。"
    }

    func applyToSelectedGroup(_ source: MediaTrack) {
        let targetIDs = Set(selectedGroupFiles.map(\.id))
        guard !targetIDs.isEmpty else { return }

        var changed = 0
        for fileIndex in files.indices where targetIDs.contains(files[fileIndex].id) {
            if let trackIndex = files[fileIndex].tracks.firstIndex(where: { $0.id == source.id }) {
                files[fileIndex].tracks[trackIndex].include = source.include
                files[fileIndex].tracks[trackIndex].language = source.language
                files[fileIndex].tracks[trackIndex].name = source.name
                files[fileIndex].tracks[trackIndex].defaultTrack = source.defaultTrack
                files[fileIndex].tracks[trackIndex].forcedDisplay = source.forcedDisplay
                files[fileIndex].tracks[trackIndex].enabled = source.enabled
                changed += 1
            }
        }

        if let selectedFile = selectedFile {
            selectedFileGroupKey = fileGroupKey(for: selectedFile)
        }
        notice = "已修改这一组 \(changed) 个文件的 \(source.trackType) #\(source.typeIndex + 1)。"
    }

    private func setStatus(for path: URL, status: FileStatus, warning: String? = nil) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        files[index].status = status
        if let warning {
            files[index].warnings = [warning]
        }
    }

    private func refreshOutputPaths(in outputDir: URL) {
        for index in files.indices {
            files[index].outputPath = service.outputPath(for: files[index].path, in: outputDir)
        }
    }

    private func sortedLanguagePresets(_ presets: [LanguagePreset]) -> [LanguagePreset] {
        presets.sorted {
            if $0.name == $1.name {
                return $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func preferredInitialFile(in files: [MediaFile]) -> MediaFile? {
        let sorted = files.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        return sorted.first { $0.fileName.localizedCaseInsensitiveContains("S01E01") } ?? sorted.first
    }

    private func fileGroupKey(for file: MediaFile) -> String {
        let trackSignature = file.tracks
            .enumerated()
            .map { index, track in
                "\(index)|\(track.trackType)|\(track.typeIndex)|\(track.codec)|\(track.language)|\(track.name)"
            }
            .joined(separator: "||")

        return trackSignature.isEmpty ? "no-tracks" : trackSignature
    }
}

struct FileGroup: Identifiable {
    var id: String { key }
    let key: String
    let files: [MediaFile]

    var title: String {
        files.first?.fileName ?? "空分组"
    }

    var subtitle: String {
        "共 \(files.count) 个文件"
    }
}
