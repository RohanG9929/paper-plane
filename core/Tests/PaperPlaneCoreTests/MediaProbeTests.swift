import Foundation
import Testing
@testable import PaperPlaneCore

struct MediaProbeTests {
    @Test func emptyInputThrowsNoInputs() async {
        let unused = URL(fileURLWithPath: "/nonexistent")
        let probe = MediaProbe(tools: ToolPaths(ffmpeg: unused, ffprobe: unused))
        await #expect(throws: MediaProbeError.noInputs) {
            try await probe.probe(ResolvedInput(inputs: [], title: "nothing"))
        }
    }
}

@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct MediaProbeMediaTests {
    private func probe(_ name: String) async throws -> MediaInfo {
        try await MediaProbe(tools: TestSupport.tools!).probe(.file(TestSupport.media(name)))
    }

    @Test func probesMKVWithSurroundAndSubtitles() async throws {
        let info = try await probe("h264_ac3_51.mkv")
        #expect(info.video.map(\.codec) == [.h264])
        #expect(info.video.first?.width == 1280)
        #expect(info.video.first?.height == 720)
        #expect(info.audio.map(\.codec) == [.ac3])
        #expect(info.audio.first?.channels == 6)
        #expect(info.subtitles.map(\.kind) == [.text])
        let duration = try #require(info.duration)
        #expect(abs(duration - 10) < 0.5)
    }

    @Test func skipsEmbeddedCoverArt() async throws {
        let info = try await probe("h264_coverart.mkv")
        #expect(info.video.map(\.codec) == [.h264])
    }

    @Test func handlesAwkwardFileNames() async throws {
        let info = try await probe("Movie: Part 1 (Director's Cut) é.mp4")
        #expect(info.video.map(\.codec) == [.h264])
    }

    @Test func audioOnlyFileHasNoVideo() async throws {
        let info = try await probe("audio_only.m4a")
        #expect(info.video.isEmpty)
        #expect(info.audio.map(\.codec) == [.aac])
    }

    @Test func corruptFileThrowsFFprobeFailed() async throws {
        let error = await #expect(throws: MediaProbeError.self) {
            try await probe("corrupt.mkv")
        }
        guard case .ffprobeFailed(let status, _) = error else {
            Issue.record("Expected ffprobeFailed, got \(String(describing: error))")
            return
        }
        #expect(status != 0)
    }
}
