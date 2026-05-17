import Foundation

final class PresetStore {
    private let key = "MuxFlow.Settings"

    func load() -> PersistedSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(PersistedSettings.self, from: data)
        else {
            return PersistedSettings(
                lastOutputDir: nil,
                recentInputPaths: [],
                presets: [],
                languagePresets: Self.defaultLanguagePresets
            )
        }

        return PersistedSettings(
            lastOutputDir: settings.lastOutputDir,
            recentInputPaths: settings.recentInputPaths,
            presets: settings.presets ?? [],
            languagePresets: normalizedLanguagePresets(from: settings.languagePresets)
        )
    }

    func save(outputDir: URL?, recentInputPaths: [URL], languagePresets: [LanguagePreset]) {
        let settings = PersistedSettings(
            lastOutputDir: outputDir,
            recentInputPaths: recentInputPaths,
            presets: [],
            languagePresets: languagePresets.isEmpty ? Self.defaultLanguagePresets : languagePresets
        )
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func normalizedLanguagePresets(from presets: [LanguagePreset]?) -> [LanguagePreset] {
        let source = presets?.isEmpty == false ? presets! : Self.defaultLanguagePresets
        return source.sorted {
            if $0.name == $1.name {
                return $0.tag.localizedStandardCompare($1.tag) == .orderedAscending
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static let defaultLanguagePresets: [LanguagePreset] = [
        LanguagePreset(id: UUID(uuidString: "C1A9B044-25E3-4305-A40E-1382E06B29F9")!, name: "简体中文", tag: "zh-Hans"),
        LanguagePreset(id: UUID(uuidString: "D09D4FC5-6C25-4F36-B52E-723C433AC081")!, name: "繁体中文", tag: "zh-Hant"),
        LanguagePreset(id: UUID(uuidString: "8E365F0D-E803-4C94-A504-22223E82B754")!, name: "粤语", tag: "yue"),
        LanguagePreset(id: UUID(uuidString: "8CB7186D-A15D-4B3E-BA46-B942951325D1")!, name: "日语", tag: "ja"),
        LanguagePreset(id: UUID(uuidString: "9F809FE4-783D-4395-9AD3-1BBE20D01BF4")!, name: "英语", tag: "en"),
    ]
}
