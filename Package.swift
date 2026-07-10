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
        // schema.ckdb is the repo-canonical CloudKit schema consumed by
        // `dispatch-mod setup` via cktool at runtime, not compiled in.
        .executableTarget(
            name: "dispatch-mod",
            dependencies: ["DispatchKit"],
            exclude: ["schema.ckdb"]
        ),
        .testTarget(
            name: "DispatchKitTests",
            // dispatch-mod dependency: lets the tests exercise the tool's
            // config resolution (per-environment key IDs) directly.
            dependencies: ["DispatchKit", "dispatch-mod"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
