// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LeafSend",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LeafSend", targets: ["LeafSend"])
    ],
    targets: [
        .executableTarget(
            name: "LeafSend",
            path: "Sources/LeafSend"
        ),
        .testTarget(
            name: "LeafSendTests",
            dependencies: ["LeafSend"],
            path: "Tests/LeafSendTests"
        )
    ]
)
