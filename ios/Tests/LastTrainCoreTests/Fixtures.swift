import Foundation

/**
 An absolute instant, written as UTC.

 Test inputs standing for "now" are always written this way, with the London time
 they correspond to in a comment, because those two differing by an hour through BST
 is the entire reason these tests exist.
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
