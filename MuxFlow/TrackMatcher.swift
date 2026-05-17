import Foundation

enum TrackMatcher {
    static func normalizeCodec(_ codec: String) -> String {
        codec
            .lowercased()
            .replacingOccurrences(of: "audio/", with: "")
            .replacingOccurrences(of: "video/", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    static func matches(_ track: MediaTrack, rule: TrackRule) -> Bool {
        track.trackType == rule.trackType
            && track.typeIndex == rule.typeIndex
            && normalizeCodec(track.codec) == normalizeCodec(rule.codec)
    }

    static func matches(_ lhs: MediaTrack, _ rhs: MediaTrack) -> Bool {
        lhs.trackType == rhs.trackType
            && lhs.typeIndex == rhs.typeIndex
            && normalizeCodec(lhs.codec) == normalizeCodec(rhs.codec)
    }

    static func apply(_ preset: TrackPreset?, to tracks: inout [MediaTrack]) -> [String] {
        guard let preset else { return [] }

        var warnings: [String] = []
        for rule in preset.rules {
            if let index = tracks.firstIndex(where: { matches($0, rule: rule) }) {
                tracks[index].include = rule.include
                tracks[index].language = rule.language
                tracks[index].name = rule.name
                tracks[index].defaultTrack = rule.defaultTrack
                tracks[index].forcedDisplay = rule.forcedDisplay
                tracks[index].enabled = rule.enabled
            } else {
                warnings.append("缺少匹配轨道：\(rule.trackType) #\(rule.typeIndex + 1) \(rule.codec)")
            }
        }
        return warnings
    }
}

