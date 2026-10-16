import SwiftUI

/// What the remote's controls do. The app wires these to its playback controller.
public struct RemoteActions: Sendable {
    public var openVideo: @MainActor @Sendable () -> Void
    /// Plays a link (or a video file) from the clipboard.
    public var playCopiedLink: @MainActor @Sendable () -> Void
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
    public var dismissNotice: @MainActor @Sendable () -> Void
    /// An audio track's `RemoteState.Choice.id`.
    public var selectAudio: @MainActor @Sendable (String) -> Void
    /// A subtitle's `RemoteState.Choice.id`, or nil for off.
    public var selectSubtitle: @MainActor @Sendable (String?) -> Void
    /// Reveals the saved log of the last failure.
    public var showLog: @MainActor @Sendable () -> Void

    public init(openVideo: @escaping @MainActor @Sendable () -> Void = {},
                playCopiedLink: @escaping @MainActor @Sendable () -> Void = {},
                drop: @escaping @MainActor @Sendable ([URL]) -> Bool = { _ in false },
                togglePlay: @escaping @MainActor @Sendable () -> Void = {},
                skip: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
                seek: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
                stop: @escaping @MainActor @Sendable () -> Void = {},
                setVolume: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
                dismissWelcome: @escaping @MainActor @Sendable () -> Void = {},
                dismissNotice: @escaping @MainActor @Sendable () -> Void = {},
                selectAudio: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                selectSubtitle: @escaping @MainActor @Sendable (String?) -> Void = { _ in },
                showLog: @escaping @MainActor @Sendable () -> Void = {}) {
        self.openVideo = openVideo
        self.playCopiedLink = playCopiedLink
        self.drop = drop
        self.togglePlay = togglePlay
        self.skip = skip
        self.seek = seek
        self.stop = stop
        self.setVolume = setVolume
        self.dismissWelcome = dismissWelcome
        self.dismissNotice = dismissNotice
        self.selectAudio = selectAudio
        self.selectSubtitle = selectSubtitle
        self.showLog = showLog
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
    /// Off in the menu bar panel, where the popover draws the background, pointer included.
    var drawsBackground: Bool
    @State private var isDropTarget = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: RemoteState, artwork: Image? = nil, actions: RemoteActions, drawsBackground: Bool = true,
                @ViewBuilder routePicker: () -> RoutePicker) {
        self.state = state
        self.artwork = artwork
        self.actions = actions
        self.drawsBackground = drawsBackground
        self.routePicker = routePicker()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let notice = state.notice {
                NoticeBanner(message: notice, dismiss: actions.dismissNotice)
                    .transition(.opacity)
            }
            if state.showsWelcome {
                WelcomeView(done: actions.dismissWelcome)
            } else if state.phase == .idle {
                DropZone(isTargeted: isDropTarget, openVideo: actions.openVideo, playCopiedLink: actions.playCopiedLink)
            } else {
                NowPlayingCard(state: state, artwork: artwork, actions: actions, routePicker: routePicker)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.notice)
        .frame(width: Self.width)
        .background {
            if drawsBackground {
                Rectangle().fill(.background)
            }
        }
        .overlay {
            // The drop zone highlights itself; everywhere else the window gets a ring.
            if isDropTarget && (state.showsWelcome || state.phase != .idle) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            actions.drop(urls)
        } isTargeted: { isDropTarget = $0 }
    }
}

// MARK: - Notice

/// A passing message at the top of the window, such as a dropped file that isn't a video. It
/// leaves whatever is playing alone.
struct NoticeBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 20) // the same margin as the card below it
        .onAppear {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Paper Plane")
                    .font(.title2.weight(.semibold))
                Text("Send any video on your Mac to your AirPlay TV.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                step("film.stack", "Drop a video on this window",
                     "MKV, MP4, WebM and more. Paper Plane converts them for AirPlay as they play.")
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
        .padding(.horizontal, 20) // the card's margins
        .padding(.vertical, 28)
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .leading) // in line with the heading
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
    var playCopiedLink: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "play.rectangle.on.rectangle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Drop a video or a link here")
                    .font(.title3.weight(.semibold))
                Text("It plays on your TV over AirPlay.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Open Video…", action: openVideo)
                    .buttonStyle(.borderedProminent)
                // ⌘V comes from Edit ▸ Paste, which the app handles the same way.
                Button("Play Copied Link", action: playCopiedLink)
                    .buttonStyle(.bordered)
                    .help("Plays a link you've copied: YouTube, most video sites, or a video file's address (⌘V)")
            }
            .controlSize(.large)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isTargeted ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
        }
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop a video or a link here to play it on your TV")
    }
}

// MARK: - Now playing

