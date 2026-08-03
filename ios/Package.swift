// swift-tools-version: 6.0
import PackageDescription

/**
 * The native app's domain logic, as a package rather than as app source.
 *
 * IOS.md §9 step 4 is explicit about the order: "Service-day logic and its tests
 * first, then pickers, then the result stack, then the design system." A package is
 * what makes that order possible — this builds and runs with the Swift toolchain
 * alone, so the rules that decide which train is the last one are proved before
 * anything needs Xcode, a simulator, or a view.
 *
 * `LastTrainCore` imports Foundation and nothing else. No SwiftUI, no UIKit. The
 * Xcode app project, when it exists, adds this as a local package dependency.
 *
 * ## Why the tests are an executable
 *
 * Neither `XCTest` nor `swift-testing` ships with the Command Line Tools — both
 * arrive with the full Xcode. Rather than wait, `CoreTests` is an ordinary
 * executable with a small assertion harness: `swift run CoreTests` prints the same
 * tick-per-test output as `npm test` and exits non-zero on failure. The assertions
 * are the valuable part and they port to XCTest mechanically once Xcode is
 * installed, which it must be before any of this can become an app.
 */
let package = Package(
    name: "LastTrain",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LastTrainCore", targets: ["LastTrainCore"]),
    ],
    targets: [
        .target(name: "LastTrainCore"),
        .executableTarget(name: "CoreTests", dependencies: ["LastTrainCore"]),
    ]
)
