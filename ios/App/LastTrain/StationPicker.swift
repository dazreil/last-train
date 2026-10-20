import SwiftUI

import LastTrainCore

struct StationPicker: View {
    @Binding var selection: Station?
    /// The stations found near you, if you asked. Shown as a section above search until
    /// you start typing, so nearby lives in the picker rather than as chips on the board.
    var nearby: [Nearby<Station>] = []
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Whether the search box is active, with the keyboard up.
    @State private var searching = false

    var body: some View {
        NavigationStack {
            ZStack {
                CathodeBackdrop()
                List {
                    if query.isEmpty && !nearby.isEmpty {
                        Section {
                            ForEach(nearby, id: \.station.crs) { candidate in
                                row(candidate.station, trailing: candidate.distanceLabel, colour: Theme.textDim)
                            }
                        } header: {
                            Text("Nearby").font(Theme.Font.meta).foregroundStyle(Theme.textDim)
                        }
                    }
                    if !matches.isEmpty {
                        Section {
                            ForEach(matches, id: \.crs) { station in
                                row(station, trailing: station.crs, colour: Theme.serviceBlueLit)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            .task {
                // With no nearby list, typing is the only thing to do here, so start with
                // the keyboard up. With one, leave the list in view to tap. The search box
                // ignores the change while the sheet is still sliding up, so wait for that.
                guard nearby.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(350))
                searching = true
            }
            .searchable(text: $query, isPresented: $searching, prompt: "Station or code")
            .navigationTitle("From")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Same way out the destination picker has. Without it, opening this by
                // mistake left no exit but choosing a station you did not want.
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ station: Station, trailing: String, colour: Color) -> some View {
        Button {
            selection = station
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name).font(Theme.Font.destination).foregroundStyle(Theme.text)
                    if let locality = station.locality {
                        Text(locality).font(Theme.Font.meta).foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer(minLength: 0)
                Text(trailing).font(Theme.Font.meta.monospaced()).foregroundStyle(colour)
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Theme.surface.opacity(0.62))
    }

    private var matches: [Station] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return Stations.all
            .compactMap { station -> (Station, Int)? in
                let name = station.name.lowercased()
                if station.crs.lowercased() == needle { return (station, 0) }
                if name == needle { return (station, 1) }
                if name.hasPrefix(needle) { return (station, 2) }
                if name.contains(needle) { return (station, 3) }
                return nil
            }
            .sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
            .prefix(60)
            .map(\.0)
    }
}
