import Foundation
import Testing
@testable import PaperPlaneCore

struct MediaPlaylistTests {
    @Test func readsSegmentsOfAGrowingPlaylist() {
        let text = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:6
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:EVENT
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:6.006000,
            seg_00000.m4s
            #EXTINF:5.338667,
            seg_00001.m4s

            """
        #expect(MediaPlaylist(parsing: text) == MediaPlaylist(segments: [
            .init(uri: "seg_00000.m4s", duration: 6.006),
            .init(uri: "seg_00001.m4s", duration: 5.338667),
        ], isComplete: false))
    }

    @Test func endListMeansComplete() {
        let text = "#EXTM3U\r\n#EXTINF:4.0,\r\nseg_00000.m4s\r\n#EXT-X-ENDLIST\r\n"
        let playlist = MediaPlaylist(parsing: text)
        #expect(playlist.isComplete)
        #expect(playlist.segments == [.init(uri: "seg_00000.m4s", duration: 4)])
    }

    @Test func ignoresURIsWithoutDurations() {
        #expect(MediaPlaylist(parsing: "#EXTM3U\nstray.m4s\n").segments.isEmpty)
        #expect(MediaPlaylist(parsing: "").segments.isEmpty)
    }
}

struct InitSegmentTests {
    @Test func h264AndAAC() {
        let data = MP4.initSegment([
            MP4.visualEntry("avc1", width: 1920, height: 1080, config: MP4.box("avcC", [1, 0x64, 0x00, 0x28, 0xFF])),
            MP4.audioEntry("mp4a", config: MP4.esds(audioSpecificConfig: [0x12, 0x10])),
        ])
        #expect(InitSegment(data) == InitSegment(codecs: ["avc1.640028", "mp4a.40.2"], width: 1920, height: 1080))
    }

    @Test func hdr10HEVC() {
        // Main 10 (profile 2), main tier, level 5.0, progressive and frame-only.
        let hvcC = MP4.box("hvcC", [1, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 150] + [UInt8](repeating: 0, count: 10))
        let data = MP4.initSegment([MP4.visualEntry("hvc1", width: 3840, height: 2160, config: hvcC)])
        #expect(InitSegment(data).codecs == ["hvc1.2.4.L150.90"])
    }

    @Test func highTierHEVCKeepsEveryConstraintByteUpToTheLastNonZero() {
        let hvcC = MP4.box("hvcC", [1, 0x21, 0x60, 0, 0, 0, 0xB0, 0, 0x01, 0, 0, 0, 153])
        let data = MP4.initSegment([MP4.visualEntry("hvc1", width: 1920, height: 1080, config: hvcC)])
        #expect(InitSegment(data).codecs == ["hvc1.1.6.H153.B0.0.1"])
    }

    @Test func dolbyAudioAndHEAAC() {
        let data = MP4.initSegment([
            MP4.visualEntry("avc1", width: 1280, height: 720, config: MP4.box("avcC", [1, 0x4D, 0x40, 0x1F])),
            MP4.audioEntry("ec-3"),
            MP4.audioEntry("ac-3"),
            MP4.audioEntry("mp4a", config: MP4.esds(audioSpecificConfig: [0x2B, 0x92, 0x08, 0x00])),
        ])
        #expect(InitSegment(data).codecs == ["avc1.4d401f", "ec-3", "ac-3", "mp4a.40.5"])
    }

    @Test func unknownCodecDropsTheWholeList() {
        let data = MP4.initSegment([
            MP4.visualEntry("avc1", width: 1280, height: 720, config: MP4.box("avcC", [1, 0x64, 0x00, 0x1F])),
            MP4.audioEntry("Opus"),
        ])
        #expect(InitSegment(data) == InitSegment(codecs: nil, width: 1280, height: 720))
    }

    @Test func garbageHasNothing() {
        #expect(InitSegment(Data("not an mp4 file at all".utf8)) == InitSegment(codecs: nil, width: nil, height: nil))
        #expect(InitSegment(Data()) == InitSegment(codecs: nil, width: nil, height: nil))
        // A box claiming to be bigger than the file.
        #expect(InitSegment(Data([0xFF, 0xFF, 0xFF, 0xFF] + Array("moov".utf8))).codecs == nil)
    }
}

struct MasterPlaylistTests {
    @Test func describesTheStreamAndStartsAtTheBeginning() {
        let text = MasterPlaylist.text(
            bandwidth: 25_000_000,
            initSegment: InitSegment(codecs: ["hvc1.2.4.L150.90", "mp4a.40.2"], width: 3840, height: 2160),
            frameRate: 24000.0 / 1001,
            videoRange: .pq)
        #expect(text == """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-START:TIME-OFFSET=0
            #EXT-X-STREAM-INF:BANDWIDTH=25000000,CODECS="hvc1.2.4.L150.90,mp4a.40.2",RESOLUTION=3840x2160,FRAME-RATE=23.976,VIDEO-RANGE=PQ
            index.m3u8

            """)
    }

    @Test func leavesOutWhatIsUnknown() {
        let text = MasterPlaylist.text(bandwidth: 800_000, initSegment: InitSegment(codecs: nil, width: nil, height: nil),
                                       frameRate: nil, videoRange: .sdr)
        #expect(text.contains("#EXT-X-STREAM-INF:BANDWIDTH=800000,VIDEO-RANGE=SDR\nindex.m3u8\n"))
    }

    @Test func bandwidthIsThePeakSegmentRateWithHeadroom() {
        // 6 s of 3 MB is 4 Mb/s; 2 s of 2 MB is 8 Mb/s, the peak.
        #expect(MasterPlaylist.bandwidth(segmentSizes: [(3_000_000, 6), (2_000_000, 2)]) == 8_800_000)
        #expect(MasterPlaylist.bandwidth(segmentSizes: []) == 100_000)
        #expect(MasterPlaylist.bandwidth(segmentSizes: [(500, 0)]) == 100_000)
    }
}

/// Builds just enough of an fMP4 init segment to exercise InitSegment.
enum MP4 {
    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        be32(8 + payload.count) + Array(type.utf8) + payload
    }

    static func initSegment(_ sampleEntries: [[UInt8]]) -> Data {
        let tracks = sampleEntries.flatMap { entry in
            let stsd = box("stsd", [0, 0, 0, 0] + be32(1) + entry)
            return box("trak", box("mdia", box("minf", box("stbl", stsd))))
        }
        return Data(box("ftyp", Array("iso5".utf8) + [0, 0, 2, 0]) + box("moov", tracks))
    }

    static func visualEntry(_ type: String, width: Int, height: Int, config: [UInt8]) -> [UInt8] {
        box(type, [UInt8](repeating: 0, count: 24) + be16(width) + be16(height) + [UInt8](repeating: 0, count: 50) + config)
    }

    static func audioEntry(_ type: String, config: [UInt8] = []) -> [UInt8] {
        box(type, [UInt8](repeating: 0, count: 28) + config)
    }

    /// An esds box for AAC (object type 0x40) with the given AudioSpecificConfig.
    static func esds(audioSpecificConfig: [UInt8]) -> [UInt8] {
        let specific = [0x05, UInt8(audioSpecificConfig.count)] + audioSpecificConfig
        let decoderConfig = [0x04, UInt8(13 + specific.count), 0x40, 0x15] + [UInt8](repeating: 0, count: 11) + specific
        let elementary = [0x03, UInt8(3 + decoderConfig.count), 0x00, 0x01, 0x00] + decoderConfig
        return box("esds", [0, 0, 0, 0] + elementary)
    }

    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    static func be32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (24 - 8 * $0) & 0xFF) } }
}
