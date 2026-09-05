import SwiftUI
import UIKit

import LastTrainCore

/// The Cathode Gauze visual system.
///
/// It keeps the product's original semantic palette: blue is an ordinary service and
/// red is the final service of the day. The visual depth comes from light, grid and
/// ghosted type, never from extra status colours.
enum Theme {
    static let ink = Color(hex: 0x05070a)
    static let surface = Color(hex: 0x0b0d10)
    static let raised = Color(hex: 0x11161d)
    static let control = Color(hex: 0x18202a)
    static let hairline = Color(hex: 0x29323d)

    static let controlLit = Color(hex: 0x3d4956)
    static let serviceBlueLit = Color(hex: 0x2d62d0)
    static let lastTrainRedLit = Color(hex: 0xff365a)

    static let text = Color(hex: 0xf2f5f8)
    static let textDim = Color(hex: 0x9aa7b4)
    static let textFaint = Color(hex: 0x65717d)

    static let serviceBlue = Color(hex: 0x012169)
    static let paper = Color(hex: 0xffffff)
    static let lastTrainRed = Color(hex: 0xe4002b)

    enum Font {
        static let time = SwiftUI.Font.system(.largeTitle, design: .monospaced).weight(.bold)
        static let heading = SwiftUI.Font.system(.title2, design: .rounded).weight(.semibold)
        static let destination = SwiftUI.Font.system(.headline, design: .rounded).weight(.semibold)
        static let body = SwiftUI.Font.system(.body, design: .rounded).weight(.medium)
        static let label = SwiftUI.Font.system(.caption2, design: .rounded).weight(.bold)
        static let meta = SwiftUI.Font.system(.caption, design: .rounded).weight(.semibold)
    }

    static let tracking: CGFloat = 1.8

    enum Space {
        static let gutter: CGFloat = 22
        static let blockGap: CGFloat = 0
        static let tap: CGFloat = 48
        static let section: CGFloat = 28
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

struct PressLift: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.08 : 0)
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct PressDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.52 : 1)
    }
}

/// Fine phosphor grid used behind every major surface. It is deliberately subtle: the
/// information remains crisp while the unlit field carries the approved gauze texture.
struct CathodeGauze: View {
    var tint: Color = Theme.serviceBlueLit
    var density: CGFloat = 12

