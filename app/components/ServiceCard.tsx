import type { DepartureService } from '@/lib/journeys';

/** Short brand labels. The full operator name goes in the tooltip and aria label. */
const BRAND: Record<string, string> = {
  CC: 'c2c',
  LE: 'Anglia',
  XR: 'Elizabeth',
};

/**
 * Drop the "London" from London termini for display.
 *
 * "London Fenchurch Street" does not fit beside a 2rem departure time on a 375px
 * phone, and truncating to "London Fenchurch S..." loses the only word that
 * distinguishes it. Nobody standing at Grays needs telling which city Fenchurch
 * Street is in. The full name stays in the tooltip and the screen-reader text.
 */
const shortenPlace = (name: string): string =>
  name
    .split(' & ')
    .map((part) => part.replace(/^London (?=\S)/, ''))
    .join(' & ');

/**
 * One departure.
 *
 * A departure board line, not a journey: with only a direction chosen there is no
 * destination to arrive at, so the answer is the time it leaves, where it is
 * going, and which way round it gets there.
 *
 * The route matters more here than it did with a destination chosen. From Fenchurch
 * Street, "east" mixes the Basildon main line with the Tilbury loop, and only one
 * of those goes anywhere near Grays.
 */
export default function ServiceCard({ service }: { service: DepartureService }) {
  const brand = BRAND[service.toc] ?? service.toc;

  return (
    <li className="service">
      <div className="service-times">
        <span className="time">
          {service.dep}
          {service.departsAfterMidnight && (
            <span className="next-day" title="After midnight, still tonight's service">
              +1
            </span>
          )}
        </span>
        <span className="destination" title={service.destination}>
          {shortenPlace(service.destination)}
        </span>
        <span className="badge" data-toc={service.toc} title={service.tocName}>
          {brand}
        </span>
      </div>

      <div className="service-meta">
        {service.via && <span className="via">{service.via}</span>}

        {service.platform && (
          <>
            {service.via && (
              <span className="sep" aria-hidden="true">
                ·
              </span>
            )}
            <span>plat {service.platform}</span>
          </>
        )}

        {service.isReplacementBus && (
          <>
            {(service.via || service.platform) && (
              <span className="sep" aria-hidden="true">
                ·
              </span>
            )}
            <span className="bus">replacement bus</span>
          </>
        )}

        {service.headcode && (
          <>
            {(service.via || service.platform || service.isReplacementBus) && (
              <span className="sep" aria-hidden="true">
                ·
              </span>
            )}
            <span className="headcode">{service.headcode}</span>
          </>
        )}
      </div>

      <span className="visually-hidden">
        {`${service.tocName} service departing ${service.dep}` +
          (service.departsAfterMidnight ? ' after midnight' : '') +
          `, towards ${service.destination}` +
          (service.via ? `, ${service.via}` : '')}
      </span>
    </li>
  );
}
