// swift-tools-version:5.9
// Lets `swift build` (and Xcode, via File > Open… on this folder) build and index PortHop incrementally.
// ./build.sh is still what makes the finished PortHop.app: it adds the icon, the device tools and the signature.
import PackageDescription

let package = Package(
    name: "PortHop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PortHop",
            path: "Sources",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
