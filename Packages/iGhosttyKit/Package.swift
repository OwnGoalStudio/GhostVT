// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iGhosttyKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
    ],
    products: [
        .library(name: "iGhosttyKit", targets: ["iGhosttyKit"]),
    ],
    targets: [
        .target(
            name: "iGhosttyKit",
            path: "Sources/iGhosttyKit"
        ),
    ]
)
