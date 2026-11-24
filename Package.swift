// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DontCloseMe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DontCloseMe", targets: ["DontCloseMe"])
    ],
    targets: [
        .executableTarget(
            name: "DontCloseMe",
            path: "Sources/DontCloseMe",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "DontCloseMeTests",
            dependencies: ["DontCloseMe"],
            path: "Tests/DontCloseMeTests"
        )
    ]
)
