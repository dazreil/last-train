import SwiftUI

import LastTrainCore

/**
 Watch this train.

 The one thing a board row offers besides opening it. What watching *does* differs by
 board — the Dynamic Island on Fast Train, the lock-screen widget on Last — but the pill
 is identical, so the gesture is learned once and works on both. The pill knows nothing
 about islands or widgets; it runs the closure the board hands it.

 Its own button, never nested inside the row's open tap, so following a train and reading
 its detail are two gestures that cannot be mistaken for each other.
 */
struct FollowPill: View {
    let isOn: Bool
    let colour: Color
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView().controlSize(.mini).tint(isOn ? Theme.ink : colour)
                } else {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "wave.3.right")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(isOn ? "Following" : "Follow")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(isOn ? Theme.ink : colour)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isOn ? colour : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(colour.opacity(isOn ? 0 : 0.5), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressDim())
        .disabled(isBusy)
        .accessibilityLabel(isOn ? "Following this train" : "Follow this train")
    }
}

/**
 The little a detail sheet needs, produced by either board's row.

 Last Train rows are `BoardDeparture`, Fast Train rows are `FastService`; both carry the
 fields the sheet reads and a `serviceId`, which is all the calling-points fetch needs. So
 one sheet serves both, fed through this rather than two sheets left to drift apart.
 */
struct SheetService: Identifiable {
    let serviceId: String
    let dep: String
    let destination: String
    let tocName: String
    let platform: String?
    let isReplacementBus: Bool
    let headcode: String?
    /// Named under the time when set — "Last train", "Following".
    let topLabel: String?
    /// Red numerals for the train that leads its board, else service blue.
    let isRed: Bool

    var id: String { serviceId }
}
