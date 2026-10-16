import Foundation

/// A subtitle the user can pick: a track in the file, or a sidecar `.srt` beside it (spec §4).
public struct SubtitleOption: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable {
        case embedded(TrackRef)
        case sidecar(URL)
    }

    public var source: Source
    /// As the file gives it: `eng`, `en`, `pt-BR`. nil when unknown.
    public var language: String?
    public var title: String?
    public var isForced: Bool
    /// Text (SRT, ASS, WebVTT, mov_text) becomes a subtitle track the TV shows; pictures (PGS,
    /// VobSub, DVB) are burned into the video.
    public var isText: Bool

    public init(source: Source, language: String?, title: String?, isForced: Bool, isText: Bool) {
        self.source = source
        self.language = language
        self.title = title
        self.isForced = isForced
        self.isText = isText
    }

    /// Stable within one playback.
    public var id: String {
        switch source {
        case .embedded(let ref): "track-\(ref.input)-\(ref.index)"
        case .sidecar(let url): "file-\(url.lastPathComponent)"
        }
    }

    /// The file's tracks Paper Plane can show, then the sidecar files, in that order.
    public static func all(in media: MediaInfo, sidecars: [SidecarSubtitles.File]) -> [SubtitleOption] {
        media.subtitles.filter { $0.kind != .unsupported }.map {
            SubtitleOption(source: .embedded($0.ref), language: $0.language, title: $0.title, isForced: $0.isForced,
                           isText: $0.kind == .text)
        } + sidecars.map {
            SubtitleOption(source: .sidecar($0.url), language: $0.language, title: $0.url.lastPathComponent,
                           isForced: $0.isForced, isText: true)
        }
    }

    /// "English", "English (SDH)", "French (Forced)", or "Subtitles" when nothing is known.
    public var displayName: String {
        TrackNames.name(language: language, title: title, fallback: "Subtitles", extra: isForced ? "Forced" : nil)
    }
}

extension AudioTrack {
    /// "English (5.1)", "Japanese — Commentary (Stereo)", "Audio" when nothing is known.
    public var displayName: String {
        let layout = switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) channels"
        }
        return TrackNames.name(language: language, title: title, fallback: "Audio", extra: layout)
    }
}

public enum TrackNames {
    /// "English", from `eng`, `en` or `EN`; "Portuguese (Brazil)" from `pt-BR`. nil for codes
    /// Foundation doesn't know.
    public static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Locale(identifier: "en").localizedString(forIdentifier: code)
    }

    /// The tag HLS's `LANGUAGE` wants (RFC 5646): the two-letter code where one exists (`eng` →
    /// `en`), otherwise the code as given.
    public static func languageTag(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let language = Locale.Language(identifier: bibliographicCodes[code.lowercased()] ?? code)
        guard let base = language.languageCode?.identifier(.alpha2) else { return code }
        return [base, language.region?.identifier].compactMap { $0 }.joined(separator: "-")
    }

    /// ISO 639-2's bibliographic codes, which Matroska files often use, and their two-letter
    /// equivalents. Foundation only knows the terminological ones (`fra`, not `fre`).
    private static let bibliographicCodes = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr",
        "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms", "per": "fa",
        "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
    ]

    /// The name is also a playlist NAME, a quoted value that can't hold a double quote or a line
    /// break, and the player's options are matched by it; so it never has either.
    static func name(language: String?, title: String?, fallback: String, extra: String?) -> String {
        let languageName = languageName(language)
        let title = title.map { String($0.map { $0 == "\"" ? "'" : $0.isNewline ? " " : $0 }) }
        var name = languageName ?? title ?? fallback
        if languageName != nil, let title, !title.isEmpty {
            name += " — \(title)"
        }
        if let extra {
            name += " (\(extra))"
        }
        return name
    }

    /// `names` made unique, so each can identify one track: a repeat gets the lowest " 2", " 3", …
    /// that no other track is already called.
    public static func unique(_ names: [String]) -> [String] {
        let given = Set(names)
        var taken: Set<String> = []
        return names.map { name in
            var candidate = name
            var number = 1
            while taken.contains(candidate) || (number > 1 && given.contains(candidate)) {
                number += 1
                candidate = "\(name) \(number)"
            }
            taken.insert(candidate)
            return candidate
        }
    }
}