    var body: some View {
        // The grid and phosphor texture were removed by request. Kept as a transparent
        // no-op so every call site — backdrops, rows, widgets, the Live Activity — still
        // composes and lays out unchanged, and the effect can be restored in one place.
        Color.clear
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Fine horizontal scanlines — the refined cathode surface that replaced the grid. Lines
/// only, never a mesh: the graph paper was the part that read as noise. Kept faint and
/// screen-blended so it lifts the black into lit glass without ever competing with a
/// numeral. This is the whole texture now.
struct CathodeScanlines: View {
    var spacing: CGFloat = 3

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            var path = Path()
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
        }
        .blendMode(.overlay)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct CathodeBackdrop: View {
    var tint: Color = Theme.serviceBlueLit

    var body: some View {
        ZStack {
            Theme.ink
            // The phosphor bloom: a soft column of light rising through the board, so the
            // dark glass reads as lit rather than merely black.
            RadialGradient(
                colors: [tint.opacity(0.17), tint.opacity(0.04), .clear],
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 6,
                endRadius: 380
            )
            CathodeScanlines()
            // Curvature: the edges fall away into the tube.
            RadialGradient(
                colors: [.clear, Theme.ink.opacity(0.82)],
                center: .center,
                startRadius: 90,
                endRadius: 440
            )
        }
        .ignoresSafeArea()
    }
}

/// A luminous machine-readable clock. The embedded OCR-A face gives timetable values
/// their distinctive hardware voice, while the offset copy retains the phosphor depth
/// of the approved visual system.
struct CathodeNumber: View {
    let text: String
    let colour: Color
    var scale: Scale = .row
    var alignment: Alignment = .leading

    enum Scale { case hero, row, compact }

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 112
    @ScaledMetric(relativeTo: .title) private var rowSize: CGFloat = 48
    @ScaledMetric(relativeTo: .headline) private var compactSize: CGFloat = 28

    private var size: CGFloat {
        switch scale {
        case .hero: min(heroSize, 148)
        case .row: min(rowSize, 72)
        case .compact: min(compactSize, 42)
        }
    }

    private var display: ServiceDay.ClockDisplay {
        ServiceDay.formatClock(text)
    }

    private var terminalFont: SwiftUI.Font {
        clockFont(size: size)
    }

    private var periodFont: SwiftUI.Font {
        clockFont(size: max(11, size * (scale == .hero ? 0.18 : 0.24)))
    }

    private func clockFont(size: CGFloat) -> SwiftUI.Font {
        guard UIFont(name: "WPOCRA-Regular", size: size) != nil else {
            return .system(size: size, weight: .medium, design: .monospaced)
        }
        return .custom("WPOCRA-Regular", fixedSize: size)
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: max(4, size * 0.045)) {
            ZStack(alignment: .leading) {
                terminalText
                    .foregroundStyle(colour.opacity(0.1))
                    .offset(x: max(1, size * 0.018), y: max(2, size * 0.045))
                    .blur(radius: max(0.8, size * 0.014))

                terminalText
                    .foregroundStyle(colour)
                    .shadow(color: colour.opacity(0.72), radius: scale == .hero ? 7 : 3)
                    .shadow(color: colour.opacity(0.26), radius: scale == .hero ? 18 : 8)
            }
            .layoutPriority(1)

            if let dayPeriod = display.dayPeriod {
                Text(dayPeriod)
                    .font(periodFont)
                    .tracking(size * 0.008)
                    .foregroundStyle(colour)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: scale == .hero ? .infinity : nil, alignment: alignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spoken)
    }

    /// The time, held to a constant width whatever the hour.
    ///
    /// A twelve-hour clock drops the leading zero — `5:23`, not `05:23` — so a single-digit
    /// hour is a glyph narrower than a two-digit one. Sized to fill its width, the narrower
    /// string was drawn larger, and the clock grew and shrank as the hour changed. An
    /// earlier fix padded with `\u{2007}` FIGURE SPACE, but WPOCRA has no such glyph: it fell
    /// back to a system space of the wrong width and merely indented the shorter times.
    ///
    /// A hidden widest-case string lays out the width instead. `88:88` reserves room for any
    /// `HH:MM`, and the real time is drawn over it, left-aligned — so every time sits in the
    /// same box at the same size, left edges lined up, with no glyph the face lacks.
    private var terminalText: some View {
        Text(verbatim: "88:88")
            .font(terminalFont)
            .monospacedDigit()
            .tracking(-size * 0.02)
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .leading) {
                Text(display.time)
                    .font(terminalFont)
                    .monospacedDigit()
                    .tracking(-size * 0.02)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: true, vertical: false)
            }
    }
}

struct CathodeRule: View {
    var colour: Color = Theme.serviceBlueLit

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [colour.opacity(0.8), colour.opacity(0.08)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

extension View {
    func embossed(lit: Color, weight: CGFloat = 1) -> some View {
        overlay(alignment: .top) { Rectangle().fill(lit).frame(height: weight) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink.opacity(0.45)).frame(height: weight) }
    }

    func labelStyle(_ colour: Color = Theme.textFaint) -> some View {
        font(Theme.Font.label)
            .tracking(Theme.tracking)
            .textCase(.uppercase)
            .foregroundStyle(colour)
    }

    func cathodeSection(_ colour: Color = Theme.serviceBlueLit) -> some View {
        HStack(spacing: 12) {
            self.labelStyle(colour)
            CathodeRule(colour: colour)
        }
    }
}
