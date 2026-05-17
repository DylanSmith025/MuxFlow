import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var languageName = ""
    @State private var languageTag = ""

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(languageName: $languageName, languageTag: $languageTag)
                .frame(width: 320)

            Divider()

            WorkbenchView()
                .frame(minWidth: 650)

            Divider()

            InspectorView()
                .frame(width: 420)
        }
        .background(AppTheme.background)
        .alert("输出文件已存在", isPresented: $state.showingConflictAlert) {
            Button("取消", role: .cancel) { state.notice = "已取消转换。" }
            Button("覆盖并转换", role: .destructive) { state.convert(overwrite: true) }
        } message: {
            Text(conflictMessage)
        }
    }

    private var conflictMessage: String {
        let shown = state.conflictPaths.prefix(8).map(\.lastPathComponent).joined(separator: "\n")
        return "以下 \(state.conflictPaths.count) 个输出文件已存在，是否覆盖？\n\n\(shown)"
    }

    private func loadDroppedURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let url {
                urls.append(url)
            }
        }
        return urls
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Binding var languageName: String
    @Binding var languageTag: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("MuxFlow", systemImage: "film.stack")
                    .font(.system(size: 24, weight: .bold))
                Text("批量封装、整理轨道，一次处理整季。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ActionButton(title: "扫描轨道", icon: "waveform.badge.magnifyingglass") {
                    state.scan()
                }
                .disabled(state.isScanning || state.isConverting)

                ActionButton(title: "开始转换", icon: "play.fill", prominent: true) {
                    state.requestConvert()
                }
                .disabled(state.isScanning || state.isConverting)
            }

            GlassSection("输出") {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(AppTheme.tint)
                    Text(state.outputDir?.path ?? "请选择输出文件夹")
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择") {
                        state.chooseOutputDir()
                    }
                    .controlSize(.small)
                }
            }

            GlassSection("轨道规则") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("轨道名称-语言标签")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(state.languagePresets) { preset in
                                LanguagePresetEditorRow(preset: preset)
                            }
                        }
                        .padding(.trailing, 8)
                    }
                    .frame(height: 118)

                    Divider()

                    Text("规则添加")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("名称，例如：简体中文", text: $languageName)
                    TextField("语言标签，例如：zh-Hans", text: $languageTag)

                    Button {
                        state.addLanguagePreset(name: languageName, tag: languageTag)
                        languageName = ""
                        languageTag = ""
                    } label: {
                        Label("添加轨道规则", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(languageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || languageTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            GlassSection("概览") {
                VStack(spacing: 10) {
                    MetricRow(title: "输入", value: "\(state.inputPaths.count)")
                    MetricRow(title: "文件", value: "\(state.files.count)")
                    MetricRow(title: "可转换", value: "\(state.readyFiles.count)")
                }
            }

            Spacer()
        }
        .padding(20)
        .background(AppTheme.sidebar)
    }
}

struct LanguagePresetEditorRow: View {
    @EnvironmentObject private var state: AppState
    let preset: LanguagePreset

