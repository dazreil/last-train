import Foundation
import Testing

import LastTrainCore

/**
 Telling a cancelled request apart from a failed one.

 The bug this exists to prevent cost a session's diagnosis. `URLSession` reports
 cancellation as an ordinary thrown error, so the blanket `catch` mapped it to
 `.unreachable` — *"Could not reach the server. Are you online?"* — for a request the app
 itself had called off. The server had answered; only the answer was discarded. The
 message sent the investigation to the network, the base URL and the deployment, and the
 cause was in none of them.

 The trigger was a view keyed on state its own lookup wrote, so the task cancelled itself
 on first use. That is fixed where it belongs, in `FastModel`; this pins the half that
 made it unreadable, which is one blanket `catch` too many.
 */
@Suite("Transport failure")
struct TransportFailureTests {

    private let deployed = BoardClient(baseURL: URL(string: "https://example.invalid")!)
    private let local = BoardClient(baseURL: URL(string: "http://localhost:3000")!)

    @Test("a cancelled request is not a failure to report")
    func cancellationStaysCancellation() {
        #expect(deployed.transportFailure(URLError(.cancelled)) is CancellationError)
        #expect(deployed.transportFailure(CancellationError()) is CancellationError)
    }

    /// Cancellation is cancellation wherever it is pointed. A dev-server message for a
    /// request nobody was waiting for would be just as misleading as the network one.
    @Test("cancellation is not dressed as a missing dev server either")
    func cancellationBeatsLoopback() {
        #expect(local.transportFailure(URLError(.cancelled)) is CancellationError)
    }

    @Test("a genuine transport failure still says the server could not be reached")
    func realFailureSurvives() {
        let failure = deployed.transportFailure(URLError(.notConnectedToInternet))
        #expect(failure as? BoardClientError == .unreachable)
    }

    /// The distinction `devServerDown` exists to make, unchanged by any of this.
    @Test("a genuine failure against loopback still names the dev server")
    func loopbackFailureSurvives() {
        let failure = local.transportFailure(URLError(.cannotConnectToHost))
        #expect(failure as? BoardClientError == .devServerDown("localhost:3000"))
    }
}
