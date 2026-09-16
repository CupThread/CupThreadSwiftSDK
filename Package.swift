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
        // Automatic linkage (static by default): consumers' app targets link
        // the SDK into their own binary, so the linker can dead-strip unused
        // code and app extensions stop embedding per-target dylib copies.
        // The CDN XCFramework is assembled from static archives by
        // scripts/release.mjs.
        .library(
            name: "CupThreadFeedback",
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
