// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// Production release binary.
// These are generated by CI, and you verify the code used to generate this, and the checksum result
// on our GH actions https://github.com/CriticalMoments/CriticalMoments/actions
var appcoreTarget = Target.binaryTarget(
    name: "Appcore",
    url: "https://github.com/CriticalMoments/CriticalMoments/releases/download/appcore-v0.8.0-beta/Appcore.xcframework.zip",
    checksum: "45ee96b2143ef9fe38d1bc47f5b8464f7fed5a9371b5a5b59b51dec39a059b4f")

// If this device has built the appcore framework locally, use that. This is primarily for development.
// We highly recommend end users use the production binary.
// If you don't trust the precompiled binaries, you can verify the checksums/source from Github release action logs which built it https://github.com/CriticalMoments/CriticalMoments/actions.
// Building yourself should work, but requires additional tooling (golang) and we don't offer support for this flow.
let filePath = #filePath
let endOfPath = filePath.count - "Package.swift".count - 1
let dirPath = String(filePath[...String.Index.init(utf16Offset: endOfPath, in: filePath)])
let infoPath = dirPath + "go/appcore/build/Appcore.xcframework/Info.plist"
if (FileManager.default.fileExists(atPath: infoPath))
{
    print("Using Local Appcore Build From: " + infoPath);
    appcoreTarget = Target.binaryTarget(
        name: "Appcore",
        path: "go/appcore/build/Appcore.xcframework")
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
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CriticalMoments",
            dependencies: ["Appcore"],
            path: "ios/Sources/CriticalMoments",
            publicHeadersPath:"include",
            cSettings: [
                .unsafeFlags([
                    "-Werror=return-type",
                    "-Werror=unused-variable",
                    "-Werror"
                ]),
            ]),
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
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
