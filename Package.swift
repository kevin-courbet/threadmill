// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Threadmill",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Threadmill",
            targets: ["Threadmill"]
        ),
        .executable(
            name: "threadmill-relay",
            targets: ["threadmill-relay"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "threadmill-relay",
            path: "Sources/threadmill-relay"
        ),
        .executableTarget(
            name: "Threadmill",
            dependencies: ["GhosttyKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        )
    ]
)
