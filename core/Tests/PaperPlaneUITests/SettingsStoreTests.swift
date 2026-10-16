import Foundation
import PaperPlaneCore
import Testing
@testable import PaperPlaneUI

@MainActor
struct SettingsStoreTests {
    let defaults = UserDefaults(suiteName: "dev.paperplane.tests.\(UUID().uuidString)")!

    @Test func startsWithTheProfileTheSonyNeeds() {
        let store = SettingsStore(defaults: defaults)
        #expect(!store.allowSurround)
        #expect(!store.convertHDRToSDR)
        #expect(!store.alwaysBurnInSubtitles)
        #expect(SettingsStore.settings(from: defaults) == PlaybackSettings(profile: .default, alwaysBurnInSubtitles: false))
    }

    @Test func changesAreKeptAndBecomeThePlaybackSettings() {
        let store = SettingsStore(defaults: defaults)
        store.allowSurround = true
        store.convertHDRToSDR = true
        store.alwaysBurnInSubtitles = true
        #expect(SettingsStore.settings(from: defaults) == PlaybackSettings(
            profile: OutputProfile(surround: true, hdr: false), alwaysBurnInSubtitles: true))

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.allowSurround && reopened.convertHDRToSDR && reopened.alwaysBurnInSubtitles)
    }
}
