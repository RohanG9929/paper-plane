import Foundation

/// The native messaging manifests that let Chrome and Brave start the helper (spec §5.2).
public enum BrowserHosts {
    public static let name = "dev.paperplane.host"
    /// The extension's ID, which Chrome derives from the public key in
    /// extension/static/manifest.json. Only this extension may start the helper.
    public static let extensionID = "napcmmglefncoieikecpjmdopmagllcg"
    /// Chrome's and Brave's folders in Application Support.
    static let browsers = ["Google/Chrome", "BraveSoftware/Brave-Browser"]

    public static var standardApplicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// The manifest for the helper at `host`.
    public static func manifest(host: URL) -> Data {
        let object: [String: Any] = [
            "name": name,
            "description": "Paper Plane",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        // Plain strings and arrays can't fail to serialize.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
    }

    /// Writes the manifest for each browser installed under `applicationSupport`, leaving files
    /// that already say the same alone, and returns the files written.
    @discardableResult
    public static func install(host: URL, applicationSupport: URL) throws -> [URL] {
        let manifest = manifest(host: host)
        var written: [URL] = []
        for browser in browsers {
            let folder = applicationSupport.appendingPathComponent(browser, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let hosts = folder.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            let file = hosts.appendingPathComponent("\(name).json")
            guard (try? Data(contentsOf: file)) != manifest else { continue }
            try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            try manifest.write(to: file, options: .atomic)
            written.append(file)
        }
        return written
    }
}
