import Foundation

enum Fraction {
    /// "30000/1001" → 29.97…, as ffprobe and ffmpeg write frame rates and time bases. nil
    /// unless it's two numbers with a nonzero denominator.
    static func value(_ text: some StringProtocol) -> Double? {
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]),
              denominator != 0
        else { return nil }
        return numerator / denominator
    }
}
