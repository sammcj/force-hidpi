// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ForceHiDPI",
  platforms: [.macOS(.v14)],
  targets: [
    .target(
      name: "CPrivateAPI",
      path: "Sources/CPrivateAPI",
      publicHeadersPath: "include"
    ),
    .executableTarget(
      name: "ForceHiDPI",
      dependencies: ["CPrivateAPI"],
      path: "Sources/ForceHiDPI",
      linkerSettings: [
        .linkedFramework("IOKit")
      ]
    ),
  ]
)
