// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Jnobs",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Jnobs",
            path: "Sources/Jnobs",
            swiftSettings: [
                // Swift 5 mode: avoids a Swift 6 IRGen crash on @isolated(any)
                // @Sendable closure-conversion thunks (KnobBinding setters in the UI).
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
