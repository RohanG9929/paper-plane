import AppKit
import Observation
import PaperPlaneCore
import PaperPlaneUI

/// The menu bar icon (spec §1): its menu, built fresh each time it opens, and videos dropped on
/// it (spec §4, step 1). The icon fills in while something is open.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: PlaybackController
    private let perform: @MainActor (StatusMenu.Item.Command) -> Void
    private let open: @MainActor ([URL]) -> Void

    init(controller: PlaybackController, perform: @escaping @MainActor (StatusMenu.Item.Command) -> Void,
         open: @escaping @MainActor ([URL]) -> Void) {
        self.controller = controller
        self.perform = perform
        self.open = open
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        // The status bar window passes drags on to its delegate.
        item.button?.window?.registerForDraggedTypes([.fileURL, .URL]) // files, and links from a browser
        item.button?.window?.delegate = self
        followIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in StatusMenu.items(for: controller.remoteState) {
            menu.addItem(menuItem(for: entry))
        }
    }

    private func menuItem(for entry: StatusMenu.Item) -> NSMenuItem {
        if entry.isSeparator {
            return .separator()
        }
        let built = NSMenuItem(title: entry.title, action: nil, keyEquivalent: entry.key)
        built.isEnabled = entry.isEnabled
        built.state = entry.isChecked ? .on : .off
        if let command = entry.command {
            built.action = #selector(choose(_:))
            built.target = self
            built.representedObject = command
        }
        if let submenu = entry.submenu {
            let menu = NSMenu(title: entry.title)
            menu.autoenablesItems = false
            submenu.forEach { menu.addItem(menuItem(for: $0)) }
            built.submenu = menu
        }
        return built
    }

    @objc private func choose(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? StatusMenu.Item.Command {
            perform(command)
        }
    }

    // MARK: - Drops on the icon

    @objc func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.urls(in: sender).isEmpty ? [] : .copy
    }

    @objc func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.urls(in: sender)
        guard !urls.isEmpty else { return false }
        open(urls)
        return true
    }

    /// Files, and web links dragged from a browser's address bar.
    private static func urls(in info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return urls.filter { $0.isFileURL || Links.webLink(in: $0.absoluteString) != nil }
    }

    // MARK: - Icon

    private func followIcon() {
        observeContinuously { [weak self] in
            guard let self else { return }
            item.button?.image = NSImage(systemSymbolName: controller.isActive ? "paperplane.fill" : "paperplane",
                                         accessibilityDescription: "Paper Plane")
        }
    }
}
