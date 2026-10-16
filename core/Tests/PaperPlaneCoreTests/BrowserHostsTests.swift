import CryptoKit
import Foundation
import Testing
@testable import PaperPlaneCore

struct BrowserHostsTests {
    static let host = URL(fileURLWithPath: "/Applications/Paper Plane.app/Contents/Helpers/paperplane-host")

    /// Spec §5.2: Chrome and Brave, each only when it's installed.
    @Test func installsForEachBrowserThatIsThere() throws {
        let support = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)
        let written = try BrowserHosts.install(host: Self.host, applicationSupport: support)
        let chrome = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/dev.paperplane.host.json")
        #expect(written.map(\.path) == [chrome.path])
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("BraveSoftware").path))

        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: chrome)) as? [String: Any]
        #expect(manifest?["name"] as? String == "dev.paperplane.host")
        #expect(manifest?["type"] as? String == "stdio")
        #expect(manifest?["path"] as? String == Self.host.path)
        #expect(manifest?["allowed_origins"] as? [String] == ["chrome-extension://napcmmglefncoieikecpjmdopmagllcg/"])
    }

    @Test func rewritesOnlyWhatChanged() throws {
        let support = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("BraveSoftware/Brave-Browser"),
                                                withIntermediateDirectories: true)
        #expect(try BrowserHosts.install(host: Self.host, applicationSupport: support).count == 1)
        #expect(try BrowserHosts.install(host: Self.host, applicationSupport: support).isEmpty)
        let moved = URL(fileURLWithPath: "/Users/someone/Applications/Paper Plane.app/Contents/Helpers/paperplane-host")
        #expect(try BrowserHosts.install(host: moved, applicationSupport: support).count == 1)
    }

    /// The ID the manifests allow is the one Chrome derives from the extension's pinned key:
    /// the first 32 hex digits of the key's SHA-256, each mapped 0–f → a–p.
    @Test func allowsTheExtensionThatShipsWithIt() throws {
        let url = TestSupport.repoRoot.appendingPathComponent("extension/static/manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let encoded = try #require(manifest?["key"] as? String)
        let key = try #require(Data(base64Encoded: encoded))
        let hex = SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined()
        let id = String(hex.map { Character(UnicodeScalar(UInt8(Int(String($0), radix: 16)!) + 97)) })
        #expect(id == BrowserHosts.extensionID)
    }
}
