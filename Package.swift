// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ElementCall",
    platforms: [.iOS(.v18)],
    products: [
        // One dependency and one import for a host that wants all of it, under the name a host
        // reaches for first. The four below stay published: the split is what SwiftLint enforces
        // the module boundaries against, and a host wanting only the media layer should not have to
        // link the view layer to get it.
        .library(name: "ElementCall", targets: ["ElementCall"]),
        .library(name: "ElementCallKit", targets: ["ElementCallKit"]),
        .library(name: "ElementCallHost", targets: ["ElementCallHost"]),
        .library(name: "ElementCallUI", targets: ["ElementCallUI"]),
        .library(name: "ElementCallMatrix", targets: ["ElementCallMatrix"])
    ],
    dependencies: [
        .package(url: "https://github.com/element-hq/matrix-rust-rtc", exact: "0.3.0-rc.2"),
        // .package(path: "../matrix-rust-rtc"),
        // The design *tokens*, not the Compound component library. Tokens are static values in
        // their own small package, so depending on them is safe. Compound itself is not, because its
        // colours live on a shared instance a host re-brands at runtime: a second copy linked in
        // here would never see that override, and a re-branded host would get a stock call screen.
        // The host still supplies the real colours through ElementCallThemeProtocol; these are the default.
        //
        // A range, for the same reason the SDK below is one: the host links these tokens too, through
        // Compound, so an exact pin here forces the host's Compound onto our version. It was exact at
        // 10.2.4 until compound-ios moved to 11.0.0, and element-x-ios then could not resolve at all —
        // two exact requirements on one package have no solution, and the failure lands before anything
        // compiles. The upper bound is absurd on purpose; CI builds whatever Package.resolved holds.
        .package(url: "https://github.com/element-hq/compound-design-tokens", "11.0.0" ..< "100.0.0"),
        // Use the same Letro SDK source and reviewed version as the host. It
        // preserves Letro upload, room-marker and verification diagnostic APIs.
        .package(url: "https://git.postnumber.com/letro/matrix-rust-components-swift", exact: "26.09.22-letro.1"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.4")
    ],
    targets: [
        .target(name: "ElementCallKit",
                dependencies: [.product(name: "MatrixRtc", package: "matrix-rust-rtc")],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .target(name: "ElementCallHost",
                dependencies: ["ElementCallKit",
                               .product(name: "CompoundDesignTokens", package: "compound-design-tokens")],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .target(name: "ElementCallUI",
                dependencies: ["ElementCallHost"],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        // The only module allowed to know the Matrix SDK exists. Everything a host would otherwise
        // have to implement for itself lives here, so a host supplies a Client and nothing more.
        .target(name: "ElementCallMatrix",
                dependencies: ["ElementCallKit",
                               "ElementCallHost",
                               .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift")],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        // Nothing but re-exports, and it holds the bare name so that a host's one import reads as
        // the package. ElementCallUI and ElementCallMatrix already pull in the other two, but all
        // four are named so that dropping one of those edges later cannot silently shrink what the
        // umbrella offers.
        .target(name: "ElementCall",
                dependencies: ["ElementCallKit",
                               "ElementCallHost",
                               "ElementCallUI",
                               "ElementCallMatrix"],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "ElementCallTests",
                    dependencies: ["ElementCall",
                                   "ElementCallUI",
                                   "ElementCallMatrix",
                                   .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
                    exclude: ["__Snapshots__"],
                    swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
