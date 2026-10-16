import AppKit
import os
import PaperPlaneCore
import PaperPlaneUI
import SwiftUI

/// The remote (spec §1), in a panel that hangs from the menu bar icon with a pointer. Clicking the
/// icon opens and closes it. It stays open while a video is dragged in from Finder, so nothing has
/// to be dropped near the menu bar, where Mission Control and notch apps take drags. Esc closes it.
/// The views themselves live in PaperPlaneUI.
@MainActor
final class MenuBarPanel: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let anchor: @MainActor () -> NSView?
    /// Told when the panel opens or closes, so the icon looks pressed while it's open.
    var visibilityChanged: (@MainActor (Bool) -> Void)?

    init(controller: PlaybackController, anchor: @escaping @MainActor () -> NSView?,
         openVideo: @escaping @MainActor @Sendable () -> Void,
         playCopiedLink: @escaping @MainActor @Sendable () -> Void,
         open: @escaping @MainActor @Sendable ([URL]) -> Void) {
        self.anchor = anchor
        super.init()
        let content = PanelContentController(rootView: RemoteContent(
            controller: controller, openVideo: openVideo, playCopiedLink: playCopiedLink, open: open))
        content.sizingOptions = .preferredContentSize // the panel follows the remote's height
        content.paste = playCopiedLink
        content.close = { [weak self] in self?.close() }
        popover.contentViewController = content
        // Not .transient, which closes the panel the moment you click Finder to drag a video in.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }
    /// The panel's own window, while it's open.
    var window: NSWindow? { popover.isShown ? popover.contentViewController?.view.window : nil }

    func show() {
        NSApp.activate()
        if !popover.isShown {
            let anchor = visibleAnchor()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        window?.makeKey()
    }

    func toggle() {
        popover.isShown ? close() : show()
    }

    func close() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        log.info("Panel open: app active \(NSApp.isActive, privacy: .public), panel key \(self.window?.isKeyWindow ?? false, privacy: .public)")
        watchForEsc()
        visibilityChanged?(true)
    }

    func popoverDidClose(_ notification: Notification) {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        fallbackAnchor?.orderOut(nil)
        visibilityChanged?(false)
    }

    // MARK: - Esc

    private let log = Logger(subsystem: "dev.paperplane.app", category: "panel")
    private var escMonitor: Any?

    /// Esc closes the panel. Watched for here rather than in the remote's responder chain: in a
    /// popover the first responder is usually the popover's own window, so Esc never reaches the
    /// content. Only while the panel has the keyboard, so Esc in Settings is left alone.
    private func watchForEsc() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let closes = event.keyCode == 53 // Esc
                && MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, event.window === window else { return false }
                    self.log.info("Esc: closing the panel")
                    self.close()
                    return true
                }
            return closes ? nil : event
        }
    }

    // MARK: - Where the panel hangs

    private var fallbackAnchor: NSWindow?

    /// The menu bar icon, or, when it can't be seen (hidden behind the notch, or by an app that
    /// tidies the menu bar), an invisible spot at the top right of the screen.
    private func visibleAnchor() -> NSView {
        if let icon = anchor(), let window = icon.window, window.isVisible,
           NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            return icon
        }
        let window = fallbackAnchor ?? {
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.level = .statusBar
            fallbackAnchor = window
            return window
        }()
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        window.setFrame(NSRect(x: screen.maxX - 80, y: screen.maxY - 1, width: 24, height: 1), display: false)
        window.orderFront(nil)
        return window.contentView ?? NSView()
    }
}

struct RemoteContent: View {
    let controller: PlaybackController
    let openVideo: @MainActor @Sendable () -> Void
    let playCopiedLink: @MainActor @Sendable () -> Void
    let open: @MainActor @Sendable ([URL]) -> Void

    var body: some View {
        RemoteView(
            state: controller.remoteState,
            artwork: controller.artwork.map { Image(nsImage: $0) },
            actions: RemoteActions(
                openVideo: openVideo,
                playCopiedLink: playCopiedLink,
                drop: { urls in
                    // Anything is taken: a file that isn't a video gets a notice saying so.
                    guard !urls.isEmpty else { return false }
                    open(urls)
                    return true
                },
                togglePlay: { controller.togglePause() },
                skip: { controller.skip(by: $0) },
                seek: { controller.seek(toMovieTime: $0) },
                stop: { controller.stop() },
                setVolume: { controller.volume = $0 },
                dismissWelcome: { controller.dismissWelcome() },
                dismissNotice: { controller.dismissNotice() },
                selectAudio: { controller.selectAudio($0) },
                selectSubtitle: { controller.selectSubtitle($0) },
                showLog: {
                    if let log = controller.failureLog {
                        NSWorkspace.shared.activateFileViewerSelecting([log])
                    }
                }),
            drawsBackground: false // the popover draws it, pointer included
        ) {
            RoutePicker(player: controller.player)
        }
    }
}

/// The panel's content: Edit ▸ Paste (⌘V) with nothing else to take it plays what was copied, and
/// Esc closes the panel. Only here, so ⌘V in Settings leaves what's playing alone.
private final class PanelContentController: NSHostingController<RemoteContent> {
    var paste: (@MainActor () -> Void)?
    var close: (@MainActor () -> Void)?

    @objc func paste(_ sender: Any?) {
        paste?()
    }

    override func cancelOperation(_ sender: Any?) {
        close?()
    }
}
