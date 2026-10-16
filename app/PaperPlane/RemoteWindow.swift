import AppKit
import PaperPlaneCore
import SwiftUI

/// The small "now playing" window (spec §1). Plain AppKit, so it can be shown from anywhere,
/// including Finder's Open With.
@MainActor
final class RemoteWindow {
    private let window: NSWindow

    init(controller: PlaybackController, open: @escaping ([URL]) -> Void) {
        window = NSWindow(contentViewController: NSHostingController(rootView: RemoteView(controller: controller, open: open)))
        window.title = "Paper Plane"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct RemoteView: View {
    let controller: PlaybackController
    let open: ([URL]) -> Void
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.title ?? "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(controller.status)
                        .foregroundStyle(controller.needsTV ? Color.accentColor : .secondary)
                }
                Spacer()
                RoutePicker(player: controller.player)
                    .frame(width: 32, height: 26)
                    .padding(4)
                    .background(controller.needsTV ? Color.accentColor.opacity(0.25) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .help("Choose your TV")
            }
            HStack(spacing: 10) {
                Button(controller.isPaused ? "Play" : "Pause", systemImage: controller.isPaused ? "play.fill" : "pause.fill") {
                    controller.togglePause()
                }
                .disabled(!controller.isOnTV)
                Button("Stop", systemImage: "stop.fill") {
                    controller.stop()
                }
                .disabled(!controller.isActive)
                Spacer()
                Text(controller.timeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 440)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(3)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !VideoFiles.videos(in: urls).isEmpty else { return false }
            open(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}
