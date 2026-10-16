import Foundation

/// Saves what went wrong, for bug reports (spec §6): the plain message the user saw and the
/// converter's last output, redacted.
public enum FailureLog {
    /// `~/Library/Logs/Paper Plane/`.
    public static var standardFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Paper Plane", isDirectory: true)
    }

    /// How many logs to keep; older ones are deleted.
    static let kept = 10

    /// Writes a log and returns where, or nil if it couldn't be written.
    public static func save(message: String, error: any Error, in folder: URL = standardFolder,
                            date: Date = .now) -> URL? {
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).timeZone(separator: .omitted))
        // Two failures in one second get two logs.
        var file = folder.appendingPathComponent("Paper Plane \(stamp).log")
        var number = 1
        while FileManager.default.fileExists(atPath: file.path) {
            number += 1
            file = folder.appendingPathComponent("Paper Plane \(stamp) \(number).log")
        }
        let text = """
            Paper Plane failure log, \(date.formatted(.iso8601))
            Shown: \(message)

            \(details(for: error))

            """
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        removeOld(in: folder)
        return file
    }

    /// The tool's own words where there are any, with secrets and the home folder taken out.
    static func details(for error: any Error) -> String {
        let text = switch error {
        case TranscodeError.ffmpegFailed(let status, let message): "ffmpeg stopped (status \(status)):\n\(message)"
        case MediaProbeError.ffprobeFailed(let status, let message): "ffprobe stopped (status \(status)):\n\(message)"
        case YtDlpFailure.failed(let reason, let log): "yt-dlp stopped: \(reason ?? "no reason given")\n\(log)"
        default: String(describing: error)
        }
        return Redaction.redact(text).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func removeOld(in folder: URL) {
        let logs = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("Paper Plane ") && $0.hasSuffix(".log") }
            .sorted()
        for name in logs.dropLast(kept) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

/// Free space where the sessions live, for the converted-video window (spec §6).
public enum DiskSpace {
    /// Bytes available on the volume holding `url` (or its nearest existing parent). nil when
    /// the system can't say.
    public static func available(at url: URL) -> Int64? {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
