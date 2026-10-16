import AVKit
import SwiftUI

/// The AirPlay button. Setting `player` is what makes macOS list video AirPlay devices such as
/// TVs, not only speakers (spec §2).
struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.player = player
        picker.isRoutePickerButtonBordered = false
        picker.setAccessibilityLabel("Choose TV")
        // Match the rest of the control row; it turns the accent colour while AirPlay is on.
        picker.setRoutePickerButtonColor(.labelColor, for: .normal)
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        picker.player = player
    }
}
