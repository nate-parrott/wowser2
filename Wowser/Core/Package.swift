// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Core",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Core",
            targets: ["Core"]
        ),
    ],
    dependencies: [
        .package(name: "ChatToys", path: "../../../chattoys"),
        .package(name: "Reeeed", path: "../../reeeed"),
        .package(url: "https://github.com/DenDmitriev/DominantColors.git", .upToNextMajor(from: "1.2.0")),
        .package(url: "https://github.com/b3ll/Motion.git", branch: "main"),
        .package(url: "https://github.com/johnsundell/ink.git", from: "0.1.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Core",
            dependencies: [
                "ChatToys", "DominantColors", "Reeeed", "Motion",
                .product(name: "Ink", package: "ink"),
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS])),
                .product(name: "MCP", package: "swift-sdk", condition: .when(platforms: [.macOS])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.macOS])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.macOS])),
                .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.macOS])),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.macOS])),
                .product(name: "X509", package: "swift-certificates", condition: .when(platforms: [.macOS])),
            ],
            resources: [
                .copy("Adblock/easylist.min.json"),
                .copy("Adblock/easycookie.min.json"),
                .copy("ElementPicker/elementPicker.js"),
                .copy("BrowserJS/BrowserJS.d.ts"),
                .process("Assets.xcassets"),
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: [
                "Core",
                .product(name: "MCP", package: "swift-sdk", condition: .when(platforms: [.macOS])),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
