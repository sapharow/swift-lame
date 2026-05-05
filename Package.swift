// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-lame",
    platforms: [
        .macOS(.v10_13), .iOS(.v12), .tvOS(.v12)
    ],
    products: [
        .library(name: "lamemp3", type: .dynamic, targets: ["liblame"]),
        .library(name: "SwiftLame", type: .dynamic, targets: ["SwiftLame"]),
    ],
    targets: [
        .target(name: "liblame", path: "Sources/lame", cSettings: [.headerSearchPath("libmp3lame/include")]),
        .target(name: "SwiftLame", dependencies: ["liblame"], path: "Sources/SwiftLame")
    ],
)
