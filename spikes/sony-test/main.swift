// Throwaway Milestone 0 spike: play test HLS streams from this Mac on an AirPlay TV and
// show what the player reports. Not shipped; see docs/sony-test-results.md.
//
// Usage: build/SonyTest.app/Contents/MacOS/SonyTest http://<mac-lan-ip>:8642

import AppKit
import AVFoundation
import AVKit

let streams: [(name: String, path: String)] = [
    ("1 Baseline H.264 + AAC", "baseline/index.m3u8"),
    ("2 HEVC + AAC", "hevc/index.m3u8"),
    ("3 H.264 + AC3 5.1", "ac3/index.m3u8"),
    ("4 H.264 + E-AC3 5.1", "eac3/index.m3u8"),
    ("3b H.264 + AC3 5.1 (MPEG-TS)", "ac3ts/index.m3u8"),
    ("4b H.264 + E-AC3 5.1 (MPEG-TS)", "eac3ts/index.m3u8"),
    ("5 WebVTT subtitles", "webvtt/master.m3u8"),
    ("6 HDR10 HEVC (4K)", "hdr10/index.m3u8"),
    ("7 Live (growing EVENT playlist)", "live/index.m3u8"),
]

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    let baseURL: URL
    let player = AVPlayer()
    let streamPicker = NSPopUpButton()
    let status = NSTextField(wrappingLabelWithString: "")
    var window: NSWindow?
    var timer: Timer?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        player.allowsExternalPlayback = true
        let routePicker = AVRoutePickerView()
        routePicker.player = player  // On macOS this is what makes video (not just audio) AirPlay devices appear.

        streams.forEach { streamPicker.addItem(withTitle: $0.name) }
        let loadRow = NSStackView(views: [streamPicker, button("Load", #selector(load)), routePicker])
        let controlRow = NSStackView(views: [
            button("Play", #selector(play)), button("Pause", #selector(pause)),
            button("Seek to start", #selector(seekToStart)), button("−30 s", #selector(back30)),
            button("+30 s", #selector(forward30)), button("+5 min", #selector(forward5min)),
            button("Subtitles on/off", #selector(toggleSubtitles)),
        ])
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let stack = NSStackView(views: [loadRow, controlRow, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 240),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sony Test"
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    @objc func load() {
        let url = baseURL.appendingPathComponent(streams[streamPicker.indexOfSelectedItem].path)
        print("Loading \(url.absoluteString)")
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    @objc func play() { player.play() }
    @objc func pause() { player.pause() }
    @objc func back30() { skip(by: -30) }
    @objc func forward30() { skip(by: 30) }
    @objc func forward5min() { skip(by: 300) }

    @objc func seekToStart() {
        player.seek(to: .zero) { finished in print("Seek to start finished: \(finished)") }
    }

    private func skip(by seconds: Double) {
        let target = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: target) { finished in print("Skip \(seconds) s finished: \(finished)") }
    }

    @objc func toggleSubtitles() {
        guard let item = player.currentItem else { return }
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
                print("This stream has no subtitle tracks")
                return
            }
            let isOn = item.currentMediaSelection.selectedMediaOption(in: group) != nil
            let next = isOn ? nil : group.options.first
            item.select(next, in: group)
            print("Subtitles: \(next?.displayName ?? "off")")
        }
    }

    private func refresh() {
        let item = player.currentItem
        let duration = item?.duration.seconds ?? .nan
        let seekable = item?.seekableTimeRanges
            .map { String(format: "%.0f–%.0f s", $0.timeRangeValue.start.seconds, $0.timeRangeValue.end.seconds) }
            .joined(separator: ", ") ?? "–"
        status.stringValue = [
            String(format: "Time %.1f s    Duration %@", player.currentTime().seconds,
                   duration.isFinite ? String(format: "%.1f s", duration) : "indefinite (live)"),
            "Seekable: \(seekable)",
            "On TV (isExternalPlaybackActive): \(player.isExternalPlaybackActive ? "YES" : "no")",
            "Item: \(describe(item?.status))    Rate: \(player.rate)",
            "Error: \(item?.error?.localizedDescription ?? "none")",
        ].joined(separator: "\n")
    }

    private func describe(_ status: AVPlayerItem.Status?) -> String {
        switch status {
        case .readyToPlay: "ready"
        case .failed: "FAILED"
        case .unknown: "loading"
        case nil: "nothing loaded"
        @unknown default: "unknown"
        }
    }
}

guard CommandLine.arguments.count == 2, let baseURL = URL(string: CommandLine.arguments[1]) else {
    print("Usage: SonyTest http://<mac-lan-ip>:8642")
    exit(2)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller(baseURL: baseURL)  // app.delegate is weak; this keeps it alive
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
}