struct NowPlayingCard<RoutePicker: View>: View {
    var state: RemoteState
    var artwork: Image?
    var actions: RemoteActions
    var routePicker: RoutePicker

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch state.phase {
            case .failed:
                failure
            default:
                if case .choosingTV = state.phase, state.showsTVHelp {
                    chooseTVCallout
                }
                if state.isLive {
                    LiveIndicator()
                } else {
                    Scrubber(state: state, seek: actions.seek, skip: actions.skip)
                        .disabled(!state.canControlPlayback)
                }
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
            Text("Click the AirPlay button below and pick your TV. The video starts once the TV is connected.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Stop on the left, the AirPlay button (and the audio and subtitle menu) on the right, and
    /// play with its skips centred between them whatever their widths. Borderless buttons, so
    /// Full Keyboard Access draws focus rings.
    private var transport: some View {
        HStack {
            Button(action: actions.stop) {
                Image(systemName: "stop.circle").font(.system(size: 20, weight: .regular))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(RemoteButtonStyle())
            .foregroundStyle(.primary)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityLabel("Stop")
            .help("Stop")

            Spacer()

            HStack(spacing: 4) {
                if state.showsAudioChoices || state.showsSubtitleChoices {
                    TracksMenu(state: state, selectAudio: actions.selectAudio, selectSubtitle: actions.selectSubtitle)
                }
                routePicker
                    .frame(width: 32, height: 32)
                    .background {
                        if case .choosingTV = state.phase {
                            Circle().fill(.tint.opacity(0.18))
                            Circle().strokeBorder(.tint, lineWidth: 1.5)
                        }
                    }
                    .help("Choose your TV")
            }
        }
        .overlay {
            HStack(spacing: 20) {
                TransportButton(symbol: "gobackward.10", label: "Back 10 seconds", enabled: state.canSeek) {
                    actions.skip(-10)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                PlayButton(isPlaying: state.phase == .playing, label: state.playButtonLabel,
                           enabled: state.canControlPlayback, action: actions.togglePlay)
                    .keyboardShortcut(.space, modifiers: [])
                TransportButton(symbol: "goforward.10", label: "Forward 10 seconds", enabled: state.canSeek) {
                    actions.skip(10)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
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
                if state.canShowLog {
                    Button("Show Log", action: actions.showLog)
                        .controlSize(.large)
                        .help("Show the details in Finder, for a bug report")
                }
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
        case _ where state.isLoading, .preparing:
            label("hourglass")
        case .choosingTV:
            label("airplayvideo", isNextStep: true)
        case .playing:
            label("tv")
        case .paused:
            label("pause.circle")
        case .failed, .idle:
            EmptyView() // a failure is spelled out below the header
        }
    }

    /// The next step's icon takes the accent colour; its words stay in the text colour, which
    /// reads better than the accent at caption size.
    private func label(_ symbol: String, isNextStep: Bool = false) -> some View {
        Label {
            Text(state.status)
                .foregroundStyle(isNextStep ? .primary : .secondary)
        } icon: {
            Image(systemName: symbol)
                .symbolVariant(.none)
                .foregroundStyle(isNextStep ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 16) // every icon as wide, so the words line up
        }
        .font(.caption.weight(isNextStep ? .semibold : .medium))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
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
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08))
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
                .foregroundStyle(enabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .offset(x: isPlaying ? 0 : 2)
                .frame(width: 56, height: 56)
                .background(Circle().fill(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(RemoteButtonStyle(circle: true))
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
        .buttonStyle(RemoteButtonStyle(circle: true))
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Audio and subtitles in one menu, as the TV app has them. Picking audio, or subtitles that
/// are drawn into the picture, takes a moment while a new session starts.
struct TracksMenu: View {
    var state: RemoteState
    var selectAudio: @MainActor @Sendable (String) -> Void
    var selectSubtitle: @MainActor @Sendable (String?) -> Void

    @Environment(\.drawsMenusAsLabels) private var drawsMenusAsLabels

    var body: some View {
        if drawsMenusAsLabels {
            label
        } else {
            menu
        }
    }

    private var label: some View {
        Image(systemName: state.subtitle == nil ? "captions.bubble" : "captions.bubble.fill")
            .font(.system(size: 18, weight: .regular))
            .frame(width: 32, height: 32)
    }

    private var menu: some View {
        Menu {
            if state.showsAudioChoices {
                Picker("Audio", selection: Binding(get: { state.audio ?? "" }, set: selectAudio)) {
                    ForEach(state.audioChoices) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
            if state.showsSubtitleChoices {
                Picker("Subtitles", selection: Binding(get: { state.subtitle ?? "" },
                                                       set: { selectSubtitle($0.isEmpty ? nil : $0) })) {
                    Text("Off").tag("")
                    ForEach(state.subtitleChoices) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(state.tracksLabel)
        .help(state.tracksLabel)
    }
}

/// The remote's own buttons: no bezel, dimmed while pressed, and a focus ring of their own so
/// Full Keyboard Access shows where it is (design audit, move 1). Drawn entirely by SwiftUI, so
/// the snapshots show them as they are.
struct RemoteButtonStyle: ButtonStyle {
    var circle = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, circle: circle)
    }

    private struct Styled: View {
        let configuration: Configuration
        let circle: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.6 : 1)
                .overlay {
                    if isFocused && isEnabled {
                        if circle {
                            Circle().strokeBorder(.tint.opacity(0.7), lineWidth: 3).padding(-4)
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.tint.opacity(0.7), lineWidth: 3).padding(-4)
                        }
                    }
                }
        }
    }
}

extension EnvironmentValues {
    /// Menus draw only their label: ImageRenderer can't draw AppKit's pop-up buttons, so the
    /// snapshots set this.
    @Entry var drawsMenusAsLabels = false
}

// MARK: - Scrubber

/// In place of the scrubber for a live stream, which has nothing to seek in (spec §5.3). As tall
/// as the scrubber, so the controls below stay put.
struct LiveIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text("Live")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live stream")
    }
}

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
        let readyFrom = RemoteState.fraction(of: state.convertedFrom ?? 0, in: state.duration)
        let ready = max(RemoteState.fraction(of: state.converted ?? 0, in: state.duration), readyFrom)
        let shownTime = dragFraction.map { $0 * duration } ?? state.elapsed
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tertiary).frame(width: width * (ready - readyFrom)).offset(x: width * readyFrom)
                    Capsule().fill(state.canControlPlayback ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: played > 0 ? max(6, width * played) : 0) // no stub at 0:00
                }
                .frame(height: dragFraction == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard state.canControlPlayback, width > 0 else { return }
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
        .help(state.convertedNote)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityHint(state.convertedNote)
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
