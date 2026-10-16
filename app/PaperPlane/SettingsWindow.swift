import AppKit
import PaperPlaneUI
import SwiftUI

/// Settings (spec §4.1 overrides), in a small window of its own.
@MainActor
final class SettingsWindow {
    private let window: NSWindow

    init(store: SettingsStore) {
        window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
        window.title = "Paper Plane Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
