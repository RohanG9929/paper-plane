import AppKit
import PaperPlaneUI
import SwiftUI

/// The menu bar icon's menu: what's playing first, then opening things, then quitting.
struct MenuContent: View {
    let app: AppDelegate
    let controller: PlaybackController

    var body: some View {
        if controller.isActive, let title = controller.title {
            Section(title) {
                Button(controller.remoteState.playButtonLabel) { controller.togglePause() }
                    .disabled(!controller.remoteState.canControlPlayback)
                Button("Stop") { controller.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            }
            Divider()
        }
        Button("Open Video…") { app.chooseVideo() }
            .keyboardShortcut("o")
        Button("Show Remote") { app.showRemote() }
            .keyboardShortcut("1")
        Divider()
        Button("Quit Paper Plane") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
