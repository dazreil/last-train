'use client';

import type { DirectionValue } from '@/lib/contract';

/**
 * Direction, as a block whose position on screen *is* the answer.
 *
 * Westbound sits against the left edge, eastbound against the right, and tapping
 * slides it across. You read the direction from where the mass sits before you
 * read a word of it -- which works because west-is-left is a map convention people
 * already hold, and because the domain really is a line with a thing on it.
 *
 * The mark is drawn here rather than borrowed: British Rail's double arrow is a
 * protected mark, and this app is served from a public URL.
 */
export default function DirectionBlock({
  direction,
  towards,
  onChange,
}: {
  direction: DirectionValue;
  towards: string[];
  onChange: (next: DirectionValue) => void;
}) {
  const next: DirectionValue = direction === 'west' ? 'east' : 'west';
  const heading = direction === 'west' ? 'Westbound' : 'Eastbound';

  return (
    <div className="direction" data-direction={direction}>
      <button
        type="button"
        className="direction-block"
        onClick={() => onChange(next)}
        aria-label={
          `${heading}${towards.length ? `, towards ${towards.join(', ')}` : ''}. ` +
          `Change to ${next}bound.`
        }
      >
        <span className="direction-mark" aria-hidden="true">
          <svg viewBox="0 0 34 24" width="30" height="22" focusable="false">
            <path
              d="M3 3 L14 12 L3 21"
              fill="none"
              stroke="currentColor"
              strokeWidth="4.5"
              strokeLinecap="square"
            />
            <path
              d="M19 3 L30 12 L19 21"
              fill="none"
              stroke="currentColor"
              strokeWidth="4.5"
              strokeLinecap="square"
            />
          </svg>
        </span>

        <span className="direction-text">
          <span className="direction-heading">{heading}</span>
          {/* Two is what fits on one line at 72% width; a third wraps and orphans
              a word. */}
          {towards.length > 0 && (
            <span className="direction-towards">
              towards {towards.slice(0, 2).join(', ')}
            </span>
          )}
        </span>
      </button>
    </div>
  );
}
