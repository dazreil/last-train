import SwiftUI

import LastTrainCore

/// A compact railway-direction selector. The selected direction reads like a lit panel;
/// unavailable directions remain named so the absence of service is still explicit.
struct DirectionControl: View {
    let available: Set<Compass>
    let towards: [Compass: String]
    @Binding var selection: Compass
    var onTap: ((Compass) -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 7), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if typeSize.isAccessibilitySize {
                Menu {
                    ForEach(Compass.allCases, id: \.self) { direction in
                        Button {
                            selection = direction
                            onTap?(direction)
                        } label: {
                            Label(
                                direction.rawValue.capitalized,
                                systemImage: direction == selection ? "checkmark" : symbol(for: direction)
                            )
                        }
                        .disabled(!available.isEmpty && !available.contains(direction))
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: selection))
                        Text(selection.rawValue.capitalized)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.serviceBlue.opacity(0.78))
                    .overlay(Rectangle().stroke(Theme.serviceBlueLit, lineWidth: 1))
                }
                .accessibilityLabel("Direction")
                .accessibilityValue(selection.rawValue.capitalized)
            } else {
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(Compass.allCases, id: \.self) { direction in
                        directionButton(direction)
                    }
                }
            }

            Text(towards[selection].map { "Towards \($0.withoutLondonPrefix)" } ?? "No service this way")
                .font(Theme.Font.meta)
                .foregroundStyle(towards[selection] == nil ? Theme.textFaint : Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .padding(.horizontal, Theme.Space.gutter)
    }

    private func directionButton(_ direction: Compass) -> some View {
        let selected = direction == selection
        let isAvailable = available.isEmpty || available.contains(direction)

        return Button {
            selection = direction
            onTap?(direction)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol(for: direction))
                    .font(.caption.weight(.bold))
                Text(direction.rawValue)
                    .font(Theme.Font.label)
                    .tracking(Theme.tracking)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(selected ? Theme.paper : isAvailable ? Theme.textDim : Theme.textFaint.opacity(0.55))
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                if selected {
                    LinearGradient(
                        colors: [Theme.serviceBlueLit.opacity(0.75), Theme.serviceBlue.opacity(0.76)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Theme.control.opacity(isAvailable ? 0.58 : 0.18)
                }
            }
            .overlay(Rectangle().stroke(selected ? Theme.serviceBlueLit : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressLift())
        .accessibilityLabel(direction.rawValue.capitalized)
        .accessibilityValue(accessibilityValue(direction, available: isAvailable, selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func symbol(for direction: Compass) -> String {
        switch direction {
        case .north: "arrow.up"
        case .east: "arrow.right"
        case .south: "arrow.down"
        case .west: "arrow.left"
        }
    }

    private func accessibilityValue(_ direction: Compass, available: Bool, selected: Bool) -> String {
        var parts: [String] = []
        if selected { parts.append("selected") }
        if let destination = towards[direction] { parts.append("towards \(destination)") }
        if !available { parts.append("no service") }
        return parts.joined(separator: ", ")
    }
}
