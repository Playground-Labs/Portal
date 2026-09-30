// swift-tools-version: 6.0
import PackageDescription
import Foundation

let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/native").path
let package = Package(
    name: "Portal",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Portal", targets: ["Portal"])],
    targets: [
        .target(name: "PortalCore"),
        .target(name: "PortalVNC", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I", native + "/include"])],
                linkerSettings: [.unsafeFlags(["-L", native + "/lib", "-Xlinker", "-rpath", "-Xlinker", native + "/lib"]), .linkedLibrary("vncclient"), .linkedLibrary("iconv")]),
        .executableTarget(name: "Portal", dependencies: ["PortalCore", "PortalVNC"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("Security")]),
        .testTarget(name: "PortalAppTests", dependencies: ["Portal", "PortalCore"], resources: [.copy("session_server.py")]),
        .testTarget(name: "PortalCoreTests", dependencies: ["PortalCore"]),
        .testTarget(name: "PortalVNCTests", dependencies: ["PortalVNC"], resources: [.copy("rfb_server.py")])
    ],
    swiftLanguageModes: [.v5]
)
