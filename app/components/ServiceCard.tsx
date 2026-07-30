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
export default function ServiceCard({
  service,
  isLastTrain = false,
}: {
  service: DepartureService;
  isLastTrain?: boolean;
}) {
  const brand = BRAND[service.toc] ?? service.toc;

  return (
    <li className={isLastTrain ? 'service last-train' : 'service'}>
      {/*
       * Stated in words as well as in colour. Red carries it at a glance, but red
       * against the blue above is a hue difference more than a brightness one, so
       * it is reinforcement rather than the whole message -- and it has to work for
       * anyone who cannot separate the two hues at all.
       */}
      {isLastTrain && <span className="last-train-flag">Last train</span>}
      <div className="service-times">
        {/*
         * Just the time. No next-day marker: the whole app works in service days,
         * and a 00:18 sitting below a 23:47 in a list of tonight's last trains is
         * already unambiguous on a 24-hour clock.
         */}
        <span className="time">{service.dep}</span>
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
        {(isLastTrain ? 'Last train. ' : '') +
          `${service.tocName} service departing ${service.dep}` +
          `, towards ${service.destination}` +
          (service.via ? `, ${service.via}` : '')}
      </span>
    </li>
  );
}
