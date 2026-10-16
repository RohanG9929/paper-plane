import AppKit
import SwiftUI
import Testing
@testable import PaperPlaneUI

/// Renders every state of the remote, light and dark, with SwiftUI's ImageRenderer: no window,
/// no screen recording. `scripts/render-ui.sh` writes them to docs/design/ for review; otherwise
/// they go to a temporary folder and the test checks that each one rendered.
@MainActor
struct RemoteSnapshotTests {
    static let states: [(String, RemoteState)] = {
        let movie = RemoteState(phase: .playing, title: "The Grand Budapest Hotel", detail: "1080p · 1 h 39 min",
                                elapsed: 1_234, duration: 5_940, converted: 2_100, volume: 0.7)
        var paused = movie
        paused.phase = .paused
        var preparing = movie
        preparing.phase = .preparing
        preparing.elapsed = 0
        preparing.converted = nil
        var choosing = movie
        choosing.phase = .choosingTV(tvWentAway: false)
        choosing.elapsed = 0
        choosing.converted = 12
        var lost = movie
        lost.phase = .choosingTV(tvWentAway: true)
        var hdr = movie
        hdr.title = "Planet Earth II — Islands (a very long title that has to wrap onto two lines)"
        hdr.detail = "4K · HDR10 · 58 min"
        var failed = movie
        failed.phase = .failed("Paper Plane couldn't read this file. It may be damaged or not a video.")
        var notice = movie
        notice.notice = "“Holiday photos.zip” isn't a video file."
        return [
            ("welcome", RemoteState(showsWelcome: true)),
            ("idle", RemoteState()),
            ("preparing", preparing),
            ("choosing-tv", choosing),
            ("playing", movie),
            ("paused", paused),
            ("tv-went-away", lost),
            ("long-title-hdr", hdr),
            ("failed", failed),
            ("notice", notice),
        ]
    }()

    @Test func rendersEveryStateInLightAndDark() throws {
        let folder = ProcessInfo.processInfo.environment["PAPERPLANE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("paperplane-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, state) in Self.states {
            for scheme in [ColorScheme.light, .dark] {
                let artwork = state.phase == .preparing || name == "failed" ? nil : Self.sampleArtwork
                let view = RemoteView(state: state, artwork: artwork, actions: RemoteActions()) {
                    // Stand-in for AVRoutePickerView, which ImageRenderer can't draw; the app sets
                    // the real one's colour to match (RoutePicker.swift).
                    Image(systemName: "airplayvideo").font(.system(size: 17)).foregroundStyle(.primary)
                }
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage, "\(name) didn't render")
                #expect(image.width == Int(RemoteView<Image>.width * 2), "\(name)")
                #expect(image.height > 200, "\(name)")
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("remote-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// A stand-in video frame: a sky, a sun and hills.
    static let sampleArtwork: Image = {
        let size = CGSize(width: 640, height: 360)
        let image = NSImage(size: size, flipped: false) { rect in
            let sky = NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.40, alpha: 1),
                                 ending: NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.62, alpha: 1))
            sky?.draw(in: rect, angle: 90)
            NSColor(calibratedRed: 1, green: 0.86, blue: 0.55, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 380, y: 150, width: 90, height: 90)).fill()
            for (index, color) in [(0, NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.40, alpha: 1)),
                                   (1, NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.28, alpha: 1))] {
                let hills = NSBezierPath()
                hills.move(to: .zero)
                hills.curve(to: NSPoint(x: 640, y: CGFloat(80 - index * 30)),
                            controlPoint1: NSPoint(x: 220, y: CGFloat(200 - index * 60)),
                            controlPoint2: NSPoint(x: 420, y: CGFloat(20 + index * 10)))
                hills.line(to: NSPoint(x: 640, y: 0))
                hills.close()
                color.setFill()
                hills.fill()
            }
            return true
        }
        return Image(nsImage: image)
    }()
}
