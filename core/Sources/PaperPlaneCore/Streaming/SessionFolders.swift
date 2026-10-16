import Foundation

/// Where each playback's HLS files go: `~/Library/Caches/Paper Plane/sessions/<id>/` (spec §4).
public struct SessionFolders: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: SessionFolders {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return SessionFolders(root: caches.appendingPathComponent("Paper Plane/sessions", isDirectory: true))
    }

    /// A new, empty folder for one session.
    public func create() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Deletes every session folder. The app calls this at launch, so nothing a crash left
    /// behind piles up (spec §4.2).
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }
}
