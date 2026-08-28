// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iGhostVTKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
    ],
    products: [
        .library(name: "iGhostVTKit", targets: ["iGhostVTKit"]),
    ],
    targets: [
        .target(
            name: "iGhostVTKit",
            path: "Sources/iGhostVTKit"
        ),
    ]
)
