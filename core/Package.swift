// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperPlaneCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaperPlaneCore", targets: ["PaperPlaneCore"]),
    ],
    targets: [
        .target(name: "PaperPlaneCore"),
        .testTarget(name: "PaperPlaneCoreTests", dependencies: ["PaperPlaneCore"]),
    ]
)
