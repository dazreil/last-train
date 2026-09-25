import type { Metadata } from 'next';

import { Contact, Footer, Nav } from '../site';

export const metadata: Metadata = { title: 'Support' };

/** The support page the App Store links to: the common questions, then who to write to. */
export default function Support() {
  return (
    <div className="wrap">
      <Nav here="support" />
      <h1 className="page-title">Support</h1>

      <section>
        <h3>The time looks wrong</h3>
        <p>
          Hold the header to refresh. Times within two hours are live from National Rail. Times further out are from
          the timetable and can change.
        </p>

        <h3>The arrow does not find my station</h3>
        <p>
          Location may be off for Last Train. Tap the message under the bar to open Settings, or pick your station by
          name.
        </p>

        <h3>The countdown is not on my lock screen</h3>
        <p>Live Activities may be off. Open Settings → Last Train → Live Activities.</p>

        <h3>Something else</h3>
        <p>
          Write to <Contact />. Please include the stations and the time you looked.
        </p>
      </section>

      <Footer />
    </div>
  );
}
