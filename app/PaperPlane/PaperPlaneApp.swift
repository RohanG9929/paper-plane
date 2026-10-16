import AppKit
import PaperPlaneCore
import SwiftUI

@main
struct PaperPlaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Paper Plane", systemImage: "paperplane") {
            MenuContent(app: appDelegate, controller: appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = PlaybackController()
    private lazy var remote = RemoteWindow(controller: controller, open: { [weak self] urls in self?.open(urls) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Whatever a crash left behind (spec §4.2).
        try? SessionFolders.standard.removeAll()
        remote.show()
    }

    /// Finder's Open With, and files dropped on the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ffmpeg must not outlive the app.
        Task {
            await controller.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Plays the first video among `urls`. The remote opens each time, because the TV has to be
    /// picked again for every playback (docs/sony-test-results.md, row 9).
    func open(_ urls: [URL]) {
        remote.show()
        controller.play(urls)
    }

    func showRemote() {
        remote.show()
    }
}
