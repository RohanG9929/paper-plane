import Foundation

/// The menu bar icon's menu, as plain values the app turns into an NSMenu: what's playing and
/// its tracks first, then opening things, then Settings and Quit.
public enum StatusMenu {
    public struct Item: Equatable, Sendable {
        public enum Command: Equatable, Sendable {
            case togglePlay, stop, openVideo, showRemote, settings, quit
            case selectAudio(String)
            /// nil turns subtitles off.
            case selectSubtitle(String?)
        }

        public var title: String
        /// nil for a heading or a separator.
        public var command: Command?
        /// The key used with ⌘, if any.
        public var key: String
        public var isEnabled: Bool
        public var isChecked: Bool
        public var submenu: [Item]?

        public init(_ title: String, _ command: Command? = nil, key: String = "", isEnabled: Bool = true,
                    isChecked: Bool = false, submenu: [Item]? = nil) {
            self.title = title
            self.command = command
            self.key = key
            self.isEnabled = isEnabled
            self.isChecked = isChecked
            self.submenu = submenu
        }

        public static let separator = Item("-")
        public var isSeparator: Bool { title == "-" && command == nil }
    }

    public static func items(for state: RemoteState) -> [Item] {
        var items: [Item] = []
        if state.phase != .idle, !state.title.isEmpty {
            items.append(Item(state.title, isEnabled: false))
            if case .failed = state.phase {
                items.append(Item("Dismiss", .stop))
            } else {
                items.append(Item(state.playButtonLabel, .togglePlay, isEnabled: state.canControlPlayback))
                items.append(Item("Stop", .stop, key: "."))
            }
            if state.canChooseTracks, state.audioChoices.count > 1 {
                items.append(Item("Audio", submenu: state.audioChoices.map {
                    Item($0.name, .selectAudio($0.id), isChecked: $0.id == state.audio)
                }))
            }
            if state.canChooseTracks, !state.subtitleChoices.isEmpty {
                items.append(Item("Subtitles", submenu: [Item("Off", .selectSubtitle(nil), isChecked: state.subtitle == nil)]
                    + state.subtitleChoices.map {
                        Item($0.name, .selectSubtitle($0.id), isChecked: $0.id == state.subtitle)
                    }))
            }
            items.append(.separator)
        }
        items += [
            Item("Open Video…", .openVideo, key: "o"),
            Item("Show Remote", .showRemote, key: "1"),
            .separator,
            Item("Settings…", .settings, key: ","),
            .separator,
            Item("Quit Paper Plane", .quit, key: "q"),
        ]
        return items
    }
}
