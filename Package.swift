// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DispatchKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DispatchKit", targets: ["DispatchKit"]),
        // Moderation tool for the community question catalog (plan 20).
        // macOS-only in practice: the app depends solely on the DispatchKit
        // library product, so iOS builds never compile this target, and its
        // sources are additionally wrapped in `#if os(macOS)`.
        .executable(name: "dispatch-mod", targets: ["dispatch-mod"]),
    ],
    targets: [
        .target(name: "DispatchKit"),
        .executableTarget(name: "dispatch-mod", dependencies: ["DispatchKit"]),
        .testTarget(
            name: "DispatchKitTests",
            dependencies: ["DispatchKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
