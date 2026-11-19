// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SamsungTVKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "SamsungTVKit", targets: ["SamsungTVKit"]),
        .executable(name: "tvprobe", targets: ["tvprobe"]),
    ],
    targets: [
        .target(name: "SamsungTVKit"),
        .executableTarget(name: "tvprobe", dependencies: ["SamsungTVKit"]),
        .testTarget(
            name: "SamsungTVKitTests",
            dependencies: ["SamsungTVKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SamsungTVKitIntegrationTests",
            dependencies: ["SamsungTVKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
