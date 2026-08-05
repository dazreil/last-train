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
                part.hasPrefix("London ") && part.count > "London ".count
                    ? String(part.dropFirst("London ".count))
                    : part
            }
            .joined(separator: " & ")
    }
}
