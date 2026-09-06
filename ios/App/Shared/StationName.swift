/**
 Station names, shortened without ever being truncated.

 Lives beside the theme rather than beside the departure row because the widget needs
 it more than the app does: a lock screen accessory has room for about a dozen
 characters, and "London Fenchurch Street" is twice that.
 */
extension String {
    /**
     Drop "London" from London termini for display.

     "London Fenchurch Street" does not fit beside a large departure time on a phone,
     nor inside a direction block, and nobody standing at Grays needs telling which city
     Fenchurch Street is in. This is not truncation — the Real Length Rule forbids that
     — it is a shorter true name, and the full one stays in the accessible label.
     */
    var withoutLondonPrefix: String {
        components(separatedBy: " & ")
            .map { part in
                var name = part
                // "London Fenchurch Street" -> "Fenchurch Street".
                if name.hasPrefix("London ") && name.count > "London ".count {
                    name = String(name.dropFirst("London ".count))
                }
                // "Stratford (London)" -> "Stratford". The suffix disambiguates for a
                // national audience; on a board that only shows London-area journeys it is
                // noise, and it read oddly next to "Fenchurch Street" losing its "London".
                if name.hasSuffix(" (London)") {
                    name = String(name.dropLast(" (London)".count))
                }
                return name
            }
            .joined(separator: " & ")
    }
}
