import AppKit
import Network
import PaperPlaneCore
import PaperPlaneUI
import UniformTypeIdentifiers

/// A menu bar app (`LSUIElement`) on AppKit's own lifecycle: a status item that takes drops, the
/// remote and Settings windows, and a main menu for their keyboard shortcuts.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private enum Key {
        static let welcomeShown = "didShowWelcome"
        static let tvChosen = "didChooseTV"
    }

    #if DEBUG
    private static let isDevelopmentBuild = true
    #else
    private static let isDevelopmentBuild = false
    #endif

    private let settings = SettingsStore()
    let controller = PlaybackController(
        environment: .live(bundleURL: Bundle.main.bundleURL, fallsBackToInstalledFFmpeg: isDevelopmentBuild,
                           settings: { SettingsStore.settings(from: .standard) }),
        showsWelcome: !UserDefaults.standard.bool(forKey: Key.welcomeShown),
        welcomeSeen: { UserDefaults.standard.set(true, forKey: Key.welcomeShown) },
        showsTVHelp: !UserDefaults.standard.bool(forKey: Key.tvChosen),
        tvChosen: { UserDefaults.standard.set(true, forKey: Key.tvChosen) })
    private lazy var remote = RemoteWindow(
        controller: controller,
        openVideo: { [weak self] in self?.chooseVideo() },
        open: { [weak self] urls in self?.open(urls) })
    private lazy var settingsWindow = SettingsWindow(store: settings)
    private var statusItem: StatusItem?
    private var nowPlaying: NowPlaying?
    private let network = NWPathMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Whatever a crash left behind (spec §4.2).
        try? SessionFolders.standard.removeAll()
        NSApp.mainMenu = mainMenu()
        statusItem = StatusItem(controller: controller,
                                perform: { [weak self] in self?.perform($0) },
                                open: { [weak self] in self?.open($0) })
        let nowPlaying = NowPlaying(controller: controller)
        nowPlaying.start()
        self.nowPlaying = nowPlaying
        // A new Wi-Fi network or address means the TV can't reach the old one (spec §6).
        network.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.controller.networkChanged() }
        }
        network.start(queue: .main)
        remote.show()
    }

    /// Finder's Open With, and files dropped on the app's icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ffmpeg must not outlive the app.
        network.cancel()
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

    private func perform(_ command: StatusMenu.Item.Command) {
        switch command {
        case .togglePlay: controller.togglePause()
        case .stop: controller.stop()
        case .openVideo: chooseVideo()
        case .showRemote: remote.show()
        case .settings: settingsWindow.show()
        case .quit: NSApp.terminate(nil)
        case .selectAudio(let id): controller.selectAudio(id)
        case .selectSubtitle(let id): controller.selectSubtitle(id)
        }
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

    // MARK: - Main menu

    /// Never shown (the app lives in the menu bar), but it's where ⌘O, ⌘, , ⌘W and ⌘Q come from
    /// while one of the app's windows is in front, and editing shortcuts for text fields.
    private func mainMenu() -> NSMenu {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu?.addItem($0) }
            return item
        }
        func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
        let main = NSMenu()
        main.addItem(menu("Paper Plane", [
            item("About Paper Plane", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(showSettings), ",", target: self),
            .separator(),
            item("Quit Paper Plane", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("File", [
            item("Open Video…", #selector(openVideo), "o", target: self),
            item("Show Remote", #selector(showRemote), "1", target: self),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(menu("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        return main
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func openVideo() {
        chooseVideo()
    }

    @objc private func showRemote() {
        remote.show()
    }
}
