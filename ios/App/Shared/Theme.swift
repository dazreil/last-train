import SwiftUI

/**
 The design system, ported from `DESIGN.md`.

 IOS.md §7 is explicit: **port, don't redesign.** Full-bleed blocks, zero radius, zero
 gaps, mono tabular times as the largest thing on screen, operator as an outline rather
 than a filled brand colour.

 Two rules here are load-bearing and easy to break by accident:

 **Red means "this is the last train" and nothing else.** There is deliberately no
 danger colour in this file. Errors, replacement buses and alerts are all non-red. The
 moment red means two things it means nothing, and the red block stops being readable
 from across a platform.

 **Contrast is computed, never eyeballed.** The palette already changed once because a
 Union Flag red measured 2.51:1 against the blue beneath it. Do not substitute a colour
 here without measuring it against the ground it sits on.

 Type uses Dynamic Type text styles rather than fixed point sizes — the native
 equivalent of the 200% font test the web app already passes. The layout grows
 downward; it never clips.
 */
enum Theme {

    // MARK: - Colour

    /// `#0b0d10`. The ground.
    static let ink = Color(hex: 0x0b0d10)
    /// `#14181d`. The page the board sits on.
    static let surface = Color(hex: 0x14181d)
    /// `#1c2229`. Fields.
    static let raised = Color(hex: 0x1c2229)
    /**
     `#232b34`. An unselected direction block.

     A shade above `raised`, because on device the chevrons were nearly invisible
     against the surface — the shape has to read before the word does, and it cannot do
     that at 1.2:1. Still well below the blue, so the selected block is unambiguous.
     */
    static let control = Color(hex: 0x232b34)
    static let hairline = Color(hex: 0x2a323b)

    /**
     `#3d4956` and `#20449b`. The lit facet of a direction block, per fill.

     **Not white.** The emboss was built with `paper` at part opacity, and on device that
     is a white line drawn on a dark shape rather than light falling across it — the whole
     effect reads as an outline. Light on a surface is that surface, lifted: each of these
     is its own fill taken a few steps up, so the edge belongs to the block it sits on.

     Decorative only. State is carried by the fill beneath — blue, grey, or black — so
     these never have to reach a contrast ratio.
     */
    static let controlLit = Color(hex: 0x3d4956)
    static let serviceBlueLit = Color(hex: 0x20449b)

    static let text = Color(hex: 0xf2f5f8)
    static let textDim = Color(hex: 0x9aa7b4)
    static let textFaint = Color(hex: 0x6b7885)

    /// `#012169`. Every service block that is not the last train.
    static let serviceBlue = Color(hex: 0x012169)
    static let paper = Color(hex: 0xffffff)

    /**
     `#E4002B`. **The last train, and nothing else, ever.**

     Not flag red — chosen by measurement against the blue beneath it. Colour is never
     the only signal either: the block carries a visible LAST TRAIN label as well, for
     anyone who cannot separate the two hues.
     */
    static let lastTrainRed = Color(hex: 0xe4002b)

    // MARK: - Type

    enum Font {
        /// The departure time. The largest thing on screen, and tabular.
        static let time = SwiftUI.Font.system(.largeTitle, design: .monospaced).weight(.bold)
        /// Direction words, section titles.
        static let heading = SwiftUI.Font.system(.title3, design: .default).weight(.bold)
        /// Where a train is going.
        static let destination = SwiftUI.Font.system(.subheadline).weight(.bold)
        static let body = SwiftUI.Font.system(.body).weight(.semibold)
        /// Uppercase labels. Pair with `Theme.tracking`.
        static let label = SwiftUI.Font.system(.caption2).weight(.bold)
        /// Platform, operator, headcode.
        static let meta = SwiftUI.Font.system(.caption).weight(.semibold)
    }

    /// Uppercase labels are letter-spaced; body text is not.
    static let tracking: CGFloat = 1.3

    enum Space {
        static let gutter: CGFloat = 16
        /// Blocks are separated by colour change alone, so the stack reads as one object.
        static let blockGap: CGFloat = 0
        /// Minimum comfortable target for a thumb, one-handed.
        static let tap: CGFloat = 48
    }
}

extension Color {
    /// `0xRRGGBB`, so the values in `DESIGN.md` can be pasted in unchanged.
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

extension View {
    /// An uppercase, letter-spaced label in the house style.
    func labelStyle(_ colour: Color = Theme.textFaint) -> some View {
        self
            .font(Theme.Font.label)
            .tracking(Theme.tracking)
            .textCase(.uppercase)
            .foregroundStyle(colour)
    }
}
