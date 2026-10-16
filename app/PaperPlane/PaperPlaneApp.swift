import AppKit
import PaperPlaneCore
import PaperPlaneUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct PaperPlaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: appDelegate, controller: appDelegate.controller)
        } label: {
            // Filled while something is open, so the menu bar shows Paper Plane is busy.
            Image(systemName: appDelegate.controller.isActive ? "paperplane.fill" : "paperplane")
                .accessibilityLabel("Paper Plane")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let welcomeKey = "didShowWelcome"
    let controller = PlaybackController(
        environment: .live(bundleURL: Bundle.main.bundleURL),
        showsWelcome: !UserDefaults.standard.bool(forKey: welcomeKey),
        welcomeSeen: { UserDefaults.standard.set(true, forKey: welcomeKey) })
    private lazy var remote = RemoteWindow(
        controller: controller,
        openVideo: { [weak self] in self?.chooseVideo() },
        open: { [weak self] urls in self?.open(urls) })

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

    func chooseVideo() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.message = "Choose a video to play on your TV"
        panel.prompt = "Open"
        panel.allowedContentTypes = VideoFiles.contentTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            open([url])
        }
    }
}
