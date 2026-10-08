// swift-tools-version: 6.0
import PackageDescription
import Foundation

let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/native").path
let brew = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? (FileManager.default.fileExists(atPath: "/opt/homebrew") ? "/opt/homebrew" : "/usr/local")
let package = Package(
    name: "Portal",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Portal", targets: ["Portal"])],
    targets: [
        .target(name: "PortalCore"),
        .target(name: "PortalVNC", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I", native + "/include", "-I", brew + "/opt/openssl/include", "-I", brew + "/opt/nettle/include"])],
                linkerSettings: [.unsafeFlags(["-L", native + "/lib", "-Xlinker", "-rpath", "-Xlinker", native + "/lib"]), .linkedLibrary("vncclient"), .linkedLibrary("iconv"), .unsafeFlags(["-L", brew + "/opt/openssl/lib", "-L", brew + "/opt/nettle/lib"]), .linkedLibrary("crypto"), .linkedLibrary("ssl"), .linkedLibrary("nettle")]),
        .executableTarget(name: "Portal", dependencies: ["PortalCore", "PortalVNC"],
                          resources: [.copy("Resources/Fonts")],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("Security")]),
        .testTarget(name: "PortalAppTests", dependencies: ["Portal", "PortalCore"], resources: [.copy("session_server.py")]),
        .testTarget(name: "PortalCoreTests", dependencies: ["PortalCore"]),
        .testTarget(name: "PortalVNCTests", dependencies: ["PortalVNC"], resources: [.copy("rfb_server.py"), .copy("rsa_server.py")])
    ],
    swiftLanguageModes: [.v5]
)
