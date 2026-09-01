import SwiftUI

import LastTrainCore

/**
 Last Train.

 One question: what is the last train home, and if I miss it, what is the first one
 back. The app never asks where you are going — you pick where you *are* and which way
 you are heading, and it shows what leaves. That refusal is the product.

 Everything that decides an answer lives in `LastTrainCore`, which imports Foundation
 and nothing else and is covered by 68 tests. This target is views.
 */
@main
struct LastTrainApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    /// Surfaced rather than swallowed: an app with no stations cannot answer anything.
    @State private var bundleError: String?

    var body: some View {
        Group {
            if let bundleError {
                StationsMissingView(detail: bundleError)
            } else {
                BoardView()
            }
        }
        .task {
            do {
                try Stations.validate()
            } catch {
                bundleError = "\(error)"
            }
        }
    }
}

/**
 The station list failed to load.

 Only reachable if the bundled resource is missing or unreadable, which SwiftPM makes
 a build failure — so this is the belt to that braces. It says what is wrong and how to
 fix it rather than showing an empty picker with no explanation.
 */
struct StationsMissingView: View {
    let detail: String

    var body: some View {
        ZStack {
            CathodeBackdrop()
            VStack(alignment: .leading, spacing: Theme.Space.gutter) {
                Text("NO STATION LIST").cathodeSection(Theme.serviceBlueLit)
                Text("The bundled station list could not be read, so nothing can be looked up.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textDim)
                Text(detail)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Theme.Space.gutter)
        }
        .preferredColorScheme(.dark)
    }
}
