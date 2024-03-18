// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// Production release binary.
// These are generated by CI, and you verify the code used to generate this, and the checksum result
// on our GH actions https://github.com/CriticalMoments/CriticalMoments/actions
var appcoreTarget = Target.binaryTarget(
    name: "Appcore",
    url: "https://github.com/CriticalMoments/CriticalMoments/releases/download/appcore-v0.9.1/Appcore.xcframework.zip",
    checksum: "676252f7cb288caa2cb99df03e413f02a7e42ec221e3f621fbea18e069f29808")

// If this device has built the appcore framework locally, use that. This is primarily for development.
// We highly recommend end users use the production binary.
// If you don't trust the precompiled binaries, you can verify the checksums/source from Github release action logs which built it https://github.com/CriticalMoments/CriticalMoments/actions.
// Building yourself should work, but requires additional tooling (golang) and we don't offer support for this flow.
let filePath = #filePath
let endOfPath = filePath.count - "Package.swift".count - 1
let dirPath = String(filePath[...String.Index.init(utf16Offset: endOfPath, in: filePath)])
let infoPath = dirPath + "go/appcore/build/Appcore.xcframework/Info.plist"

var cmTarget = Target.target(name: "CriticalMoments",
                             dependencies: ["Appcore"],
                             path: "ios/Sources/CriticalMoments",
                             publicHeadersPath:"include")

if (FileManager.default.fileExists(atPath: infoPath))
{
    print("Using Local Appcore Build From: " + infoPath);
    appcoreTarget = Target.binaryTarget(
        name: "Appcore",
        path: "go/appcore/build/Appcore.xcframework")

    // For local development, increase error checking level.
    // Unsafe flags are not allowed with SPM distribution
    // but CI will still check these compile time errors.
    cmTarget.cSettings = [
        .unsafeFlags(["-Werror=return-type",
                     "-Werror=unused-variable",
                     "-Werror"]),
    ]
}

let package = Package(
    name: "CriticalMoments",
    platforms: [.iOS(.v12)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "CriticalMoments",
            targets: ["CriticalMoments"]),
    ],
    targets: [
        cmTarget,
        appcoreTarget,
        .testTarget(
            name: "CriticalMomentsTests",
            dependencies: ["CriticalMoments"],
            path: "ios/Tests/CriticalMomentsTests",
            resources: [
                .copy("TestResources")
            ],
            cSettings: [
                .headerSearchPath("../../Sources/CriticalMoments"),
                .define("IS_CRITICAL_MOMENTS_INTERNAL", to:"1")
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
