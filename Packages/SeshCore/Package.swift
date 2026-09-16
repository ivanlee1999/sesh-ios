// swift-tools-version: 5.9
import PackageDescription

/**
 SeshCore — the rules, and nothing else.

 No dependencies at all, deliberately. The decisions that matter most here —
 what a session lasted, which day a task belongs to, who wins when two devices
 disagree, what colour the room becomes — are worth being able to test in a
 second on any machine, including ones with no Xcode and no SQLite headers.
 That is only true if nothing is in the way.

 Persistence lives in the SeshStore package next door, where GRDB belongs.
 */
let package = Package(
    name: "SeshCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SeshCore", targets: ["SeshCore"]),
    ],
    targets: [
        .target(name: "SeshCore"),
        .testTarget(
            name: "SeshCoreTests",
            dependencies: ["SeshCore"],
            // Real responses captured from a running sesh-web, so the wire types
            // are held to what the server actually sends rather than to a
            // hand-written idea of it.
            resources: [.copy("Fixtures")]
        ),
    ]
)
