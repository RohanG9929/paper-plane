import SwiftUI

/// What the remote's controls do. The app wires these to its playback controller.
public struct RemoteActions: Sendable {
    public var openVideo: @MainActor @Sendable () -> Void
    /// Files dropped on the window. Returns whether any of them was taken.
    public var drop: @MainActor @Sendable ([URL]) -> Bool
    public var togglePlay: @MainActor @Sendable () -> Void
    /// Seconds to move by: −10 or +10.
    public var skip: @MainActor @Sendable (Double) -> Void
    /// Movie time to go to.
    public var seek: @MainActor @Sendable (Double) -> Void
    public var stop: @MainActor @Sendable () -> Void
    public var setVolume: @MainActor @Sendable (Double) -> Void
    public var dismissWelcome: @MainActor @Sendable () -> Void

    public init(openVideo: @escaping @MainActor @Sendable () -> Void = {},
                drop: @escaping @MainActor @Sendable ([URL]) -> Bool = { _ in false },
                togglePlay: @escaping @MainActor @Sendable () -> Void = {},
                skip: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
                seek: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
                stop: @escaping @MainActor @Sendable () -> Void = {},
                setVolume: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
                dismissWelcome: @escaping @MainActor @Sendable () -> Void = {}) {
        self.openVideo = openVideo
        self.drop = drop
        self.togglePlay = togglePlay
        self.skip = skip
        self.seek = seek
        self.stop = stop
        self.setVolume = setVolume
        self.dismissWelcome = dismissWelcome
    }
}

/// The small "now playing" window (spec §1): a welcome the first time, then a drop zone, then a
/// Now Playing card for the video on the TV.
public struct RemoteView<RoutePicker: View>: View {
    public static var width: CGFloat { 420 }

    var state: RemoteState
    var artwork: Image?
    var actions: RemoteActions
    var routePicker: RoutePicker
    @State private var isDropTarget = false

    public init(state: RemoteState, artwork: Image? = nil, actions: RemoteActions,
                @ViewBuilder routePicker: () -> RoutePicker) {
        self.state = state
        self.artwork = artwork
        self.actions = actions
        self.routePicker = routePicker()
    }

    public var body: some View {
        Group {
            if state.showsWelcome {
                WelcomeView(done: actions.dismissWelcome)
            } else if state.phase == .idle {
                DropZone(isTargeted: isDropTarget, openVideo: actions.openVideo)
            } else {
                NowPlayingCard(state: state, artwork: artwork, actions: actions, routePicker: routePicker)
            }
        }
        .frame(width: Self.width)
        .background(.background)
        .overlay {
            // The drop zone highlights itself; everywhere else the window gets a ring.
            if isDropTarget && (state.showsWelcome || state.phase != .idle) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            actions.drop(urls)
        } isTargeted: { isDropTarget = $0 }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Paper Plane")
                    .font(.title2.weight(.semibold))
                Text("Send any video on your Mac to your AirPlay TV.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                step("film.stack", "Drop a video on this window",
                     "MKV, MP4, WebM and more. Paper Plane converts whatever your TV can't play.")
                step("airplayvideo", "Choose your TV",
                     "Use the AirPlay button. The first time, your TV may show a code to type on your Mac.")
                step("network", "Allow local network access",
                     "If macOS asks, click Allow. Your TV fetches the video from this Mac.")
            }
            HStack {
                Spacer()
                Button("Get Started", action: done)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Drop zone

struct DropZone: View {
    var isTargeted: Bool
    var openVideo: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "play.rectangle.on.rectangle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Drop a video here")
                    .font(.title3.weight(.semibold))
                Text("It plays on your TV over AirPlay.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Open Video…", action: openVideo)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.clear))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop a video here to play it on your TV")
    }
}

// MARK: - Now playing

