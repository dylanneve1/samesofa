// swift-tools-version:5.10
import PackageDescription

// WebRTC's audio processing module, built by scripts/build-apm.sh.
let apm = "\(Context.packageDirectory)/Vendor/APM"

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
        // C wrapper for MTAudioProcessingTapCreate.
        .target(name: "CAudioTap", linkerSettings: [.linkedFramework("MediaToolbox")]),
        // C interface to the echo canceller (WebRTC AEC3 from webrtc-audio-processing,
        // BSD-3-Clause; static library built by scripts/build-apm.sh).
        .target(
            name: "CEchoCanceller",
            cxxSettings: [
                .unsafeFlags(["-I\(apm)/include"]),
                .define("WEBRTC_POSIX"), .define("WEBRTC_MAC"), .define("WEBRTC_LIBRARY_IMPL"),
                // The library is built without debug checks; its headers must agree.
                .define("NDEBUG"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(apm)/lib"]),
                .linkedLibrary("samesofa-apm"),
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Calls, file transfer, playback and audio. Shared by the app and the integration test.
        .target(
            name: "SameSofaKit",
            dependencies: [
                "SameSofaCore",
                "CWebRTCAudioDevice",
                "CAudioTap",
                "CEchoCanceller",
                "WebRTC",
            ]
        ),
        .executableTarget(
            name: "SameSofa",
            dependencies: ["SameSofaKit", "SameSofaCore", "WebRTC"]
        ),
        .executableTarget(
            name: "samesofa-itest",
            dependencies: ["SameSofaKit", "SameSofaCore", "CEchoCanceller", "WebRTC"]
        ),
        .testTarget(name: "SameSofaCoreTests", dependencies: ["SameSofaCore"]),
    ],
    swiftLanguageVersions: [.v5],
    cxxLanguageStandard: .cxx17
)
