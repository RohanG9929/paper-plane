import AVFoundation
import Foundation
import Testing
@testable import PaperPlaneCore

/// End to end: probe → plan → ffmpeg → HLS served over HTTP → Apple's player says it's playable.
@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct PipelineTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var file: String
        var profile = OutputProfile(surround: true, hdr: true)
        var video: VideoCodecName
        var audio: AudioCodecName?
        var channels: Int?
        var hdr: HDRFormat?
        var testDescription: String { file }
    }

    static let cases: [Case] = [
        Case(file: "h264_aac.mp4", video: .h264, audio: .aac, channels: 2),
        Case(file: "h264_ac3_51.mkv", video: .h264, audio: .ac3, channels: 6),
        Case(file: "hevc_eac3_51.mkv", video: .hevc, audio: .eac3, channels: 6),
        Case(file: "hevc_hdr10_aac.mkv", video: .hevc, audio: .aac, channels: 2, hdr: .pq),
        Case(file: "vp9_opus.webm", video: .h264, audio: .aac, channels: 2),
        Case(file: "av1_flac_51.mkv", video: .h264, audio: .eac3, channels: 6),
        Case(file: "mpeg2_dts_51.mkv", video: .h264, audio: .eac3, channels: 6),
        Case(file: "h264_flac_71.mkv", video: .h264, audio: .eac3, channels: 6),
        Case(file: "h264_10bit_aac.mkv", video: .h264, audio: .aac, channels: 2),
        Case(file: "h264_noaudio.mkv", video: .h264, audio: nil),
        Case(file: "h264_coverart.mkv", video: .h264, audio: .aac, channels: 2),
        Case(file: "h264_multiaudio.mkv", video: .h264, audio: .ac3, channels: 6),
        Case(file: "Movie: Part 1 (Director's Cut) é.mp4", video: .h264, audio: .aac, channels: 2),
        Case(file: "h264_ac3_51.mkv", profile: OutputProfile(surround: false, hdr: true),
             video: .h264, audio: .aac, channels: 2),
    ]

    @Test(arguments: cases)
    func convertsToPlayableHLS(_ testCase: Case) async throws {
        let output = try await convert(testCase.file, profile: testCase.profile, start: 0)
        defer { try? FileManager.default.removeItem(at: output.work) }

        #expect(abs(output.duration - 10) < 1.5)
        #expect(output.converted.video.first?.codec == testCase.video)
        #expect(output.converted.audio.first?.codec == testCase.audio)
        #expect(output.converted.audio.first?.channels == testCase.channels)
        #expect(output.converted.video.first?.hdr == testCase.hdr)
        if testCase.file == "h264_10bit_aac.mkv" {
            #expect(output.converted.video.first?.pixelFormat == "yuv420p")
        }
    }

    @Test func startsPartWayThrough() async throws {
        let output = try await convert("h264_aac.mp4", profile: .default, start: 4)
        defer { try? FileManager.default.removeItem(at: output.work) }
        #expect(abs(output.duration - 6) < 1.5)
    }

    @Test(.enabled(if: TestSupport.ffmpegHasFilter("zscale"), "Needs an ffmpeg built with zimg (zscale)"))
    func toneMapsHDRForAnSDRTV() async throws {
        let output = try await convert("hevc_hdr10_aac.mkv", profile: OutputProfile(surround: true, hdr: false), start: 0)
        defer { try? FileManager.default.removeItem(at: output.work) }
        #expect(output.converted.video.first?.codec == .h264)
        #expect(output.converted.video.first?.hdr == nil)
    }

    @Test func audioOnlyFileIsRejectedBeforeConverting() async throws {
        let media = try await MediaProbe(tools: TestSupport.tools!).probe(.file(TestSupport.media("audio_only.m4a")))
        #expect(throws: PlanError.noVideoTrack) {
            try ConversionPlanner.plan(media)
        }
    }

    // MARK: - Helpers

    struct Output {
        var work: URL
        var duration: Double
        var converted: MediaInfo
    }

    private func convert(_ file: String, profile: OutputProfile, start: Double) async throws -> Output {
        let tools = try #require(TestSupport.tools)
        let work = try TestSupport.makeTemporaryDirectory()
        let session = work.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let input = ResolvedInput.file(TestSupport.media(file))
        let media = try await MediaProbe(tools: tools).probe(input)
        let plan = try ConversionPlanner.plan(media, profile: profile)
        let result = try await ProcessRunner.run(
            tools.ffmpeg, arguments: plan.ffmpegArguments(input: input, start: start, output: session))
        try #require(result.status == 0, "ffmpeg failed: \(String(decoding: result.stderr, as: UTF8.self))")

        let playlist = try String(contentsOf: session.appendingPathComponent("index.m3u8"), encoding: .utf8)
        #expect(playlist.contains("#EXT-X-ENDLIST"))

        let server = try await HLSServer(directory: work)
        defer { server.stop() }
        let url = server.url("session/index.m3u8")
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        let duration = try await asset.load(.duration).seconds
        let converted = try await MediaProbe(tools: tools).probe(ResolvedInput(inputs: [.init(url: url)], title: file))
        return Output(work: work, duration: duration, converted: converted)
    }
}

/// Runs scripts/serve-hls.py on a random local port for the duration of a test.
final class HLSServer {
    private let process = Process()
    let port: Int

    init(directory: URL) async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", TestSupport.repoRoot.appendingPathComponent("scripts/serve-hls.py").path,
                             directory.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()

        var found: Int?
        for try await line in stdout.fileHandleForReading.bytes.lines {
            if line.hasPrefix("PORT "), let port = Int(line.dropFirst(5)) {
                found = port
                break
            }
        }
        port = try #require(found, "serve-hls.py didn't report a port")
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    /// Doesn't wait for the exit: waitUntilExit() deadlocks if this runs on the main thread.
    func stop() {
        process.terminate()
    }
}
