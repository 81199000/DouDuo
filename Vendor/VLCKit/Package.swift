// swift-tools-version: 5.7
import PackageDescription

// VLCKit（MobileVLCKit 3.6.0，来自 tylerjonesio/vlckit-spm）。
// 二进制太大（约 1GB）不进 git：首次编译前跑 `./scripts/fetch-vlckit.sh` 下载到本目录。
let package = Package(
    name: "VLCKit",
    platforms: [.iOS(.v11)],
    products: [.library(name: "VLCKitSPM", targets: ["VLCKitSPM"])],
    targets: [
        .binaryTarget(name: "VLCKit-all", path: "VLCKit-all.xcframework"),
        .target(
            name: "VLCKitSPM",
            dependencies: [.target(name: "VLCKit-all")],
            linkerSettings: [
                .linkedFramework("QuartzCore"), .linkedFramework("CoreText"), .linkedFramework("AVFoundation"),
                .linkedFramework("Security"), .linkedFramework("CFNetwork"), .linkedFramework("AudioToolbox"),
                .linkedFramework("OpenGLES"), .linkedFramework("CoreGraphics"), .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"), .linkedLibrary("c++"), .linkedLibrary("xml2"), .linkedLibrary("z"),
                .linkedLibrary("bz2"), .linkedLibrary("iconv"),
            ]),
    ]
)
