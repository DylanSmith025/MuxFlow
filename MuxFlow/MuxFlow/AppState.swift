import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var inputPaths: [URL] = []
    @Published var outputDir: URL?
    @Published var files: [MediaFile] = []
    @Published var presets: [TrackPreset] = []
    @Published var languagePresets: [LanguagePreset] = []
    @Published var selectedPresetID: UUID?
    @Published var selectedFileGroupKey: String?
    @Published var isScanning = false
    @Published var isConverting = false
    @Published var notice = ""
    @Published var conflictPaths: [URL] = []
    @Published var showingConflictAlert = false
    @Published var selectedFileID: String?
    @Published var conversionCompleted = 0
    @Published var conversionTotal = 0

    private let store = PresetStore()
    private let service = MkvmergeService()
    private var conversionTask: Task<Void, Never>?

    var selectedPreset: TrackPreset? {
        presets.first { $0.id == selectedPresetID } ?? presets.first
    }

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
        return Double(conversionCompleted) / Double(conversionTotal)
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
        presets = settings.presets
        languagePresets = sortedLanguagePresets(settings.languagePresets ?? PresetStore.defaultLanguagePresets)
        selectedPresetID = settings.presets.first?.id
    }

    func persist() {
        store.save(outputDir: outputDir, recentInputPaths: inputPaths, presets: presets, languagePresets: languagePresets)
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
        persist()
        notice = "已清空输入。"
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"

        if panel.runModal() == .OK {
            outputDir = panel.url
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
                    outputDir: outputDir,
                    preset: selectedPreset
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
        notice = "正在转换..."

        conversionTask = Task {
            for file in batch {
                guard !Task.isCancelled else { break }
                setStatus(for: file.path, status: .running)
                let result = await service.convert(file, overwrite: overwrite)
                guard !Task.isCancelled else { break }
                if result.success {
                    setStatus(for: result.filePath, status: .done)
                } else {
                    setStatus(for: result.filePath, status: .failed, warning: result.message)
                }
                conversionCompleted += 1
            }
            isConverting = false
            notice = Task.isCancelled ? "已取消转换：完成 \(conversionCompleted) / \(conversionTotal) 个文件。" : "批量转换完成。"
            conversionTask = nil
        }
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

    func saveCurrentPreset(named name: String) {
        guard let file = files.first(where: { !$0.tracks.isEmpty }) else {
            notice = "扫描后才能保存预设。"
            return
        }

        let preset = TrackPreset(
            id: UUID(),
            name: name,
            rules: file.tracks.map {
                TrackRule(
                    trackType: $0.trackType,
                    typeIndex: $0.typeIndex,
                    codec: $0.codec,
                    include: $0.include,
                    language: $0.language,
                    name: $0.name,
                    defaultTrack: $0.defaultTrack,
                    forcedDisplay: $0.forcedDisplay,
                    enabled: $0.enabled
                )
            }
        )

        presets.append(preset)
        selectedPresetID = preset.id
        persist()
        notice = "已保存预设：\(name)"
    }

    func deleteSelectedPreset() {
        guard presets.count > 1, let selectedPresetID else { return }
        presets.removeAll { $0.id == selectedPresetID }
        self.selectedPresetID = presets.first?.id
        persist()
    }

    private func setStatus(for path: URL, status: FileStatus, warning: String? = nil) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        files[index].status = status
        if let warning {
            files[index].warnings = [warning]
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
