import AppKit
import PaperPlaneCore
import PaperPlaneUI
import SwiftUI

/// The small "now playing" window (spec §1). Plain AppKit, so it can be shown from anywhere,
/// including Finder's Open With. The views themselves live in PaperPlaneUI.
@MainActor
final class RemoteWindow {
    private let window: NSWindow

    init(controller: PlaybackController, openVideo: @escaping @MainActor @Sendable () -> Void,
         open: @escaping @MainActor @Sendable ([URL]) -> Void) {
        let root = RemoteWindowContent(controller: controller, openVideo: openVideo, open: open)
        window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Paper Plane"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct RemoteWindowContent: View {
    let controller: PlaybackController
    let openVideo: @MainActor @Sendable () -> Void
    let open: @MainActor @Sendable ([URL]) -> Void

    var body: some View {
        RemoteView(
            state: controller.remoteState,
            artwork: controller.artwork.map { Image(nsImage: $0) },
            actions: RemoteActions(
                openVideo: openVideo,
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
                })
        ) {
            RoutePicker(player: controller.player)
        }
        .padding(.top, 18) // room for the window buttons in the transparent title bar
        .background(.background) // the padding above RemoteView's own background
    }
}
