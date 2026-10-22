// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    targets: [
        // Data layer: models, providers, network guard, stores. No UI.
        .target(name: "QuotaBarCore", path: "Sources/QuotaBarCore"),
        // Menu bar app: AppKit status item + SwiftUI views.
        .executableTarget(name: "QuotaBar", dependencies: ["QuotaBarCore"], path: "Sources/QuotaBar"),
        .testTarget(name: "QuotaBarTests", dependencies: ["QuotaBarCore"], path: "Tests/QuotaBarTests"),
    ]
)