    var body: some View {
        HStack(spacing: 8) {
            TextField("轨道名称", text: nameBinding)
                .textFieldStyle(.roundedBorder)

            TextField("语言标签", text: tagBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Button(role: .destructive) {
                state.deleteLanguagePreset(preset)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var nameBinding: Binding<String> {
        Binding {
            state.languagePresets.first { $0.id == preset.id }?.name ?? preset.name
        } set: { newValue in
            state.updateLanguagePreset(preset, name: newValue)
        }
    }

    private var tagBinding: Binding<String> {
        Binding {
            state.languagePresets.first { $0.id == preset.id }?.tag ?? preset.tag
        } set: { newValue in
            state.updateLanguagePreset(preset, tag: newValue)
        }
    }
}

struct WorkbenchView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DropTargetCard()

            if !state.notice.isEmpty {
                if state.isConverting {
                    NoticeCard(
                        message: state.notice,
                        progress: state.conversionProgress,
                        progressText: state.conversionProgressText,
                        onCancel: { state.cancelConversion() }
                    )
                } else {
                    NoticeCard(message: state.notice)
                }
            }

            if let file = state.selectedFile {
                VStack(alignment: .leading, spacing: 6) {
                    Text("内封轨道")
                        .font(.title2.weight(.bold))
                    Text(state.selectedGroupFiles.count > 1 ? "当前选中 \(state.selectedGroupFiles.count) 个同类文件，修改会同步到这一组。" : file.fileName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !file.warnings.isEmpty {
                    NoticeCard(message: file.warnings.joined(separator: "；"), symbol: "exclamationmark.triangle.fill", tint: .orange)
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(file.tracks) { track in
                            TrackEditorCard(file: file, track: track)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .contentMargins(.trailing, 10, for: .scrollIndicators)
            } else {
                EmptyState()
            }
        }
        .padding(22)
    }
}

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("文件列表")
                    .font(.title2.weight(.bold))
                Spacer()
                Text("\(state.files.count) 个文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if state.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("扫描后显示文件列表")
                        .font(.headline)
                    Text("相同轨道结构的文件会折叠在一起。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(state.fileGroups) { group in
                            FileGroupCard(
                                group: group,
                                isSelected: state.selectedFileGroupKey == group.key,
                                isExpanded: expandedGroups.contains(group.key),
                                onSelect: { state.select(group: group) },
                                onToggle: { toggle(group.key) }
                            )
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(20)
        .background(AppTheme.sidebar)
    }

    private func toggle(_ key: String) {
        if expandedGroups.contains(key) {
            expandedGroups.remove(key)
        } else {
            expandedGroups.insert(key)
        }
    }
}

struct FileGroupCard: View {
    let group: FileGroup
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? AppTheme.tint : .secondary)
                }
                .buttonStyle(.plain)

                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(group.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(group.files) { file in
                        FileRow(file: file)
                    }
                }
                .padding(.leading, 48)
            }
        }
        .padding(12)
        .background(isSelected ? AppTheme.selectedSurface : AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(isSelected ? AppTheme.tint.opacity(0.45) : AppTheme.border, lineWidth: 1)
        )
    }
}

struct FileRow: View {
    let file: MediaFile

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: file.status)
            Text(file.fileName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous))
    }
}

struct StatusDot: View {
    let status: FileStatus

    var body: some View {
        Circle()
            .fill(StatusPill.color(for: status))
            .frame(width: 8, height: 8)
    }
}

struct DropTargetCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.selectedSurface)
                    .frame(width: 46, height: 46)
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(AppTheme.tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.inputPaths.isEmpty ? "拖入 TS 文件或剧集文件夹" : "已添加 \(state.inputPaths.count) 个输入")
                    .font(.headline)
                Text(state.inputPaths.isEmpty ? "支持递归扫描文件夹，扫描前会先套用当前轨道预设。" : state.inputPaths.map(\.lastPathComponent).joined(separator: "、"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !state.inputPaths.isEmpty {
                Button {
                    state.clearInputPaths()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空输入")
                .disabled(state.isScanning || state.isConverting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.border, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                let urls = await loadDroppedURLs(from: providers)
                await MainActor.run {
                    if !urls.isEmpty {
                        state.addDropped(urls: urls)
                    }
                }
            }
            return true
        }
    }

    private func loadDroppedURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let url {
                urls.append(url)
            }
        }
        return urls
    }
}

