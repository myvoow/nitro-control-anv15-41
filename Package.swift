// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NitroControl",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CNitroWMI", path: "Sources/CNitroWMI"),
        .target(
            name: "NitroKit",
            dependencies: ["CNitroWMI"],
            path: "Sources/NitroKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "nitrocontrold",
            dependencies: ["NitroKit"],
            path: "Sources/nitrocontrold",
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(name: "nitroctl", dependencies: ["NitroKit"], path: "Sources/nitroctl"),
        .executableTarget(name: "NitroControl", dependencies: ["NitroKit"], path: "Sources/NitroControl"),
    ]
)
