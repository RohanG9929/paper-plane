import Foundation

/// The text subtitles one session offers, and the one it burns in, as WebVTT files on the
/// movie's timeline (from `SubtitleExtractor`). The session writes its own copies, moved to
/// its start.
public struct SessionSubtitles: Sendable {
    public struct Track: Equatable, Sendable {
        /// Unique among the tracks: the player's options are matched to tracks by it.
        public var name: String
        /// As the file gives it (`eng`, `pt-BR`); the playlist gets the RFC 5646 tag.
        public var language: String?
        public var isForced: Bool
        public var file: URL

        public init(name: String, language: String?, isForced: Bool, file: URL) {
            self.name = name
            self.language = language
            self.isForced = isForced
            self.file = file
        }
    }

    public var tracks: [Track]
    /// With `BurnIn.text`: the subtitles to draw into the picture.
    public var burnIn: URL?
    /// The movie's length, which the subtitle playlists cover. nil when unknown.
    public var duration: Double?

    public init(tracks: [Track] = [], burnIn: URL? = nil, duration: Double? = nil) {
        self.tracks = tracks
        self.burnIn = burnIn
        self.duration = duration
    }

    /// Writes `sub_<n>.vtt` and `sub_<n>.m3u8` for each track and `burn-in.vtt`, all moved
    /// `offset` seconds earlier, into `folder`. Returns the renditions for the master playlist.
    /// A track whose file can't be read is left out.
    func write(into folder: URL, offset: Double) -> [MasterPlaylist.Subtitle] {
        if let burnIn {
            Self.writeShifted(burnIn, by: offset, to: folder.appendingPathComponent(HLSFileNames.burnInSubtitles))
        }
        // A day when the length is unknown: the playlist must say something.
        let length = max((duration ?? offset + 86_400) - offset, 1)
        return tracks.enumerated().compactMap { number, track in
            let vtt = "sub_\(number).vtt"
            let playlist = "sub_\(number).m3u8"
            guard Self.writeShifted(track.file, by: offset, to: folder.appendingPathComponent(vtt)),
                  (try? MasterPlaylist.subtitlePlaylist(file: vtt, duration: length)
                      .write(to: folder.appendingPathComponent(playlist), atomically: true, encoding: .utf8)) != nil
            else { return nil }
            return MasterPlaylist.Subtitle(name: track.name, language: TrackNames.languageTag(track.language),
                                           isForced: track.isForced, uri: playlist)
        }
    }

    @discardableResult
    private static func writeShifted(_ source: URL, by offset: Double, to destination: URL) -> Bool {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return false }
        return (try? WebVTT.shifted(text, by: offset).write(to: destination, atomically: true, encoding: .utf8)) != nil
    }
}
