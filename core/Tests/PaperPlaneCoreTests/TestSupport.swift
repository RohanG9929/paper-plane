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

    /// Whether the ffmpeg under test has a filter, e.g. `zscale` (needed for HDR → SDR tone mapping).
    static func ffmpegHasFilter(_ name: String) async -> Bool {
        guard let tools,
              let result = try? await ProcessRunner.run(tools.ffmpeg, arguments: ["-hide_banner", "-filters"])
        else { return false }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").contains { line in
            line.split(separator: " ").dropFirst().first == Substring(name)
        }
    }
}
