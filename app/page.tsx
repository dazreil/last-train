'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import StationPicker from './components/StationPicker';
import ServiceCard from './components/ServiceCard';
import DirectionBlock from './components/DirectionBlock';
import { findStation, type Station } from '@/lib/stations';
import {
  addDays,
  currentServiceDate,
  formatServiceDate,
  SERVICE_DAY_START_HOUR,
} from '@/lib/serviceDay';
import type { DirectionValue, TrainsError, TrainsResponse } from '@/lib/contract';

/*
 * Bumped from `recentStations`, which stored bare CRS codes. A recent search is a
 * station *and* a direction; the old shape could not express that, so old entries
 * are simply left behind rather than migrated into a guess.
 */
const RECENTS_KEY = 'lastTrain.recents.v2';
const LAST_STATE_KEY = 'lastTrain.lastState';

/** Four blocks is what fits across a phone without the codes shrinking. */
const MAX_RECENTS = 4;

interface SavedState {
  from: string;
  direction: DirectionValue;
}

/** A recent search: where you were, and which way you were going. */
interface Recent {
  crs: string;
  direction: DirectionValue;
}

const isRecent = (value: unknown): value is Recent =>
  typeof value === 'object' &&
  value !== null &&
  typeof (value as Recent).crs === 'string' &&
  ((value as Recent).direction === 'east' || (value as Recent).direction === 'west');

const readJson = <T,>(key: string): T | null => {
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : null;
  } catch {
    return null;
  }
};

const writeJson = (key: string, value: unknown): void => {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* private browsing, or storage full; recents are a convenience only */
  }
};

