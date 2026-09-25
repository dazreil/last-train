import type { Metadata } from 'next';

import { Contact, Footer, Nav } from '../site';

export const metadata: Metadata = { title: 'Privacy' };

/**
 * The privacy policy the App Store links to.
 *
 * Every claim here is a claim about the code, checked on 25 September 2026. Change the
 * code in a way that touches one — an analytics library, a location sent to the server —
 * and this page must change with it.
 */
export default function Privacy() {
  return (
    <div className="wrap">
      <Nav here="privacy" />
      <h1 className="page-title">Privacy</h1>
      <p className="updated">Last updated 25 September 2026</p>

      <section>
        <p>Short version: no account, no ads, no tracking. What you save stays on your phone.</p>

        <h3>On your phone only</h3>
        <ul>
          <li>Your home station, your recent journeys and the stations you use most.</li>
          <li>The train you follow, for the widget and the lock-screen countdown.</li>
          <li>Settings → Reset app deletes all of it.</li>
        </ul>

        <h3>Your location</h3>
        <p>
          Used only when you tap the arrow, one time, to find the stations near you. The search happens on your phone.
          Your location is never sent to us.
        </p>

        <h3>What our server sees</h3>
        <ul>
          <li>The station codes, direction and date you ask about. We need them to find your trains.</li>
          <li>
            Your IP address, as every website does. We count requests per address to stop misuse, and the counts are
            deleted within about an hour.
          </li>
          <li>Our host, Vercel, keeps standard request logs for a short time.</li>
        </ul>

        <h3>What we do not do</h3>
        <ul>
          <li>No analytics, no advertising, and no data is sold or shared.</li>
          <li>No account, so there is nothing to sign up for or delete.</li>
        </ul>

        <h3>Questions</h3>
        <p>
          Write to <Contact />.
        </p>
      </section>

      <Footer />
    </div>
  );
}
