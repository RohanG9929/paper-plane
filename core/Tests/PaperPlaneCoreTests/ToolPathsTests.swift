import Foundation
import Testing
@testable import PaperPlaneCore

struct ToolPathsTests {
    @Test func prefersEnvironmentOverrides() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try makeExecutable(named: "my-ffmpeg", in: directory)
        let ffprobe = try makeExecutable(named: "my-ffprobe", in: directory)

        let tools = ToolPaths.locate(
            environment: ["PAPERPLANE_FFMPEG": ffmpeg.path, "PAPERPLANE_FFPROBE": ffprobe.path],
            fallbackDirectories: [])

        #expect(tools?.ffmpeg.path == ffmpeg.path)
        #expect(tools?.ffprobe.path == ffprobe.path)
    }

    @Test func searchesPathDirectoriesInOrder() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try makeExecutable(named: "ffmpeg", in: directory)
        let ffprobe = try makeExecutable(named: "ffprobe", in: directory)

        let tools = ToolPaths.locate(environment: ["PATH": "/nonexistent:\(directory.path)"], fallbackDirectories: [])

        #expect(tools?.ffmpeg.path == ffmpeg.path)
        #expect(tools?.ffprobe.path == ffprobe.path)
    }

    @Test func returnsNilWhenEitherToolIsMissing() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try makeExecutable(named: "ffmpeg", in: directory)

        #expect(ToolPaths.locate(environment: ["PATH": directory.path], fallbackDirectories: []) == nil)
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
