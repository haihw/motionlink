// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MotionLink",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MotionLinkCore", targets: ["MotionLinkCore"])],
    targets: [
        .target(name: "MotionLinkCore", path: "Shared", exclude: ["Theme.swift"]),
        .testTarget(name: "MotionLinkTests", dependencies: ["MotionLinkCore"], path: "Tests")
    ]
)
