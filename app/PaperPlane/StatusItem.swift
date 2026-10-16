import AppKit
import Observation
import PaperPlaneCore
import PaperPlaneUI

/// The menu bar icon (spec §1). A click opens and closes the panel; a right-click or
/// Control-click shows its menu, built fresh each time. Videos dropped on it play too (spec §4,
/// step 1). The icon fills in while something is open, and looks pressed while the panel is.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let controller: PlaybackController
    private let perform: @MainActor (StatusMenu.Item.Command) -> Void
    private let open: @MainActor ([URL]) -> Void
    private let togglePanel: @MainActor () -> Void
    private let closePanel: @MainActor () -> Void

    init(controller: PlaybackController, perform: @escaping @MainActor (StatusMenu.Item.Command) -> Void,
         open: @escaping @MainActor ([URL]) -> Void, togglePanel: @escaping @MainActor () -> Void,
         closePanel: @escaping @MainActor () -> Void) {
        self.controller = controller
        self.perform = perform
        self.open = open
        self.togglePanel = togglePanel
        self.closePanel = closePanel
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    /// What the panel hangs from.
    var button: NSStatusBarButton? { item.button }

    func setPanelOpen(_ isOpen: Bool) {
        item.button?.highlight(isOpen)
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        switch MenuBarClick.action(rightButton: event?.type == .rightMouseUp,
                                   control: event?.modifierFlags.contains(.control) ?? false) {
        case .togglePanel:
            togglePanel()
        case .showMenu:
            closePanel()
            // Attached only while it's open, so a plain click stays free for the panel.
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
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
