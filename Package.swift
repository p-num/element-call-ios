// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ElementCall",
    // The language every string is written in, in Localazy, and the one a lookup falls back to.
    defaultLocalization: "en",
    platforms: [.iOS(.v18)],
    products: [
        // One dependency and one import for a host that wants all of it, under the name a host
        // reaches for first. The three below stay published: the split is what SwiftLint enforces
        // the module boundaries against, and a host wanting only the media layer should not have to
        // link the view layer to get it.
        .library(name: "ElementCall", targets: ["ElementCall"]),
        .library(name: "ElementCallKit", targets: ["ElementCallKit"]),
        .library(name: "ElementCallHost", targets: ["ElementCallHost"]),
        .library(name: "ElementCallUI", targets: ["ElementCallUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/p-num/matrix-rust-rtc", exact: "0.5.0-rc.9-letro.1"),
        // .package(path: "../matrix-rust-rtc"),
        // The design *tokens*, not the Compound component library. Tokens are static values in
        // their own small package, so depending on them is safe. Compound itself is not, because its
        // colours live on a shared instance a host re-brands at runtime: a second copy linked in
        // here would never see that override, and a re-branded host would get a stock call screen.
        // The host still supplies the real colours through ElementCallThemeProtocol; these are the default.
        //
        // A range, because the host links these tokens too, through Compound, so an exact pin here
        // forces the host's Compound onto our version. It was exact at 10.2.4 until compound-ios moved
        // to 11.0.0, and element-x-ios then could not resolve at all — two exact requirements on one
        // package have no solution, and the failure lands before anything compiles. The upper bound
        // is absurd on purpose; CI builds whatever Package.resolved holds.
        .package(url: "https://github.com/element-hq/compound-design-tokens", "11.0.0" ..< "100.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.4")
    ],
    targets: [
        .target(name: "ElementCallKit",
                dependencies: [.product(name: "MatrixRtc", package: "matrix-rust-rtc")],
                // Copied rather than processed: the files are Element Call web's, byte for byte, and
                // Sounds/README.md pins them by hash.
                resources: [.copy("Sounds")],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        // The core's bindings directly as well as through the Kit: the stack takes the core's own
        // MatrixBackend, which the host implements, and the fakes implement it too.
        .target(name: "ElementCallHost",
                dependencies: ["ElementCallKit",
                               .product(name: "MatrixRtc", package: "matrix-rust-rtc"),
                               .product(name: "CompoundDesignTokens", package: "compound-design-tokens")],
                // The call screen's strings, downloaded from Localazy by scripts/download-strings.sh.
                // Here rather than in the UI because ElementCallStrings, whose defaults they are, is a port.
                resources: [.process("Resources")],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .target(name: "ElementCallUI",
                dependencies: ["ElementCallHost"],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        // Nothing but re-exports, and it holds the bare name so that a host's one import reads as
        // the package. ElementCallUI already pulls in the other two, but all three are named so that
        // dropping one of those edges later cannot silently shrink what the umbrella offers. The
        // core's bindings are re-exported too, because a host implements the core's MatrixBackend.
        .target(name: "ElementCall",
                dependencies: ["ElementCallKit",
                               "ElementCallHost",
                               "ElementCallUI",
                               .product(name: "MatrixRtc", package: "matrix-rust-rtc")],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "ElementCallTests",
                    dependencies: ["ElementCall",
                                   "ElementCallUI",
                                   .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
                    exclude: ["__Snapshots__"],
                    // The layout scenarios, vendored from feature-hq (plans/003.call_layout/scenarios).
                    // Copied rather than processed so a file keeps its name and a dump can quote it.
                    resources: [.copy("Scenarios")],
                    swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
