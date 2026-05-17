import Foundation

enum FileStatus: String, Codable {
    case ready
    case warning
    case running
    case done
    case failed
}

struct MediaFile: Identifiable, Codable {
    var id: String { path.path }
    var path: URL
    var fileName: String
    var outputPath: URL
    var status: FileStatus
    var warnings: [String]
    var tracks: [MediaTrack]
}

struct MediaTrack: Identifiable, Codable, Equatable {
    var id: Int
    var trackType: String
    var typeIndex: Int
    var codec: String
    var language: String
    var name: String
    var include: Bool
    var defaultTrack: Bool
    var forcedDisplay: Bool
    var enabled: Bool
}

struct TrackPreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var rules: [TrackRule]
}

struct LanguagePreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var tag: String
}

struct TrackRule: Codable, Equatable {
    var trackType: String
    var typeIndex: Int
    var codec: String
    var include: Bool
    var language: String
    var name: String
    var defaultTrack: Bool
    var forcedDisplay: Bool
    var enabled: Bool
}

struct PersistedSettings: Codable {
    var lastOutputDir: URL?
    var recentInputPaths: [URL]
    var presets: [TrackPreset]?
    var languagePresets: [LanguagePreset]?
}

struct ConversionResult {
    var filePath: URL
    var outputPath: URL
    var success: Bool
    var message: String
}
