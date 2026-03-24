// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShuviCmd",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/wangdongdongc/ShuviAgentCore.git", branch: "main"),
        .package(url: "https://github.com/wangdongdongc/ShuviMarkitdown.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "shuvi",
            dependencies: [
                .product(name: "ShuviAI", package: "ShuviAgentCore"),
                .product(name: "ShuviAgent", package: "ShuviAgentCore"),
                .product(name: "ShuviAgentOpenAIProvider", package: "ShuviAgentCore"),
                .product(name: "ShuviMarkitdown", package: "ShuviMarkitdown"),
            ],
            path: "Sources/shuvi"
        ),
    ]
)
