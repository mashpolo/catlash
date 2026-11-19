// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PacketBridge",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [.library(name: "PacketBridge", targets: ["PacketBridge"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", revision: "a27b21e0c81c5bf42049b897a62aaf387e80f279")],
    targets: [
        .binaryTarget(name: "MihomoBridge", path: "build/MihomoBridge.xcframework"),
        .target(
            name: "PacketBridge",
            dependencies: ["MihomoBridge", .product(name: "Yams", package: "Yams")],
            path: ".",
            exclude: ["vendor", "docs", "Resources", "AGENTS.md", "LICENSE", "HANDOFF_IOS.md", "IOS_NATIVE_SPEC.md", "IOS_PHASE0_CLASH_RS_AUDIT.md", "build", "core", "patches", "prepare-core-overlay.py", "go-overlay-wrapper.sh", "test-core.sh", "measure-host.sh", "Tools", "ProbeApp", "ProbeAppUITests", "ProbeTunnel", "PacketBridgeTests", "README.md", "VALIDATION.md", "build-core.sh", "generate-project.rb", "generate-tests.rb", "MihomoProbe.xcodeproj"],
            sources: ["PacketBridge", "SnapshotStore", "ProfileStore", "CloudSync"],
            linkerSettings: [.linkedLibrary("resolv")]
        ),
        .testTarget(name: "PacketBridgeTests", dependencies: ["PacketBridge"], path: "PacketBridgeTests"),
    ]
)