export default function Page() {
  const [from, setFrom] = useState<Station | null>(null);
  const [direction, setDirection] = useState<DirectionValue>('west');
  const [tomorrow, setTomorrow] = useState(false);
  const [recents, setRecents] = useState<Recent[]>([]);

  const [result, setResult] = useState<TrainsResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [restored, setRestored] = useState(false);

  // Answers already fetched this session, so flipping direction or date is instant
  // and costs nothing.
  const sessionCache = useRef(new Map<string, TrainsResponse>());
  const inFlight = useRef<AbortController | null>(null);

  const today = useMemo(() => currentServiceDate(), []);
  const date = tomorrow ? addDays(today, 1) : today;

  /**
   * True when the London clock has passed midnight but not yet 03:00, so "today"
   * still means last night's service day. Worth saying out loud: it is exactly the
   * case where a naive app would show tomorrow morning's timetable.
   */
  const afterMidnight = useMemo(() => {
    const hour = Number(
      new Intl.DateTimeFormat('en-GB', {
        timeZone: 'Europe/London',
        hour: '2-digit',
        hourCycle: 'h23',
      }).format(new Date())
    );
    return hour < SERVICE_DAY_START_HOUR;
  }, []);

  // ---- restore on load -----------------------------------------------------
  // The app is opened in a hurry, usually for the same journey as last time, so it
  // comes back up already showing an answer.
  useEffect(() => {
    const saved = readJson<SavedState>(LAST_STATE_KEY);
    if (saved) {
      setFrom(findStation(saved.from) ?? null);
      if (saved.direction === 'east' || saved.direction === 'west') setDirection(saved.direction);
    }
    setRecents((readJson<unknown[]>(RECENTS_KEY) ?? []).filter(isRecent));
    setRestored(true);
  }, []);

  // ---- fetch ---------------------------------------------------------------

  const lookup = useCallback(
    async (fromCrs: string, which: DirectionValue, forDate: string, refresh = false) => {
      const key = `${fromCrs}:${which}:${forDate}`;

      if (!refresh) {
        const cached = sessionCache.current.get(key);
        if (cached) {
          setResult(cached);
          setError(null);
          setLoading(false);
          return;
        }
      }

      inFlight.current?.abort();
      const controller = new AbortController();
      inFlight.current = controller;

      setLoading(true);
      setError(null);

      try {
        const params = new URLSearchParams({ from: fromCrs, direction: which, date: forDate });
        if (refresh) params.set('refresh', '1');

        const res = await fetch(`/api/trains?${params}`, { signal: controller.signal });
        const body = (await res.json()) as TrainsResponse | TrainsError;

        if (!res.ok) {
          setError((body as TrainsError).error ?? `Lookup failed (${res.status}).`);
          setResult(null);
          return;
        }

        const payload = body as TrainsResponse;
        sessionCache.current.set(key, payload);
        setResult(payload);
      } catch (cause) {
        if ((cause as Error)?.name === 'AbortError') return;
        setError('Could not reach the server. Are you online?');
        setResult(null);
      } finally {
        if (inFlight.current === controller) {
          inFlight.current = null;
          setLoading(false);
        }
      }
    },
    []
  );

  // Look up as soon as a station is set. No submit button: one fewer tap.
  useEffect(() => {
    if (!restored) return;
    if (!from) {
      setResult(null);
      setError(null);
      return;
    }

    writeJson(LAST_STATE_KEY, { from: from.crs, direction });
    setRecents((current) => {
      // Keyed on both, so Grays-east and Grays-west are two distinct recents --
      // which is exactly the out-and-back pair you want one tap away.
      const next = [
        { crs: from.crs, direction },
        ...current.filter(
          (entry) => !(entry.crs === from.crs && entry.direction === direction)
        ),
      ].slice(0, MAX_RECENTS);
      writeJson(RECENTS_KEY, next);
      return next;
    });

    void lookup(from.crs, direction, date);
  }, [from, direction, date, restored, lookup]);

  const firstTrain = result?.services.filter((service) => service.role === 'first') ?? [];
  const lastTrains = result?.services.filter((service) => service.role === 'last') ?? [];

  // The genuine last one, not merely the last section. Services arrive in departure
  // order, so it is the final entry -- the 00:46, not the 23:47 above it.
  const lastTrainId = lastTrains.length ? lastTrains[lastTrains.length - 1].serviceId : null;

  const degraded =
    result?.systemStatus?.rttCore === 'SCHEDULE_ONLY' ||
    result?.systemStatus?.realtimeNetworkRail === 'REALTIME_DATA_NONE';

  return (
    <main className="app">
      <header className="masthead">
        <h1>Last Train</h1>
        {/*
         * The date doubles as the today/tomorrow control. It has to live somewhere,
         * the control stack is compressed so the first departure clears the fold,
         * and the direction block's tap already means something else.
         */}
        <button
          type="button"
          className="day-toggle"
          aria-pressed={tomorrow}
          onClick={() => setTomorrow((current) => !current)}
          aria-label={
            `Showing ${formatServiceDate(date)}. ` +
            `Switch to ${tomorrow ? "tonight's" : "tomorrow's"} trains.`
          }
        >
          {tomorrow ? 'Tomorrow' : afterMidnight ? 'Tonight' : 'Today'}
          <span className="caret" aria-hidden="true">
            ▾
          </span>
          {formatServiceDate(date)}
        </button>
      </header>

      <div className="controls">
        <StationPicker
          label="From"
          value={from}
          onChange={setFrom}
          placeholder="Station or code"
          withLocate
        />

        {/*
         * Direction, the destination hint and the date used to be three separate
         * rows. "East" only means something if you know where east goes from here,
         * so the hint lives inside the block it explains.
         */}
        <DirectionBlock
          direction={direction}
          towards={result?.towards ?? []}
          onChange={setDirection}
        />

        {recents.length > 1 && (
          <>
            <h2 className="recent-label">Recent</h2>
            <ul className="recent-row">
              {recents.map((entry) => {
                const station = findStation(entry.crs);
                if (!station) return null;
                const active = from?.crs === entry.crs && direction === entry.direction;
                return (
                  <li key={`${entry.crs}-${entry.direction}`}>
                    <button
                      type="button"
                      className="recent-block"
                      aria-current={active}
                      // Restores both halves of the search, and the lookup effect
                      // runs off the state change. No second tap.
                      onClick={() => {
                        setFrom(station);
                        setDirection(entry.direction);
                      }}
                      aria-label={`${station.name}, ${entry.direction}bound`}
                      title={`${station.name} — ${entry.direction}bound`}
                    >
                      <span className="crs">{station.crs}</span>
                      <span className="heading" aria-hidden="true">
                        {entry.direction === 'east' ? '→ E' : '← W'}
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          </>
        )}
      </div>

      <section className="results" aria-live="polite" aria-busy={loading}>
        {loading && !result && (
          <div className="skeleton" aria-hidden="true">
            <div className="skeleton-row" />
            <div className="skeleton-row" />
            <div className="skeleton-row" />
          </div>
        )}

        {error && (
          <div className="notice error">
            <h2>Couldn’t look that up</h2>
            <p>{error}</p>
            {from && (
              <p>
                <button
                  type="button"
                  className="chip"
                  style={{ marginTop: '0.5rem' }}
                  onClick={() => void lookup(from.crs, direction, date, true)}
                >
                  Try again
                </button>
              </p>
            )}
          </div>
        )}

        {!error && result && result.services.length === 0 && (
          /*
           * Nothing running that way is a valid answer, shown plainly and calmly --
           * never as an error. The app is only useful if a blank result can be
           * trusted to mean something real.
           */
          <div className="notice">
            <h2>Nothing {direction}bound</h2>
            <p>
              No trains run {direction} from {result.from.name} on{' '}
              {formatServiceDate(result.date)}.
            </p>
            <p>
              This app covers c2c, the Elizabeth line, and Liverpool Street to Shenfield. Empty
              results on a Sunday out of Liverpool Street are usually a real engineering closure.
            </p>
          </div>
        )}

        {!error && result && result.services.length > 0 && (
          <>
            {firstTrain.length > 0 && (
              <div>
                <h2 className="section-heading">
                  <span>First train {direction}</span>
                </h2>
                <ul className="service-list">
                  {firstTrain.map((service) => (
                    <ServiceCard key={service.serviceId} service={service} />
                  ))}
                </ul>
              </div>
            )}

            <div>
              <h2 className="section-heading">
                <span>
                  {lastTrains.length > 1 ? `Last ${lastTrains.length} trains` : 'Last train'}{' '}
                  {direction}
                </span>
                {result.totalIsExact && <span>{result.totalServices} services</span>}
              </h2>
              <ul className="service-list">
                {lastTrains.map((service) => (
                  <ServiceCard
                    key={service.serviceId}
                    service={service}
                    isLastTrain={service.serviceId === lastTrainId}
                  />
                ))}
              </ul>
            </div>
          </>
        )}

        {!error && !result && !loading && restored && !from && (
          <div className="notice">
            <h2>Where are you?</h2>
            <p>
              Tap ◎ to fill in the nearest station, then pick a direction. Trains you can board
              here, across c2c, the Elizabeth line, and Liverpool Street to Shenfield.
            </p>
          </div>
        )}
      </section>

      <p className="footnote">
        Timetabled departures for the {formatServiceDate(date)} service day, which runs to{' '}
        {String(SERVICE_DAY_START_HOUR).padStart(2, '0')}:00 the next morning, so trains after
        midnight are tonight's, not tomorrow's.
        {degraded && ' Realtime data is currently degraded; these are scheduled times only.'} Data
        from{' '}
        <a href="https://www.realtimetrains.co.uk" rel="noreferrer noopener" target="_blank">
          Realtime Trains
        </a>
        .
        {result && (
          <>
            {' '}
            <button
              type="button"
              className="chip"
              style={{ marginTop: '0.6rem' }}
              onClick={() => from && void lookup(from.crs, direction, date, true)}
            >
              Refresh
            </button>
          </>
        )}
      </p>
    </main>
  );
}
