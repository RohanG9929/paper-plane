import Foundation
import Testing
@testable import PaperPlaneCore

struct FailureLogTests {
    @Test func savesARedactedLog() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let error = TranscodeError.ffmpegFailed(
            status: 1, message: "\(NSHomeDirectory())/Movies/a.mkv: Invalid data\nCookie: secret=1\nhttps://x.test/v?token=abc")
        let file = try #require(FailureLog.save(message: "Paper Plane couldn't convert this video.", error: error,
                                                in: folder, date: Date(timeIntervalSince1970: 0)))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(file.lastPathComponent == "Paper Plane 1970-01-01T000000Z.log")
        #expect(text.contains("Shown: Paper Plane couldn't convert this video."))
        #expect(text.contains("ffmpeg stopped (status 1):\n~/Movies/a.mkv: Invalid data"))
        #expect(!text.contains("secret"))
        #expect(!text.contains("token=abc"))
        #expect(!text.contains(NSHomeDirectory()))
    }

    /// yt-dlp's last words go in the log for a bug report, redacted like ffmpeg's (Milestone 4,
    /// decision 13); the remote shows only its reason.
    @Test func ytDlpFailuresAreLoggedRedacted() throws {
        let stderr = "WARNING: [youtube] n challenge solving failed\nERROR: [youtube] x: Private video. See https://x.test/v?token=abc\n"
            + "\(NSHomeDirectory())/Library/Caches/Paper Plane/yt-dlp"
        let failure = YtDlpFailure.from(stderr: Data(stderr.utf8))
        #expect(failure == .failed(reason: "Private video."))
        let details = FailureLog.details(for: failure)
        #expect(details.hasPrefix("yt-dlp stopped: Private video.\n"))
        #expect(details.contains("WARNING: [youtube] n challenge solving failed"))
        #expect(!details.contains("token=abc"))
        #expect(!details.contains(NSHomeDirectory()))
    }

    @Test func twoFailuresInOneSecondKeepBothLogs() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 0)
        let first = try #require(FailureLog.save(message: "first", error: CancellationError(), in: folder, date: date))
        let second = try #require(FailureLog.save(message: "second", error: CancellationError(), in: folder, date: date))
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8).contains("Shown: first"))
        #expect(try String(contentsOf: second, encoding: .utf8).contains("Shown: second"))
    }

    @Test func keepsTheLastTen() throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for hour in 0..<12 {
            _ = FailureLog.save(message: "x", error: CancellationError(), in: folder,
                                date: Date(timeIntervalSince1970: Double(hour) * 3600))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names.count == 10)
        #expect(names.first == "Paper Plane 1970-01-01T020000Z.log")
    }

    @Test func aFolderThatCantBeMadeGivesNoLog() throws {
        let file = try TestSupport.makeTemporaryDirectory().appendingPathComponent("file")
        try Data().write(to: file)
        #expect(FailureLog.save(message: "x", error: CancellationError(), in: file.appendingPathComponent("logs")) == nil)
    }

    @Test func diskSpaceIsKnownEvenForAFolderNotMadeYet() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("not-yet-\(UUID())/sessions")
        #expect((DiskSpace.available(at: missing) ?? 0) > 0)
    }
}
