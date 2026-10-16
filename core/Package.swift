// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperPlaneCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaperPlaneCore", targets: ["PaperPlaneCore"]),
        .library(name: "PaperPlaneUI", targets: ["PaperPlaneUI"]),
    ],
    targets: [
        .target(name: "PaperPlaneCore"),
        // The app's SwiftUI views and its playback controller, kept out of the app target so tests
        // can render the views to PNG and drive the controller.
        .target(name: "PaperPlaneUI", dependencies: ["PaperPlaneCore"]),
        .testTarget(name: "PaperPlaneCoreTests", dependencies: ["PaperPlaneCore"]),
        .testTarget(name: "PaperPlaneUITests", dependencies: ["PaperPlaneUI", "PaperPlaneCore"]),
    ]
)
