import Foundation
import ImageIO
import Testing
@testable import PaperPlaneCore

@Suite(.enabled(if: TestSupport.hasMedia, "Needs ffmpeg (brew install ffmpeg) and scripts/make-test-media.sh"))
struct ThumbnailTests {
    private func size(of jpeg: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    @Test func grabsAScaledFrame() async throws {
        let tools = try #require(TestSupport.tools)
        let jpeg = try #require(await Thumbnail.jpeg(tools: tools, input: .init(url: TestSupport.media("h264_aac.mp4")), at: 2))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        let (width, height) = try #require(size(of: jpeg))
        #expect(width == 640)
        #expect(height == 360)
    }

    @Test func worksForAwkwardNamesAndVideoNeedingConversion() async throws {
        let tools = try #require(TestSupport.tools)
        for name in ["Movie: Part 1 (Director's Cut) é.mp4", "vp9_opus.webm", "h264_coverart.mkv"] {
            let jpeg = await Thumbnail.jpeg(tools: tools, input: .init(url: TestSupport.media(name)), at: 1)
            #expect(jpeg.map { size(of: $0) != nil } == true, "\(name)")
        }
    }

    @Test func givesNothingForUnusableInput() async throws {
        let tools = try #require(TestSupport.tools)
        #expect(await Thumbnail.jpeg(tools: tools, input: .init(url: TestSupport.media("corrupt.mkv")), at: 1) == nil)
        #expect(await Thumbnail.jpeg(tools: tools, input: .init(url: TestSupport.media("audio_only.m4a")), at: 1) == nil)
        #expect(await Thumbnail.jpeg(tools: tools, input: .init(url: TestSupport.media("h264_aac.mp4")), at: 60) == nil)
    }

    @Test func pointsAtATenthOfTheVideo() {
        #expect(Thumbnail.moment(duration: 6_000) == 600)
        #expect(Thumbnail.moment(duration: 10) == 1)
        #expect(Thumbnail.moment(duration: nil) == 5)
    }
}
