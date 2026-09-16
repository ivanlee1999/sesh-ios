// swift-tools-version: 5.9
import PackageDescription

/**
 SeshStore — how the answers are kept.

 GRDB rather than SwiftData: the local schema deliberately mirrors the server's
 SQL, conflicts are settled by hand against `updated_at`, and a live query is
 wanted without a second source of truth. None of that is what SwiftData is for.
 */
let package = Package(
    name: "SeshStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SeshStore", targets: ["SeshStore"]),
    ],
    dependencies: [
        .package(path: "../SeshCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "SeshStore",
            dependencies: [
                .product(name: "SeshCore", package: "SeshCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "SeshStoreTests",
            dependencies: [
                "SeshStore",
                .product(name: "SeshCore", package: "SeshCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
