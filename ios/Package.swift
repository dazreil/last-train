// swift-tools-version: 6.0
import PackageDescription

/**
 * The native app's domain logic, as a package rather than as app source.
 *
 * IOS.md §9 step 4 is explicit about the order: "Service-day logic and its tests
 * first, then pickers, then the result stack, then the design system." A package is
 * what makes that order possible — the rules that decide which train is the last one
 * are proved before anything needs a view, a simulator, or a design.
 *
 * `LastTrainCore` imports Foundation and nothing else. No SwiftUI, no UIKit, so it
 * builds for iOS and for the Mac running the tests alike. The Xcode app project adds
 * this as a local package dependency.
 *
 * Run the tests with `TZ=UTC swift test`. The timezone is deliberate and matches
 * `npm test`: the bug these tests exist to prevent is invisible on a machine set to
 * London, because there the wrong answer and the right one are the same answer.
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
        .target(
            name: "LastTrainCore",
            // Written by `npm run national:data`, which emits the same bytes here and
            // to `data/national.json` for the API. Generated, never hand-maintained.
            resources: [.process("Resources/national.json")]
        ),
        .testTarget(name: "LastTrainCoreTests", dependencies: ["LastTrainCore"]),
    ]
)
