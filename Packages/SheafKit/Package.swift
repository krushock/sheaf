// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SheafKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SheafKit", targets: ["SheafKit"]),
    ],
    targets: [
        .target(name: "SheafKit"),
        .testTarget(
            name: "SheafKitTests",
            dependencies: ["SheafKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
