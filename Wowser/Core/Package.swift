// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// MARK: - CEF (Chromium engine) build flag
//
// CEF support is opt-in so quick WebKit-only builds stay fast. Enable by either:
//   - creating a marker file:  touch Wowser/Core/.cef-enabled   (works for Xcode + CLI)
//   - or exporting WOWSER_CEF=1 before `swift build`
// When enabled, Core gains the CefSwift dependency (macOS only) and all
// `#if canImport(CefKit)` code compiles in. Toggling this invalidates package
// resolution, so expect a full rebuild of Core.
// See scripts/cef/README.md for how the CEF framework + helpers get into the app bundle.
let cefEnabled: Bool = {
    if ProcessInfo.processInfo.environment["WOWSER_CEF"] == "1" { return true }
    let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".cef-enabled")
    return FileManager.default.fileExists(atPath: marker.path)
}()

var dependencies: [Package.Dependency] = [
    .package(name: "ChatToys", path: "../../chattoys"),
    .package(name: "Reeeed", path: "../../reeeed"),
    .package(url: "https://github.com/DenDmitriev/DominantColors.git", .upToNextMajor(from: "1.2.0")),
    .package(url: "https://github.com/b3ll/Motion.git", branch: "main"),
    .package(url: "https://github.com/johnsundell/ink.git", from: "0.1.0"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
]

var coreDependencies: [Target.Dependency] = [
    "ChatToys", "DominantColors", "Reeeed", "Motion",
    .product(name: "Ink", package: "ink"),
    .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS])),
    .product(name: "MCP", package: "swift-sdk", condition: .when(platforms: [.macOS])),
    .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.macOS])),
    .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.macOS])),
    .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.macOS])),
    .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.macOS])),
    .product(name: "X509", package: "swift-certificates", condition: .when(platforms: [.macOS])),
]

if cefEnabled {
    dependencies.append(.package(url: "https://github.com/Rajaniraiyn/CefSwift.git", from: "0.1.0"))
    coreDependencies.append(.product(name: "CefKit", package: "CefSwift", condition: .when(platforms: [.macOS])))
}

let package = Package(
    name: "Core",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Core",
            targets: ["Core"]
        ),
    ],
    dependencies: dependencies,
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Core",
            dependencies: coreDependencies,
            resources: [
                .copy("Adblock/easylist.min.json"),
                .copy("Adblock/easycookie.min.json"),
                .copy("ElementPicker/elementPicker.js"),
                .copy("ElementPicker/styleSelectors.js"),
                .copy("BrowserJS/BrowserJS.d.ts"),
                .copy("TangApps"),
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