struct NowPlayingCard<RoutePicker: View>: View {
    var state: RemoteState
    var artwork: Image?
    var actions: RemoteActions
    var routePicker: RoutePicker

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch state.phase {
            case .failed:
                failure
            default:
                if case .choosingTV = state.phase {
                    chooseTVCallout
                }
                Scrubber(state: state, seek: actions.seek, skip: actions.skip)
                    .disabled(!state.canControlPlayback)
                transport
                volume
            }
        }
        .padding(20)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Artwork(image: artwork)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StatusLine(state: state)
                    .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
    }

    private var chooseTVCallout: some View {
        HStack {
            Text("Click the AirPlay button below and pick your TV. Paper Plane never plays on this Mac.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var transport: some View {
        HStack {
            Button(action: actions.stop) {
                Image(systemName: "stop.fill").font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityLabel("Stop")
            .help("Stop")

            Spacer()
            HStack(spacing: 20) {
                TransportButton(symbol: "gobackward.10", label: "Back 10 seconds", enabled: state.canControlPlayback) {
                    actions.skip(-10)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                PlayButton(isPlaying: state.phase == .playing, label: state.playButtonLabel,
                           enabled: state.canControlPlayback, action: actions.togglePlay)
                    .keyboardShortcut(.space, modifiers: [])
                TransportButton(symbol: "goforward.10", label: "Forward 10 seconds", enabled: state.canControlPlayback) {
                    actions.skip(10)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            Spacer()

            routePicker
                .frame(width: 32, height: 32)
                .background {
                    if case .choosingTV = state.phase {
                        Circle().fill(Color.accentColor.opacity(0.18))
                        Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .help("Choose your TV")
        }
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { state.volume }, set: actions.setVolume), in: 0...1)
                .controlSize(.small)
                .disabled(!state.canAdjustVolume)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(state.status)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Dismiss", action: actions.stop)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Choose Another Video…", action: actions.openVideo)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct StatusLine: View {
    var state: RemoteState

    var body: some View {
        switch state.phase {
        case .preparing:
            label("hourglass", color: .secondary)
        case .choosingTV:
            label("airplayvideo", color: .accentColor, weight: .semibold)
        case .playing:
            label("tv", color: .secondary)
        case .paused:
            label("pause.circle", color: .secondary)
        case .failed, .idle:
            EmptyView() // a failure is spelled out below the header
        }
    }

    private func label(_ symbol: String, color: Color, weight: Font.Weight = .medium) -> some View {
        Label(state.status, systemImage: symbol)
            .font(.caption.weight(weight))
            .foregroundStyle(color)
            .lineLimit(2)
    }
}

struct Artwork: View {
    var image: Image?

    var body: some View {
        ZStack {
            if let image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 0.38, green: 0.74, blue: 1.0), Color(red: 0.20, green: 0.27, blue: 0.82)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .accessibilityHidden(true)
    }
}

struct PlayButton: View {
    var isPlaying: Bool
    var label: String
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: isPlaying ? 0 : 2)
                .frame(width: 56, height: 56)
                .background(Circle().fill(enabled ? Color.accentColor : Color.secondary.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct TransportButton: View {
    var symbol: String
    var label: String
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - Scrubber

/// Elapsed time, a track showing what's been played and what's ready, and the time left.
/// Drag or click to seek; VoiceOver adjusts it in 10-second steps.
struct Scrubber: View {
    var state: RemoteState
    var seek: (Double) -> Void
    var skip: (Double) -> Void
    @State private var dragFraction: Double?

    var body: some View {
        let duration = state.duration ?? 0
        let played = dragFraction ?? RemoteState.fraction(of: state.elapsed, in: state.duration)
        let ready = RemoteState.fraction(of: state.converted ?? 0, in: state.duration)
        let shownTime = dragFraction.map { $0 * duration } ?? state.elapsed
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tertiary).frame(width: width * ready)
                    Capsule().fill(state.canControlPlayback ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: max(6, width * played))
                }
                .frame(height: dragFraction == nil ? 6 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard state.canControlPlayback, width > 0 else { return }
                            // Only as far as can be played now; the thumb stops at the edge.
                            dragFraction = min(max(value.location.x / width, 0), state.seekableFraction)
                        }
                        .onEnded { _ in
                            if let fraction = dragFraction, duration > 0 {
                                seek(fraction * duration)
                            }
                            dragFraction = nil
                        })
            }
            .frame(height: 14)
            HStack {
                Text(TimeText.clock(shownTime))
                Spacer()
                Text(state.duration.map { TimeText.remaining(elapsed: shownTime, duration: $0) } ?? "")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .opacity(state.canControlPlayback ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(state.duration.map { "\(TimeText.spoken(state.elapsed)) of \(TimeText.spoken($0))" }
            ?? TimeText.spoken(state.elapsed))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: skip(10)
            case .decrement: skip(-10)
            @unknown default: break
            }
        }
    }
}
