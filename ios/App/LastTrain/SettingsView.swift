import SwiftUI

import LastTrainCore

/**
 The journey the app opens on, when you have chosen one.

 Without it the app opens wherever it was left, which is right for someone who checks one
 journey and wrong the morning after checking a friend's. With it, every launch lands on
 your own last train home, whatever you looked at in between.

 A station **and** a direction, because the board is the pair: a station alone would open
 on whichever direction was last used there, which is the problem this exists to remove.
 Set from the board on screen rather than chosen from a list, so a home can only ever be a
 direction that has trains.

 App-only defaults: the widget has its own configuration and never reads this.
 */
struct HomeJourney: Equatable {
    let station: Station
    let direction: Compass

    private enum Key {
        static let crs = "lastTrain.home.station"
        static let direction = "lastTrain.home.direction"
    }

    static var current: HomeJourney? {
        let defaults = UserDefaults.standard
        guard let station = defaults.string(forKey: Key.crs).flatMap(Stations.find),
              let direction = defaults.string(forKey: Key.direction).flatMap(Compass.init(rawValue:))
        else { return nil }
        return HomeJourney(station: station, direction: direction)
    }

    static func store(_ home: HomeJourney?) {
        let defaults = UserDefaults.standard
        defaults.set(home?.station.crs, forKey: Key.crs)
        defaults.set(home?.direction.rawValue, forKey: Key.direction)
    }

    var label: String { "\(station.name) · \(direction.rawValue.capitalized)" }
}

/**
 Settings: your home journey, the credits, and what the app is.

 The credits live here rather than under the board. The board has to fit one screen, and
 a footer that pushes it into scrolling was costing the thing the app exists for. RTT's
 terms ask for a credit that is "clearly visible" with a link (API terms §5.1); this page
 is one tap from every screen, by the gear in the masthead. Confirm with RTT in writing
 before submission — see `STATUS.md`.
 */
struct SettingsView: View {
    /// The board on screen, offered as the home journey. Nil when there is no station or
    /// no direction chosen yet, so there is nothing to offer.
    let current: HomeJourney?

    @Environment(\.dismiss) private var dismiss
    @State private var home = HomeJourney.current

    var body: some View {
        NavigationStack {
            ZStack {
                CathodeBackdrop()
                List {
                    homeSection
                    creditsSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Home

    private var homeSection: some View {
        Section {
            HStack {
                Text("Opens on")
                Spacer(minLength: 12)
                Text(home?.label ?? "Where you left it")
                    .foregroundStyle(home == nil ? Theme.textFaint : Theme.textDim)
                    .multilineTextAlignment(.trailing)
            }
            .listRowBackground(rowBackground)

            if let current, current != home {
                Button("Make \(current.label) home") {
                    HomeJourney.store(current)
                    home = current
                }
                .listRowBackground(rowBackground)
            }

            if home != nil {
                // Not `role: .destructive`: that draws the button red, and red is the last
                // train and nothing else.
                Button("Clear home") {
                    HomeJourney.store(nil)
                    home = nil
                }
                .tint(Theme.textDim)
                .listRowBackground(rowBackground)
            }
        } header: {
            header("Home")
        } footer: {
            Text(home == nil
                 ? "Set a home and the app always opens on it. To choose one, open that station and direction on the board first."
                 : "The app opens here every time. The widget keeps its own setting.")
                .foregroundStyle(Theme.textFaint)
        }
    }

    // MARK: Credits

    private var creditsSection: some View {
        Section {
            credit(
                "Realtime Trains",
                url: "https://www.realtimetrains.co.uk",
                detail: "Last Train times"
            )
            credit(
                "National Rail Enquiries",
                url: "https://www.nationalrail.co.uk",
                detail: "Fast Train times and the timetable"
            )
            credit(
                "Office of Rail and Road",
                url: "https://www.orr.gov.uk",
                detail: "Popular destinations, 2024-25. Open Government Licence v3.0"
            )
        } header: {
            header("Data")
        }
    }

    private func credit(_ name: String, url: String, detail: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(Theme.Font.destination).foregroundStyle(Theme.text)
                    Text(detail).font(Theme.Font.meta).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.serviceBlueLit)
            }
            .padding(.vertical, 4)
        }
        .accessibilityHint("Opens \(name) in Safari")
        .listRowBackground(rowBackground)
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            fact("Trains shown", "Direct only")
            fact("Service day starts", ServiceDay.formatClock("03:00").spoken)
            fact("Version", version)
        } header: {
            header("About")
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Theme.textDim)
        }
        .listRowBackground(rowBackground)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: Shared

    private func header(_ text: String) -> some View {
        Text(text).font(Theme.Font.meta).foregroundStyle(Theme.textDim)
    }

    private var rowBackground: some View { Theme.surface.opacity(0.62) }
}