struct FileCard: View {
    let file: MediaFile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 36, height: 36)
                .background(statusColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(file.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Text(file.outputPath.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(status: file.status)
                Text("\(file.tracks.count) 条轨道")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(isSelected ? AppTheme.selectedSurface : AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(isSelected ? AppTheme.tint.opacity(0.45) : AppTheme.border, lineWidth: 1)
        )
    }

    private var icon: String {
        switch file.status {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .warning: "exclamationmark.triangle.fill"
        case .ready: "film"
        }
    }

    private var statusColor: Color {
        StatusPill.color(for: file.status)
    }
}

struct TrackEditorCard: View {
    @EnvironmentObject private var state: AppState
    let file: MediaFile
    let track: MediaTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(track.trackType) #\(track.typeIndex + 1)", systemImage: symbol)
                    .font(.headline)
                Spacer()
                Text(track.codec)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }

            Toggle("转换后保留这条轨道", isOn: binding(\.include))

            VStack(alignment: .leading, spacing: 8) {
                Text("轨道名称")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("轨道名称", selection: trackNameSelection) {
                    Text("保持当前").tag("")
                    ForEach(state.languagePresets) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("语言标签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("语言标签", text: binding(\.language))
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 12) {
                FlagToggle(title: "默认", isOn: binding(\.defaultTrack))
                FlagToggle(title: "强制", isOn: binding(\.forcedDisplay))
                FlagToggle(title: "启用", isOn: binding(\.enabled))
            }

            if state.selectedGroupFiles.count <= 1 {
                Button {
                    state.applyToMatchingTracks(track)
                } label: {
                    Label("应用到所有匹配轨道", systemImage: "square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MediaTrack, Value>) -> Binding<Value> {
        Binding {
            track[keyPath: keyPath]
        } set: { newValue in
            state.update(track: track, in: file) { $0[keyPath: keyPath] = newValue }
        }
    }

    private var trackNameSelection: Binding<String> {
        Binding {
            state.languagePresets.first { $0.name == track.name }?.name ?? ""
        } set: { selectedName in
            guard let preset = state.languagePreset(forName: selectedName) else { return }
            state.update(track: track, in: file) {
                $0.name = preset.name
                $0.language = preset.tag
            }
        }
    }

    private var symbol: String {
        switch track.trackType {
        case "video": "video.fill"
        case "audio": "waveform"
        case "subtitles": "captions.bubble.fill"
        default: "rectangle.stack.fill"
        }
    }
}

struct FlagToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GlassSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

struct StatusPill: View {
    let status: FileStatus

    var body: some View {
        Text(label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Self.color(for: status).opacity(0.16))
            .foregroundStyle(Self.color(for: status))
            .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .ready: "就绪"
        case .warning: "警告"
        case .running: "转换中"
        case .done: "完成"
        case .failed: "失败"
        }
    }

    static func color(for status: FileStatus) -> Color {
        switch status {
        case .ready: .secondary
        case .warning: .orange
        case .running: .blue
        case .done: .green
        case .failed: .red
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? .white : AppTheme.tint)
        .background(prominent ? AppTheme.tint : AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }
}

struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.callout)
    }
}

struct NoticeCard: View {
    let message: String
    var progress: Double?
    var progressText: String?
    var onCancel: (() -> Void)?
    var symbol = "info.circle.fill"
    var tint = AppTheme.tint

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("取消转换")
                }
            }

            if let progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    if let progressText {
                        Text(progressText)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 38, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.tint.opacity(0.72))
            Text("等待扫描")
                .font(.headline)
            Text("拖入剧集后点击扫描，轨道检查器会显示每集的可编辑轨道。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(44)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }
}

enum AppTheme {
    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 12
    static let tint = adaptiveColor(
        light: rgb(0.18, 0.31, 0.48),
        dark: rgb(0.43, 0.66, 1.00)
    )
    static let background = LinearGradient(
        colors: [
            adaptiveColor(light: rgb(0.97, 0.98, 0.99), dark: rgb(0.06, 0.07, 0.09)),
            adaptiveColor(light: rgb(0.91, 0.94, 0.97), dark: rgb(0.09, 0.11, 0.13)),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let sidebar = adaptiveColor(
        light: rgb(0.94, 0.96, 0.98),
        dark: rgb(0.09, 0.11, 0.13)
    )
    static let surface = adaptiveColor(
        light: rgb(1.00, 1.00, 1.00, alpha: 0.88),
        dark: rgb(0.13, 0.15, 0.19)
    )
    static let selectedSurface = adaptiveColor(
        light: rgb(0.88, 0.93, 0.98),
        dark: rgb(0.15, 0.20, 0.28)
    )
    static let border = adaptiveColor(
        light: rgb(0.00, 0.00, 0.00, alpha: 0.08),
        dark: rgb(1.00, 1.00, 1.00, alpha: 0.14)
    )

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let darkAppearances: [NSAppearance.Name] = [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]
            let bestMatch = appearance.bestMatch(from: darkAppearances + [.aqua, .vibrantLight])
            return darkAppearances.contains(bestMatch ?? .aqua) ? dark : light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}
