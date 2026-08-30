// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CupThreadFeedback",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
        .tvOS(.v17)
    ],
    products: [
        // Dynamic so the product can be archived into an XCFramework for the
        // binary distribution on cdn.cupthread.com (see scripts/release-sdk.mjs).
        .library(
            name: "CupThreadFeedback",
            type: .dynamic,
            targets: ["CupThreadFeedback"]
        )
    ],
    targets: [
        .target(
            name: "CupThreadFeedback"
        ),
        .testTarget(
            name: "CupThreadFeedbackTests",
            dependencies: ["CupThreadFeedback"]
        )
    ]
)
