// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JXLKit",
    platforms: [.macOS("27.3")],
    products: [
        .library(name: "JXLKit", targets: ["JXLKit"]),
    ],
    targets: [
        // Built by Scripts/build-libjxl.sh; not checked in.
        .binaryTarget(name: "CJXL", path: "../../Vendor/libjxl.xcframework"),
        .target(
            name: "JXLKit",
            dependencies: ["CJXL"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JXLKitTests",
            dependencies: ["JXLKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
