// swift-tools-version:5.9
// The macOS GUI of nice-dns: a client of `nice-dns status --tsv`
// (docs/cli-contract.md) and of the shared action table (gui/share/actions.tsv).
import PackageDescription

let package = Package(
    name: "NiceDNS",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NiceDNSGUI", targets: ["NiceDNSGUI"]),
        .executable(name: "KitCheck", targets: ["KitCheck"]),
    ],
    targets: [
        // The status parser, the command runner and the action table. The
        // table is a committed copy of gui/share/actions.tsv: `make strings`
        // refreshes it, `make strings-check` and KitCheck fail on drift.
        .target(
            name: "NiceDNSKit",
            resources: [.copy("Resources/actions.tsv")]
        ),
        .executableTarget(
            name: "NiceDNSGUI",
            dependencies: ["NiceDNSKit"]
        ),
        // The portable verifier: Command Line Tools ship no XCTest.
        .executableTarget(
            name: "KitCheck",
            dependencies: ["NiceDNSKit"],
            path: "Tests/KitCheck"
        ),
        .testTarget(
            name: "NiceDNSKitTests",
            dependencies: ["NiceDNSKit"]
        ),
    ]
)
