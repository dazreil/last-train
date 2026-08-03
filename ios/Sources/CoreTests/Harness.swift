import Foundation

/**
 A very small test harness.

 Stands in for XCTest, which is not available with the Command Line Tools alone —
 both it and swift-testing arrive with the full Xcode. The assertions are the part
 worth having, and they convert to XCTest methods mechanically once Xcode is
 installed; the point is not to wait for a download before proving that the last
 train of the night is the one the app says it is.

 Output deliberately mirrors `npm test`, so the two suites read the same way.
 */
final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0
    private var failuresInCurrentTest = 0
    private var currentName = ""

    func test(_ name: String, _ body: () -> Void) {
        currentName = name
        failuresInCurrentTest = 0
        body()
        if failuresInCurrentTest == 0 {
            passed += 1
            print("✔ \(name)")
        } else {
            failed += 1
        }
    }

    private func fail(_ message: String, _ file: StaticString, _ line: UInt) {
        if failuresInCurrentTest == 0 { print("✖ \(currentName)") }
        failuresInCurrentTest += 1
        let shortFile = URL(fileURLWithPath: "\(file)").lastPathComponent
        print("    \(message)  [\(shortFile):\(line)]")
    }

    func expect<T: Equatable>(
        _ actual: T?,
        _ expected: T?,
        _ note: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard actual != expected else { return }
        let suffix = note.isEmpty ? "" : " — \(note)"
        fail(
            "expected \(expected.map { "\($0)" } ?? "nil"), got \(actual.map { "\($0)" } ?? "nil")\(suffix)",
            file, line
        )
    }

    func expectTrue(
        _ value: Bool,
        _ note: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard !value else { return }
        fail("expected true\(note.isEmpty ? "" : " — \(note)")", file, line)
    }

    func expectNotEqual<T: Equatable>(
        _ a: T?,
        _ b: T?,
        _ note: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard a == b else { return }
        fail("expected values to differ, both were \(a.map { "\($0)" } ?? "nil")\(note.isEmpty ? "" : " — \(note)")", file, line)
    }

    /// Prints the tally and returns the exit code.
    func finish() -> Int32 {
        print("")
        print("ℹ tests \(passed + failed)")
        print("ℹ pass  \(passed)")
        print("ℹ fail  \(failed)")
        return failed == 0 ? 0 : 1
    }
}

// MARK: - Fixtures

/**
 An absolute instant, written as UTC.

 Test inputs that stand for "now" are always written this way, with the London time
 they correspond to in a comment, because those two differing by an hour through BST
 is the entire reason this file exists.
 */
func utcInstant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: iso) else {
        preconditionFailure("bad fixture instant: \(iso)")
    }
    return date
}

/// Renders an instant back to UTC ISO, for asserting what a London string resolved to.
func utcString(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}
