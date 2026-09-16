// swift-tools-version: 5.9
import PackageDescription

/**
 SeshKit — everything the app knows how to do, apart from how it looks.

 `SeshCore` deliberately depends on nothing but Foundation. The rules that
 decide what a session lasted, which day a task belongs to, what colour the
 room becomes and who wins when two devices disagree are all here, as plain
 values and pure functions, so they can be tested in a second on any machine
 rather than only inside a simulator.

 Persistence lives apart in `SeshStore` for the same reason: SQLite is how the
 answers are kept, not what they are.
 */
let package = Package(
    name: "SeshKit",
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
