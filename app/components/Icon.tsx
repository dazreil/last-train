/**
 * The app's icons, drawn rather than borrowed.
 *
 * One stroke language throughout: square caps, no fill, `currentColor`, and a
 * weight that steps down with size the way the direction mark's does. Unicode
 * glyphs were standing in for these — a crosshair, a caret, an arrow — which meant
 * three different type designers' idea of the same shape sitting next to a mark
 * drawn specifically for this app.
 *
 * Every icon is decorative here: each one sits inside a control that already
 * carries its own accessible name, so they are hidden from assistive tech rather
 * than announced twice.
 */

interface IconProps {
  /** Matches the surrounding type size; the stroke scales with it. */
  size?: number;
  className?: string;
}

/** Nearest station. A reticle, not a map pin — it means "where I am", not "a place". */
export function Crosshair({ size = 22, className }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth={2.25}
      strokeLinecap="square"
      aria-hidden="true"
      focusable="false"
    >
      <circle cx="12" cy="12" r="6.25" />
      <path d="M12 1.75v3.5M12 18.75v3.5M1.75 12h3.5M18.75 12h3.5" />
    </svg>
  );
}

/** The date control's affordance: this row does something when you press it. */
export function ChevronDown({ size = 10, className }: IconProps) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth={2.75}
      strokeLinecap="square"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M2.5 5.5 L8 11 L13.5 5.5" />
    </svg>
  );
}

/**
 * Direction on a recent-search block.
 *
 * A single chevron against the direction block's double — the same drawing one
 * step lighter for one step smaller, so the two read as the same system rather
 * than as a coincidence.
 */
export function DirectionChevron({
  direction,
  size = 9,
  className,
}: IconProps & { direction: 'east' | 'west' }) {
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth={2.75}
      strokeLinecap="square"
      aria-hidden="true"
      focusable="false"
      style={direction === 'west' ? { transform: 'scaleX(-1)' } : undefined}
    >
      <path d="M5 2.5 L10.5 8 L5 13.5" />
    </svg>
  );
}
