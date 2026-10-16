import Foundation
import os

/// Subtitle files next to a video: `Movie.srt` and `Movie.<language>.srt` for `Movie.mkv`
/// (spec §4, step 1).
public enum SidecarSubtitles {
    public struct File: Equatable, Sendable {
        public var url: URL
        /// From the name, e.g. `en` in `Movie.en.srt`. nil for `Movie.srt`.
        public var language: String?
        /// `Movie.en.forced.srt`.
        public var isForced: Bool
    }

    /// The `.srt` files beside `video`, sorted by name. Names are matched without regard to case.
    ///
    /// Listing a folder in Desktop, Documents or Downloads waits on the macOS privacy prompt
    /// until it's answered, so the folder is listed on another thread: if the calling task is
    /// cancelled meanwhile (the app quits, or a newer video replaces this one), this returns no
    /// files at once instead of waiting with it. `listing` stands in for the file system in tests.
    public static func find(for video: URL, listing: @escaping @Sendable (URL) -> [String] = Self.contents)
        async -> [File] {
        let folder = video.deletingLastPathComponent()
        let names = await abandonable { listing(folder) } ?? []
        return files(forVideoNamed: video.lastPathComponent, among: names)
            .map { File(url: folder.appendingPathComponent($0.name), language: $0.language, isForced: $0.isForced) }
    }

    @Sendable public static func contents(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    /// `work`'s result, or nil as soon as the calling task is cancelled, without waiting for
    /// `work`, which may be blocked in the kernel.
    static func abandonable<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.withLock { $0 = continuation }
                if Task.isCancelled { // cancelled before the handler had anything to resume
                    pending.withLock { $0.take() }?.resume(returning: nil)
                    return
                }
                DispatchQueue.global().async {
                    let result = work()
                    pending.withLock { $0.take() }?.resume(returning: result)
                }
            }
        } onCancel: {
            pending.withLock { $0.take() }?.resume(returning: nil)
        }
    }

    /// The matching names among `names`, for the video file `videoName` (e.g. `Movie.mkv`).
    static func files(forVideoNamed videoName: String,
                      among names: [String]) -> [(name: String, language: String?, isForced: Bool)] {
        let base = (videoName as NSString).deletingPathExtension
        let videoExtension = (videoName as NSString).pathExtension.lowercased()
        let prefix = base.lowercased() + "."
        return names.sorted().compactMap { name in
            let lower = name.lowercased()
            // "Movie.srt", and "Movie.mkv.srt" as some tools name it.
            if lower == prefix + "srt" || (!videoExtension.isEmpty && lower == prefix + videoExtension + ".srt") {
                return (name, nil, false)
            }
            // What's between "Movie." and ".srt": a language, "forced", or language.forced.
            guard lower.hasPrefix(prefix), lower.hasSuffix(".srt"), lower.count > prefix.count + 4 else { return nil }
            let middle = String(name.dropFirst(prefix.count).dropLast(4))
            var parts = middle.split(separator: ".").map(String.init)
            let isForced = parts.last?.lowercased() == "forced"
            if isForced {
                parts.removeLast()
            }
            switch parts.count {
            case 0:
                return (name, nil, true)
            case 1 where isLanguageTag(parts[0]):
                return (name, parts[0], isForced)
            default:
                return nil // e.g. "Movie.Extras.Part.srt" belongs to another video
            }
        }
    }

    /// `en`, `eng`, `pt-BR`, `zh-Hant`: 2–3 letters, optionally a dash and 2–4 letters or digits.
    static func isLanguageTag(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,4})?/) != nil
    }
}
