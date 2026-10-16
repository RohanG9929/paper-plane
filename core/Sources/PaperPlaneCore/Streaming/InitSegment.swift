import Foundation

/// What the HLS master playlist needs from an fMP4 init segment (`init.mp4`): the RFC 6381
/// codec string of each track (`avc1.640028`, `hvc1.2.4.L150.90`, `mp4a.40.2`, `ac-3`, `ec-3`)
/// and the video's size.
struct InitSegment: Equatable, Sendable {
    /// nil when a track's codec isn't one Paper Plane writes. The master playlist then leaves
    /// CODECS out: a partial list would make players skip tracks.
    var codecs: [String]?
    var width: Int?
    var height: Int?

    init(codecs: [String]?, width: Int?, height: Int?) {
        self.codecs = codecs
        self.width = width
        self.height = height
    }

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var codecs: [String] = []
        var allKnown = true
        var width: Int?
        var height: Int?
        for entry in Self.sampleEntries(in: bytes) {
            var codec: String?
            switch entry.type {
            case "avc1", "avc3", "hvc1", "hev1":
                // VisualSampleEntry: 24 bytes of fields, width and height, then 50 more bytes.
                guard entry.payload.count >= 78 else { break }
                width = Self.uint16(bytes, entry.payload.lowerBound + 24)
                height = Self.uint16(bytes, entry.payload.lowerBound + 26)
                let children = Self.boxes(in: bytes, (entry.payload.lowerBound + 78)..<entry.payload.upperBound)
                if entry.type.hasPrefix("avc") {
                    codec = children.first { $0.type == "avcC" }.flatMap { Self.avcCodec(entry.type, bytes, $0.payload) }
                } else {
                    codec = children.first { $0.type == "hvcC" }.flatMap { Self.hevcCodec(entry.type, bytes, $0.payload) }
                }
            case "mp4a":
                // AudioSampleEntry: 28 bytes of fields before the child boxes.
                guard entry.payload.count >= 28 else { break }
                let children = Self.boxes(in: bytes, (entry.payload.lowerBound + 28)..<entry.payload.upperBound)
                codec = children.first { $0.type == "esds" }.flatMap { Self.aacCodec(bytes, $0.payload) }
            case "ac-3", "ec-3":
                codec = entry.type
            default:
                codec = nil
            }
            if let codec {
                codecs.append(codec)
            } else {
                allKnown = false
            }
        }
        self.init(codecs: allKnown && !codecs.isEmpty ? codecs : nil, width: width, height: height)
    }

    // MARK: - Boxes

    private struct Box {
        var type: String
        var payload: Range<Int>
    }

    /// The boxes directly inside `range`. Stops at the first malformed one.
    private static func boxes(in bytes: [UInt8], _ range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(uint32(bytes, offset))
            var header = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { break }
                size = Int(clamping: uint64(bytes, offset + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, size <= range.upperBound - offset else { break }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append(Box(type: type, payload: (offset + header)..<(offset + size)))
            offset += size
        }
        return result
    }

    /// moov → trak → mdia → minf → stbl → stsd → sample entries, for every track.
    private static func sampleEntries(in bytes: [UInt8]) -> [Box] {
        var level = boxes(in: bytes, 0..<bytes.count)
        for container in ["moov", "trak", "mdia", "minf", "stbl"] {
            level = level.filter { $0.type == container }.flatMap { boxes(in: bytes, $0.payload) }
        }
        return level.filter { $0.type == "stsd" }.flatMap { stsd in
            // stsd: version and flags (4 bytes), entry count (4 bytes), then the entries.
            stsd.payload.count >= 8 ? boxes(in: bytes, (stsd.payload.lowerBound + 8)..<stsd.payload.upperBound) : []
        }
    }

    // MARK: - Codec strings

    /// `avc1.PPCCLL`: profile, constraint flags and level from the avcC box.
    private static func avcCodec(_ type: String, _ bytes: [UInt8], _ avcC: Range<Int>) -> String? {
        guard avcC.count >= 4 else { return nil }
        let start = avcC.lowerBound
        return String(format: "%@.%02x%02x%02x", type, bytes[start + 1], bytes[start + 2], bytes[start + 3])
    }

    /// `hvc1.<space><profile>.<compatibility, bit-reversed>.<tier><level>[.<constraint bytes>]`
    /// from the hvcC box (ISO/IEC 14496-15 Annex E).
    private static func hevcCodec(_ type: String, _ bytes: [UInt8], _ hvcC: Range<Int>) -> String? {
        guard hvcC.count >= 13 else { return nil }
        let start = hvcC.lowerBound
        let space = ["", "A", "B", "C"][Int(bytes[start + 1] >> 6)]
        let tier = (bytes[start + 1] >> 5) & 1 == 1 ? "H" : "L"
        let profile = bytes[start + 1] & 0x1F
        let compatibility = uint32(bytes, start + 2)
        var reversed: UInt32 = 0
        for bit in 0..<32 where compatibility & (1 << bit) != 0 {
            reversed |= 1 << (31 - bit)
        }
        var constraints = Array(bytes[(start + 6)..<(start + 12)])
        while constraints.last == 0 {
            constraints.removeLast()
        }
        let level = bytes[start + 12]
        return "\(type).\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(level)"
            + constraints.map { "." + String($0, radix: 16, uppercase: true) }.joined()
    }

    /// `mp4a.40.<audio object type>` from the esds box's AudioSpecificConfig.
    private static func aacCodec(_ bytes: [UInt8], _ esds: Range<Int>) -> String? {
        var offset = esds.lowerBound + 4 // version and flags
        func descriptor(_ tag: UInt8) -> Range<Int>? {
            guard offset < esds.upperBound, bytes[offset] == tag else { return nil }
            offset += 1
            var length = 0
            for _ in 0..<4 {
                guard offset < esds.upperBound else { return nil }
                let byte = bytes[offset]
                offset += 1
                length = length << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            guard length <= esds.upperBound - offset else { return nil }
            return offset..<(offset + length)
        }
        guard let elementary = descriptor(0x03), elementary.count >= 3 else { return nil }
        let flags = bytes[elementary.lowerBound + 2]
        offset = elementary.lowerBound + 3
        if flags & 0x80 != 0 { offset += 2 } // stream dependence
        if flags & 0x40 != 0, offset < elementary.upperBound { offset += 1 + Int(bytes[offset]) } // URL
        if flags & 0x20 != 0 { offset += 2 } // OCR stream
        guard let config = descriptor(0x04), config.count >= 13 else { return nil }
        let objectType = bytes[config.lowerBound]
        offset = config.lowerBound + 13
        guard let specific = descriptor(0x05), specific.count >= 1 else {
            return String(format: "mp4a.%02x", objectType)
        }
        var audioObjectType = Int(bytes[specific.lowerBound] >> 3)
        if audioObjectType == 31, specific.count >= 2 {
            audioObjectType = 32 + Int((bytes[specific.lowerBound] & 0x07) << 3 | bytes[specific.lowerBound + 1] >> 5)
        }
        return String(format: "mp4a.%02x.%d", objectType, audioObjectType)
    }

    // MARK: - Integers

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    private static func uint64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }
}
