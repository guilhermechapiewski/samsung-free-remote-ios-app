// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SamsungTVKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "SamsungTVKit", targets: ["SamsungTVKit"]),
    ],
    targets: [
        .target(name: "SamsungTVKit"),
        .testTarget(
            name: "SamsungTVKitTests",
            dependencies: ["SamsungTVKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
