import Foundation

/// Reading and moving WebVTT cues. Subtitles are converted once per playback, on the movie's
/// timeline; each session starts `offset` seconds into the movie, so its copy moves every cue
/// that much earlier.
enum WebVTT {
    /// `text` with every cue `offset` seconds earlier. Cues that end before the new start are
    /// dropped, and one that spans it starts at 0. The header, styles and notes are kept.
    static func shifted(_ text: String, by offset: Double) -> String {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let kept = blocks.compactMap { block -> String? in
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else {
                return block // WEBVTT header, STYLE, REGION or NOTE
            }
            let sides = lines[timing].components(separatedBy: "-->")
            let endAndSettings = sides[1].trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard sides.count == 2, let start = seconds(sides[0].trimmingCharacters(in: .whitespaces)),
                  let endText = endAndSettings.first, let end = seconds(String(endText))
            else { return nil } // a malformed cue
            guard end - offset > 0 else { return nil }
            let settings = endAndSettings.count > 1 ? " " + endAndSettings[1] : ""
            // timestamp() starts a cue that spans the session's start at 0.
            lines[timing] = "\(timestamp(start - offset)) --> \(timestamp(end - offset))\(settings)"
            return lines.joined(separator: "\n")
        }
        return kept.joined(separator: "\n\n") + "\n"
    }

    /// "01:02:03.456" or "02:03.456" → seconds.
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count), let last = Double(parts[parts.count - 1]) else { return nil }
        var total = last
        var multiplier = 60.0
        for part in parts.dropLast().reversed() {
            guard let value = Int(part) else { return nil }
            total += Double(value) * multiplier
            multiplier *= 60
        }
        return total
    }

    /// Seconds → "01:02:03.456".
    static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                      milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
