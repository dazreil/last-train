import { Footer, Nav } from './site';

/** The home page. The board is in the app; this says what the app is, and where it is. */
export default function Home() {
  return (
    <div className="wrap">
      <Nav here="home" />

      <div className="hero">
        <div className="led" aria-hidden="true">
          00:22
        </div>
        <h1>Know your last train home.</h1>
        <p>
          Last Train shows the last train from your station, and the one after it. Fast Train shows the train that
          gets you there first.
        </p>
        <span className="store">
          Coming soon to the App Store <small>iPhone</small>
        </span>
      </div>

      <div className="modes">
        <div className="mode">
          <div className="k red">LAST TRAIN</div>
          <div className="t red" aria-hidden="true">
            00:22
          </div>
          <p>The last train, in red. Follow it and the countdown sits on your lock screen.</p>
        </div>
        <div className="mode">
          <div className="k blue">FAST TRAIN</div>
          <div className="t blue" aria-hidden="true">
            21:14
          </div>
          <p>The next trains, ranked by when they get you there, with live delays.</p>
        </div>
      </div>

      <section id="data">
        <h2>Data</h2>
        <div className="credit">
          <div>
            <b>Realtime Trains</b>
            <span>Last Train times</span>
          </div>
          <a href="https://www.realtimetrains.co.uk">realtimetrains.co.uk ↗</a>
        </div>
        <div className="credit">
          <div>
            <b>National Rail Enquiries</b>
            <span>Fast Train times and the timetable</span>
          </div>
          <a href="https://www.nationalrail.co.uk">nationalrail.co.uk ↗</a>
        </div>
        <div className="credit">
          <div>
            <b>Office of Rail and Road</b>
            <span>Popular destinations, 2024-25. Open Government Licence v3.0</span>
          </div>
          <a href="https://www.orr.gov.uk">orr.gov.uk ↗</a>
        </div>
      </section>

      <Footer />
    </div>
  );
}
