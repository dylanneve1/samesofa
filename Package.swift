// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SameSofa",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SameSofa", targets: ["SameSofa"]),
        .executable(name: "samesofa-itest", targets: ["samesofa-itest"]),
    ],
    targets: [
        // Prebuilt Google WebRTC M157 (BSD-3-Clause) from github.com/stasel/WebRTC.
        // Fetched and checksum-verified by scripts/fetch-webrtc.sh.
        .binaryTarget(name: "WebRTC", path: "Vendor/WebRTC.xcframework"),
        // Pure Swift logic: protocol, sync maths, chunk bookkeeping. No WebRTC, no AVFoundation UI.
        .target(name: "SameSofaCore"),
        // Re-declares WebRTC's RTCAudioDevice protocol, which the macOS slice of the
        // framework implements but does not ship a public header for.
        .target(
            name: "CWebRTCAudioDevice",
            dependencies: ["WebRTC"]
        ),
        // Calls, file transfer, playback and audio. Shared by the app and the integration test.
        .target(
            name: "SameSofaKit",
            dependencies: [
                "SameSofaCore",
                "CWebRTCAudioDevice",
                "WebRTC",
            ]
        ),
        .executableTarget(
            name: "SameSofa",
            dependencies: ["SameSofaKit", "SameSofaCore", "WebRTC"]
        ),
        .executableTarget(
            name: "samesofa-itest",
            dependencies: ["SameSofaKit", "SameSofaCore", "WebRTC"]
        ),
        .testTarget(name: "SameSofaCoreTests", dependencies: ["SameSofaCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
