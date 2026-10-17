// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CreatorMicroStudioKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CreatorMicroStudioKit", targets: ["CreatorMicroStudioKit"]),
    ],
    targets: [
        .target(name: "CreatorMicroStudioKit"),
        .testTarget(
            name: "CreatorMicroStudioKitTests",
            dependencies: ["CreatorMicroStudioKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
