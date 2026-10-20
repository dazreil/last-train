import SwiftUI

import LastTrainCore

extension BoardView {
    /// The date stepper (Last) and the page stepper (Fast), named the way the main design
    /// names them: three slots — the way back, where you are, and where the next tap lands.
    /// Days read Today · Wed · Thurs; pages read 1st · 2nd · 3rd.
    @ViewBuilder
    var dayControl: some View {
        HStack(alignment: .center, spacing: 7) {
            dayPagerSlots
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    var dayPagerSlots: some View {
        switch mode {
        case .last:
            if model.dayIndex > 0 && !model.stepWrapsToToday { todayButton }
            stepLabel(model.dayIndex == 0
                ? "Today"
                : ServiceDay.formatWeekday(model.shownDate) ?? "")
            stepButton(
                label: model.stepWrapsToToday
                    ? "Today"
                    : ServiceDay.formatWeekday(model.date(atStep: model.dayIndex + 1) ?? "") ?? "",
                action: { model.stepForward() },
                accessibility: model.stepWrapsToToday ? "Back to today" : "Show the next day",
                value: ServiceDay.formatServiceDate(model.shownDate) ?? ""
            )
        case .fast:
            if !fast.isOnFirstPage && !fast.pageWrapsToNow { nowButton }
            stepLabel(Self.pageName(fast.page))
            stepButton(
                label: fast.pageWrapsToNow ? Self.pageName(0) : Self.pageName(fast.page + 1),
                // The later window loads itself on reaching the last page; while it does, hold
                // the step so a tap cannot wrap out from under the trains about to arrive.
                action: { if !fast.isLoadingLater { fast.advance() } },
                accessibility: fast.pageWrapsToNow ? "Back to the first three trains" : "Show the next three trains",
                value: "Page \(fast.page + 1) of \(fast.pageCount)"
            )
        }
    }

    /**
     Pages count themselves: 1st, 2nd, 3rd.

     They used to read Now · Two · Three, which mixed a position with a time and then
     needed a special case the moment the board rolled on to tomorrow — where nothing
     departs "now" and the word contradicted the heading above it. An ordinal says only
     where you are in the list, which is true on a live board and a next-day one alike.
     */
    static func pageName(_ index: Int) -> String {
        let n = index + 1
        let suffix: String
        // 11th, 12th and 13th break the units rule and are the usual bug here, so they
        // are excluded before it is applied rather than after.
        if (11...13).contains(n % 100) {
            suffix = "th"
        } else {
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    /// The middle slot: where you are, and not a control.
    /**
     One word in the day or page row, set exactly as a direction is.

     The two rows sit one above the other and were reading at different sizes in
     different colours, which made them look like different kinds of control rather than
     the same one asked twice. Lit blue means the same thing here as it does there: this
     is the one you are on.
     */
    func stepText(_ text: String, lit: Bool) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .tracking(Theme.tracking)
            .textCase(.uppercase)
            .foregroundStyle(lit ? Theme.serviceBlueLit : Theme.textDim)
            .fixedSize(horizontal: true, vertical: false)
    }

    func stepLabel(_ text: String) -> some View {
        stepText(text, lit: true)
            .padding(.vertical, 4)
    }

    /// The right slot: named rather than a bare chevron — a name says what the tap does.
    func stepButton(
        label: String,
        action: @escaping () -> Void,
        accessibility: String,
        value: String? = nil
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                stepText(label, lit: false)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .accessibilityLabel(accessibility)
        .accessibilityValue(value ?? "")
    }

    /// The way back to the start, worn as a pill so it reads the same in either mode.
    var todayButton: some View {
        Button { model.returnToToday() } label: { wayBackLabel("Today") }
            .buttonStyle(PressLift())
            .accessibilityLabel("Back to today")
    }

    var nowButton: some View {
        Button { fast.now() } label: { wayBackLabel(Self.pageName(0)) }
            .buttonStyle(PressLift())
            .accessibilityLabel("Back to the trains from now")
    }

    func wayBackLabel(_ text: String) -> some View {
        stepText(text, lit: false)
            .padding(.vertical, 4)
    }
}
