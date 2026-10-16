import Foundation
import Testing
@testable import PaperPlaneCore

struct SubtitleDecodingTests {
    @Test func readsTheUsualEncodings() {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nCafé\n"
        #expect(SubtitleExtractor.decode(Data(text.utf8)) == text)
        #expect(SubtitleExtractor.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == text)
        #expect(SubtitleExtractor.decode(text.data(using: .utf16)!) == text) // with a byte order mark
        #expect(SubtitleExtractor.decode(text.data(using: .windowsCP1252)!) == text)
    }
}

@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct SubtitleExtractorTests {
    @Test func convertsEmbeddedAndSidecarSubtitlesToWebVTT() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // An old-style sidecar in Windows Latin-1, beside a link to the clip with an embedded SRT.
        let sidecar = folder.appendingPathComponent("Clip: Été.fr.srt")
        try "1\n00:00:02,000 --> 00:00:03,500\nÉté\n".data(using: .windowsCP1252)!.write(to: sidecar)
        let input = ResolvedInput.file(TestSupport.media("h264_ac3_51.mkv"))
        let options = [
            SubtitleOption(source: .embedded(TrackRef(index: 2)), language: nil, title: nil, isForced: false,
                           isText: true),
            SubtitleOption(source: .embedded(TrackRef(index: 9)), language: nil, title: nil, isForced: false,
                           isText: false), // a picture track is burned in, not converted
            SubtitleOption(source: .sidecar(sidecar), language: "fr", title: nil, isForced: false, isText: true),
        ]
        let output = folder.appendingPathComponent("vtt")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let files = await SubtitleExtractor(tools: try #require(TestSupport.tools))
            .extract(options, from: input, into: output)

        #expect(Set(files.keys) == ["track-0-2", "file-Clip: Été.fr.srt"])
        let embedded = try String(contentsOf: try #require(files["track-0-2"]), encoding: .utf8)
        #expect(embedded.hasPrefix("WEBVTT"))
        #expect(embedded.contains("00:01.000 --> 00:04.000\nPaper Plane test subtitle one"))
        let french = try String(contentsOf: try #require(files["file-Clip: Été.fr.srt"]), encoding: .utf8)
        #expect(french.contains("00:02.000 --> 00:03.500\nÉté"))
        // The UTF-8 copy made for ffmpeg is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["0.vtt", "2.vtt"])
    }

    @Test func aTrackThatCantBeConvertedDoesNotStopTheOthers() async throws {
        let output = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let input = ResolvedInput.file(TestSupport.media("h264_ac3_51.mkv"))
        let options = [
            SubtitleOption(source: .embedded(TrackRef(index: 1)), language: nil, title: nil, isForced: false,
                           isText: true), // really the audio track: ffmpeg can't make WebVTT of it
            SubtitleOption(source: .embedded(TrackRef(index: 2)), language: nil, title: nil, isForced: false,
                           isText: true),
            SubtitleOption(source: .sidecar(output.appendingPathComponent("missing.srt")), language: nil, title: nil,
                           isForced: false, isText: true),
        ]
        let files = await SubtitleExtractor(tools: try #require(TestSupport.tools))
            .extract(options, from: input, into: output)
        #expect(Array(files.keys) == ["track-0-2"])
    }
}
