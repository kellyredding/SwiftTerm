// swift-tools-version:5.9

import PackageDescription

// Sub-package that verifies the parent SwiftTerm fork still exposes
// the API surface Galactic depends on. Depends on the parent via
// relative path so it always tests the latest fork state, not a
// pinned version.
//
// To run from the fork root:
//
//     cd GalacticApiSmoke && swift test
//
// This sub-package builds only against the final state of the 4-commit
// main branch (where upstream + Galactic patches are both present).
// At intermediate commits in `main`'s history (e.g., before the
// upstream import lands), the parent package has no SwiftTerm sources
// and this sub-package won't build. That's expected — see MAINTAINING.md.
let package = Package(
    name: "GalacticApiSmoke",
    platforms: [
        .iOS(.v14),
        .macOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    dependencies: [
        .package(path: "../")
    ],
    targets: [
        .testTarget(
            name: "GalacticApiSmokeTests",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Tests/GalacticApiSmokeTests"
        )
    ]
)
