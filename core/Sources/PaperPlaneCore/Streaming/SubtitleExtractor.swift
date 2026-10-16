import Foundation

/// Converts a playback's text subtitles to WebVTT once, on the movie's timeline. Each session
/// then serves a copy moved to its own start (`WebVTT.shifted`).
public struct SubtitleExtractor: Sendable {
    public var tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    /// Writes `<n>.vtt` into `folder` for each text option (`n` is its position in `options`)
    /// and returns the files by option id. A track that can't be converted is left out.
    /// Cancelling stops ffmpeg.
    public func extract(_ options: [SubtitleOption], from input: ResolvedInput,
                        into folder: URL) async -> [String: URL] {
        var files: [String: URL] = [:]
        let numbered = options.enumerated().filter { $0.element.isText }
        let embedded = numbered.compactMap { item -> (Int, TrackRef)? in
            if case .embedded(let ref) = item.element.source { (item.offset, ref) } else { nil }
        }
        if !embedded.isEmpty {
            // One pass over the file for all tracks; if a track breaks it, one pass each.
            let all = await convert(embedded, from: input, into: folder)
            let made = all ? embedded : await embedded.asyncFilter { await convert([$0], from: input, into: folder) }
            for (number, _) in made {
                files[options[number].id] = Self.file(number, in: folder)
            }
        }
        for (number, option) in numbered {
            guard case .sidecar(let url) = option.source, !Task.isCancelled else { continue }
            if await convertSidecar(url, to: Self.file(number, in: folder)) {
                files[option.id] = Self.file(number, in: folder)
            }
        }
        return files
    }

    static func file(_ number: Int, in folder: URL) -> URL {
        folder.appendingPathComponent("\(number).vtt")
    }

    /// One ffmpeg run writing each track to its own WebVTT file. True if every file was made.
    private func convert(_ tracks: [(Int, TrackRef)], from input: ResolvedInput, into folder: URL) async -> Bool {
        var arguments = ffmpegQuietArguments + ["-y"]
        for item in input.inputs {
            arguments += item.ffmpegInputArguments(seek: 0)
        }
        for (number, ref) in tracks {
            arguments += ["-map", ref.mapSpecifier, "-c:s", "webvtt", "-f", "webvtt", Self.file(number, in: folder).path]
        }
        guard let result = try? await ProcessRunner.run(tools.ffmpeg, arguments: arguments), result.status == 0
        else { return false }
        return tracks.allSatisfy { FileManager.default.fileExists(atPath: Self.file($0.0, in: folder).path) }
    }

    /// A sidecar `.srt`, whatever its text encoding, to WebVTT.
    private func convertSidecar(_ url: URL, to output: URL) async -> Bool {
        guard let data = try? Data(contentsOf: url), let text = Self.decode(data) else { return false }
        // ffmpeg reads subtitles as UTF-8, so hand it a UTF-8 copy.
        let utf8 = output.deletingPathExtension().appendingPathExtension("srt")
        defer { try? FileManager.default.removeItem(at: utf8) }
        guard (try? Data(text.utf8).write(to: utf8)) != nil else { return false }
        let arguments = ffmpegQuietArguments + ["-y", "-i", utf8.path, "-c:s", "webvtt", "-f", "webvtt", output.path]
        guard let result = try? await ProcessRunner.run(tools.ffmpeg, arguments: arguments) else { return false }
        return result.status == 0
    }

    /// Subtitle files come in UTF-8 (with or without a byte order mark), UTF-16 with one, or,
    /// from older tools, Windows Latin-1.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .windowsCP1252)
    }
}

extension Sequence {
    func asyncFilter(_ isIncluded: (Element) async -> Bool) async -> [Element] {
        var kept: [Element] = []
        for element in self where await isIncluded(element) {
            kept.append(element)
        }
        return kept
    }
}
