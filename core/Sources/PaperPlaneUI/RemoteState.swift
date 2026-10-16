import Foundation

/// Everything the remote window shows, as plain values, so the views can be rendered and
/// tested without a player.
public struct RemoteState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing is open.
        case idle
        /// Probing and converting the first segments.
        case preparing
        /// Ready, held until the user picks the TV. `tvWentAway` when it was playing before.
        case choosingTV(tvWentAway: Bool)
        case playing
        case paused
        /// A plain-language message.
        case failed(String)
    }

    /// One entry in the audio or subtitle picker.
    public struct Choice: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var phase: Phase
    public var title: String
    /// Size, range and length, e.g. "4K · HDR10 · 1 h 52 min".
    public var detail: String
    /// Movie time, in seconds.
    public var elapsed: Double
    /// nil while unknown.
    public var duration: Double?
    /// How far the conversion has got, in movie time. Seeking further starts a new session.
    public var converted: Double?
    /// 0…1.
    public var volume: Double
    /// Shows the one-time explainer instead of the drop zone.
    public var showsWelcome: Bool
    /// A passing message over whatever is showing, e.g. "“song.mp3” isn't a video file."
    public var notice: String?
    public var audioChoices: [Choice]
    /// The chosen audio's id.
    public var audio: String?
    public var subtitleChoices: [Choice]
    /// The chosen subtitles' id; nil when off.
    public var subtitle: String?
    /// While a seek or track change starts a new session: "Moving to 1:02:03…".
    public var loading: String?
    /// A failure's details were saved, so the remote offers Show Log.
    public var canShowLog: Bool
    /// Explain how to choose the TV, until it has been done once (design audit, move 2).
    public var showsTVHelp: Bool
    /// Where the current session starts, in movie time: converted video runs from here to
    /// `converted`. nil or 0 when it starts at the beginning.
    public var convertedFrom: Double?

    public init(phase: Phase = .idle, title: String = "", detail: String = "", elapsed: Double = 0,
                duration: Double? = nil, converted: Double? = nil, volume: Double = 1, showsWelcome: Bool = false,
                notice: String? = nil, audioChoices: [Choice] = [], audio: String? = nil,
                subtitleChoices: [Choice] = [], subtitle: String? = nil, loading: String? = nil,
                canShowLog: Bool = false, showsTVHelp: Bool = true, convertedFrom: Double? = nil) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.elapsed = elapsed
        self.duration = duration
        self.converted = converted
        self.volume = volume
        self.showsWelcome = showsWelcome
        self.notice = notice
        self.audioChoices = audioChoices
        self.audio = audio
        self.subtitleChoices = subtitleChoices
        self.subtitle = subtitle
        self.loading = loading
        self.canShowLog = canShowLog
        self.showsTVHelp = showsTVHelp
        self.convertedFrom = convertedFrom
    }

    /// Play/pause, skip and seek only mean something once the TV is playing the video.
    public var canControlPlayback: Bool {
        phase == .playing || phase == .paused
    }

    /// Volume only reaches anything once the TV is playing.
    public var canAdjustVolume: Bool {
        canControlPlayback
    }

    /// How far along the track a seek can go, from 0 to 1: anywhere in a film of known length
    /// (past what's converted, a new session starts there), nowhere in one of unknown length.
    public var seekableFraction: Double {
        (duration ?? 0) > 0 ? 1 : 0
    }

    /// Audio and subtitles can be changed once the video is loaded.
    public var canChooseTracks: Bool {
        switch phase {
        case .choosingTV, .playing, .paused: true
        case .idle, .preparing, .failed: false
        }
    }

    /// The remote's menu and the menu bar's offer audio when there's more than one track, and
    /// subtitles when there are any.
    public var showsAudioChoices: Bool {
        canChooseTracks && audioChoices.count > 1
    }

    public var showsSubtitleChoices: Bool {
        canChooseTracks && !subtitleChoices.isEmpty
    }

    /// A seek or track change is starting a new session.
    public var isLoading: Bool {
        loading != nil && canChooseTracks
    }

    /// "Ready to play from here up to 0:40" while the conversion is behind the end, so the
    /// lighter part of the track explains itself. Empty once everything is converted or when
    /// unknown.
    public var convertedNote: String {
        let from = convertedFrom ?? 0
        guard let converted, let duration, converted < duration || from > 0 else { return "" }
        if from > 0 {
            return "Converted from \(TimeText.clock(from)) up to \(TimeText.clock(converted)); a jump elsewhere takes a moment"
        }
        return "Converted up to \(TimeText.clock(converted)); a jump further on takes a moment"
    }

    public var status: String {
        if let loading, isLoading {
            return loading
        }
        return switch phase {
        case .idle: ""
        case .preparing: "Getting your video ready…"
        case .choosingTV(let tvWentAway):
            tvWentAway ? "TV disconnected — choose it again to continue" : "Choose your TV to start"
        case .playing: "Playing on your TV"
        case .paused: "Paused"
        case .failed(let message): message
        }
    }

    public var playButtonLabel: String {
        phase == .playing ? "Pause" : "Play"
    }

    /// Where `time` sits along `duration`, from 0 to 1.
    public static func fraction(of time: Double, in duration: Double?) -> Double {
        guard let duration, duration > 0, time.isFinite else { return 0 }
        return min(max(time / duration, 0), 1)
    }
}

public enum TimeText {
    /// "0:07", "12:34", "1:02:03".
    public static func clock(_ seconds: Double) -> String {
        let (hours, minutes, secs) = parts(seconds)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "−47:26": the time left, with a true minus sign.
    public static func remaining(elapsed: Double, duration: Double) -> String {
        "−" + clock(max(duration - elapsed, 0))
    }

    /// "1 hour 2 minutes 3 seconds", for VoiceOver.
    public static func spoken(_ seconds: Double) -> String {
        let (hours, minutes, secs) = parts(seconds)
        let words = [(hours, "hour"), (minutes, "minute"), (secs, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return words.isEmpty ? "0 seconds" : words.joined(separator: " ")
    }

    /// Whole hours, minutes and seconds; 0 for negative or non-finite times.
    private static func parts(_ seconds: Double) -> (hours: Int, minutes: Int, seconds: Int) {
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        return (total / 3600, total / 60 % 60, total % 60)
    }
}

public enum MediaSummary {
    /// "4K · HDR10 · 1 h 52 min": the video's size, its HDR format if any, and its length.
    public static func text(height: Int?, hdr: String?, duration: Double?) -> String {
        var parts: [String] = []
        if let height, height > 0 {
            switch height {
            case 2160...: parts.append("4K")
            default: parts.append("\(height)p")
            }
        }
        if let hdr {
            parts.append(hdr)
        }
        if let duration, duration.isFinite, duration > 0 {
            let total = Int(duration.rounded())
            let (hours, minutes) = (total / 3600, total / 60 % 60)
            parts.append(hours > 0 ? "\(hours) h \(minutes) min" : minutes > 0 ? "\(minutes) min" : "\(total) s")
        }
        return parts.joined(separator: " · ")
    }
}
