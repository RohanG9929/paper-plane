import Foundation
import Observation
import PaperPlaneCore
import SwiftUI

/// The overrides for TVs that differ from the Sony Paper Plane was tested on (spec §4.1),
/// kept in UserDefaults.
@MainActor @Observable
public final class SettingsStore {
    enum Key {
        static let allowSurround = "allowSurround"
        static let convertHDRToSDR = "convertHDRToSDR"
        static let alwaysBurnInSubtitles = "alwaysBurnInSubtitles"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var allowSurround: Bool {
        didSet { defaults.set(allowSurround, forKey: Key.allowSurround) }
    }
    public var convertHDRToSDR: Bool {
        didSet { defaults.set(convertHDRToSDR, forKey: Key.convertHDRToSDR) }
    }
    public var alwaysBurnInSubtitles: Bool {
        didSet { defaults.set(alwaysBurnInSubtitles, forKey: Key.alwaysBurnInSubtitles) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = Self.settings(from: defaults)
        allowSurround = settings.profile.surround
        convertHDRToSDR = !settings.profile.hdr
        alwaysBurnInSubtitles = settings.alwaysBurnInSubtitles
    }

    /// The settings as playback uses them. Reads UserDefaults directly, so any thread may ask.
    public nonisolated static func settings(from defaults: UserDefaults) -> PlaybackSettings {
        PlaybackSettings(
            profile: OutputProfile(
                surround: defaults.object(forKey: Key.allowSurround) as? Bool ?? OutputProfile.default.surround,
                hdr: !(defaults.object(forKey: Key.convertHDRToSDR) as? Bool ?? !OutputProfile.default.hdr)),
            alwaysBurnInSubtitles: defaults.bool(forKey: Key.alwaysBurnInSubtitles))
    }
}

/// Settings: three switches, each saying what it's for. They apply from the next video or
/// track change.
public struct SettingsView: View {
    @Bindable var store: SettingsStore

    public init(store: SettingsStore) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section {
                setting("Allow surround sound", isOn: $store.allowSurround,
                        "Sends Dolby Digital 5.1 when the video has it. Many TVs play only stereo over AirPlay.")
                setting("Convert HDR to SDR", isOn: $store.convertHDRToSDR,
                        "For TVs that show HDR video too dark or washed out. Your Mac does more work.")
                setting("Always burn in subtitles", isOn: $store.alwaysBurnInSubtitles,
                        "Draws subtitles into the picture, for TVs that don't show subtitle tracks. Your Mac does more work.")
            } footer: {
                Text("Changes apply from the next video, seek or track change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setting(_ title: String, isOn: Binding<Bool>, _ detail: String) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(detail)
        }
    }
}
