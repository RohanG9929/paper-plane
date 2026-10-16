import AppKit
import PaperPlaneCore
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar icon's menu.
struct MenuContent: View {
    let app: AppDelegate
    let controller: PlaybackController

    var body: some View {
        Button("Open Video…") { chooseVideo() }
            .keyboardShortcut("o")
        Button("Show Remote") { app.showRemote() }
        if controller.isActive {
            Button("Stop") { controller.stop() }
        }
        Divider()
        Button("Quit Paper Plane") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func chooseVideo() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = VideoFiles.contentTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            app.open([url])
        }
    }
}
