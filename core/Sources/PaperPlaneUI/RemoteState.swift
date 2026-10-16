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

    public var phase: Phase
    public var title: String
    /// Size, range and length, e.g. "4K · HDR10 · 1 h 52 min".
    public var detail: String
    /// Movie time, in seconds.
    public var elapsed: Double
    /// nil while unknown.
    public var duration: Double?
    /// How far the conversion has got, in movie time. Seeking works up to here.
    public var converted: Double?
    /// 0…1.
    public var volume: Double
    /// Shows the one-time explainer instead of the drop zone.
    public var showsWelcome: Bool

    public init(phase: Phase = .idle, title: String = "", detail: String = "", elapsed: Double = 0,
                duration: Double? = nil, converted: Double? = nil, volume: Double = 1, showsWelcome: Bool = false) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.elapsed = elapsed
        self.duration = duration
        self.converted = converted
        self.volume = volume
        self.showsWelcome = showsWelcome
    }

    /// Play/pause, skip and seek only mean something once the TV is playing the video.
    public var canControlPlayback: Bool {
        phase == .playing || phase == .paused
    }

    public var status: String {
        switch phase {
        case .idle: ""
        case .preparing: "Getting your video ready…"
        case .choosingTV(let tvWentAway):
            tvWentAway ? "Your TV disconnected. Choose it again to continue" : "Choose your TV to start"
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
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
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
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let parts = [(total / 3600, "hour"), (total / 60 % 60, "minute"), (total % 60, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
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
