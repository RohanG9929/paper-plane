import Foundation
import UniformTypeIdentifiers

/// Which dropped or opened files Paper Plane tries to play.
public enum VideoFiles {
    /// Containers ffmpeg reads that macOS may not know as movies.
    static let knownExtensions: Set<String> = [
        "mkv", "webm", "avi", "wmv", "asf", "flv", "f4v", "ts", "m2ts", "mts", "vob", "ogv", "rmvb", "divx", "3gp",
    ]

    /// True for files whose type is a movie or video. Folders, audio, subtitles and images are
    /// left out.
    public static func isVideo(_ url: URL) -> Bool {
        url.isFileURL && !url.hasDirectoryPath && isVideo(extension: url.pathExtension)
    }

    /// True for a video file's extension, whatever case it's in.
    static func isVideo(extension pathExtension: String) -> Bool {
        let pathExtension = pathExtension.lowercased()
        if knownExtensions.contains(pathExtension) {
            return true
        }
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// What an open panel should offer: movies and videos, plus the containers above.
    public static var contentTypes: [UTType] {
        [.movie, .video] + knownExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    /// The video files among `urls`, in order.
    public static func videos(in urls: [URL]) -> [URL] {
        urls.filter(isVideo)
    }
}
