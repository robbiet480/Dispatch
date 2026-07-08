// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DispatchKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DispatchKit", targets: ["DispatchKit"])
    ],
    targets: [
        .target(name: "DispatchKit"),
        .testTarget(
            name: "DispatchKitTests",
            dependencies: ["DispatchKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
