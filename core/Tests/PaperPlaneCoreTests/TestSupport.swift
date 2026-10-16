import Foundation
@testable import PaperPlaneCore

enum TestSupport {
    /// The repository root. This file lives at core/Tests/PaperPlaneCoreTests/TestSupport.swift.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let mediaDirectory = repoRoot.appendingPathComponent("testdata/media")

    static let tools = ToolPaths.locate()

    static func media(_ name: String) -> URL {
        mediaDirectory.appendingPathComponent(name)
    }

    /// True when ffmpeg is installed and scripts/make-test-media.sh has been run.
    static var hasMedia: Bool {
        tools != nil && FileManager.default.fileExists(atPath: media("h264_aac.mp4").path)
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperplane-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whether the installed ffmpeg has a filter, e.g. `zscale` (needed for HDR → SDR tone mapping).
    static func ffmpegHasFilter(_ name: String) -> Bool {
        filterList.split(separator: "\n").contains { line in
            line.split(separator: " ").dropFirst().first == Substring(name)
        }
    }

    private static let filterList: String = {
        guard let tools else { return "" }
        let process = Process()
        process.executableURL = tools.ffmpeg
        process.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }()
}
