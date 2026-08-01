'use client';

import { useEffect, useId, useMemo, useRef, useState } from 'react';
import { Crosshair } from './Icon';
import {
  nearestStations,
  searchStations,
  type NearbyStation,
  type Station,
} from '@/lib/stations';

interface Props {
  label: string;
  value: Station | null;
  onChange: (station: Station | null) => void;
  placeholder: string;
  /** Shows the nearest-station button. Only wanted on the "from" field. */
  withLocate?: boolean;
  autoFocus?: boolean;
}

type Suggestion = { station: Station; distanceKm?: number };

export default function StationPicker({
  label,
  value,
  onChange,
  placeholder,
  withLocate = false,
  autoFocus = false,
}: Props) {
  const [text, setText] = useState('');
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const [nearby, setNearby] = useState<NearbyStation[] | null>(null);
  const [locating, setLocating] = useState(false);
  const [locateError, setLocateError] = useState<string | null>(null);

  const listId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  // The input mirrors the selection unless the user is actively typing.
  useEffect(() => {
    if (!open) setText(value ? value.name : '');
  }, [value, open]);

  const suggestions = useMemo<Suggestion[]>(() => {
    if (nearby) return nearby.map((n) => ({ station: n.station, distanceKm: n.distanceKm }));
    return searchStations(text).map((station) => ({ station }));
  }, [text, nearby]);

  useEffect(() => setActive(0), [text, nearby]);

  // Close when focus or a tap lands outside.
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!containerRef.current?.contains(event.target as Node)) {
        setOpen(false);
        setNearby(null);
      }
    };
    document.addEventListener('pointerdown', onPointerDown);
    return () => document.removeEventListener('pointerdown', onPointerDown);
  }, [open]);

  const pick = (station: Station) => {
    onChange(station);
    setText(station.name);
    setOpen(false);
    setNearby(null);
    setLocateError(null);
    inputRef.current?.blur();
  };

  const locate = () => {
    if (!('geolocation' in navigator)) {
      setLocateError('This device cannot report its location.');
      return;
    }
    setLocating(true);
    setLocateError(null);

    navigator.geolocation.getCurrentPosition(
      (position) => {
        setLocating(false);
        const found = nearestStations({
          lat: position.coords.latitude,
          lon: position.coords.longitude,
        });
        if (!found.length) {
          setLocateError('No station found near you.');
          return;
        }
        // One tap fills the field with the nearest station. The alternatives stay
        // on screen because at Barking or Stratford the nearest by straight line
        // is not always the one you are stood on.
        onChange(found[0].station);
        setText(found[0].station.name);
        setNearby(found);
        setOpen(true);
      },
      (error) => {
        setLocating(false);
        setLocateError(
          error.code === error.PERMISSION_DENIED
            ? 'Location permission denied.'
            : 'Could not get your location.'
        );
      },
      { enableHighAccuracy: true, timeout: 8000, maximumAge: 60_000 }
    );
  };

  const onKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Escape') {
      setOpen(false);
      setNearby(null);
      return;
    }
    if (!suggestions.length) return;

    if (event.key === 'ArrowDown') {
      event.preventDefault();
      setOpen(true);
      setActive((index) => (index + 1) % suggestions.length);
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      setActive((index) => (index - 1 + suggestions.length) % suggestions.length);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      pick(suggestions[active].station);
    }
  };

  const showList = open && suggestions.length > 0;

  return (
    <div className="field" ref={containerRef}>
      <label className="field-label" htmlFor={`${listId}-input`}>
        {label}
      </label>

      <div className="field-row">
        <input
          id={`${listId}-input`}
          ref={inputRef}
          className="station-input"
          type="text"
          role="combobox"
          aria-expanded={showList}
          aria-controls={listId}
          aria-autocomplete="list"
          autoComplete="off"
          autoCorrect="off"
          spellCheck={false}
          enterKeyHint="search"
          autoFocus={autoFocus}
          placeholder={placeholder}
          value={text}
          onChange={(event) => {
            // The text is a transient query; the selection only changes when a
            // station is actually picked. Nulling the selection on every
            // keystroke meant a stray input event could silently discard a valid
            // choice -- and it threw away results the user was still reading.
            setText(event.target.value);
            setNearby(null);
            setOpen(true);
          }}
          onFocus={(event) => {
            setOpen(true);
            // Tapping a filled field should let you retype immediately.
            event.target.select();
          }}
          onKeyDown={onKeyDown}
        />

        {withLocate && (
          <button
            type="button"
            className="icon-button"
            onClick={locate}
            disabled={locating}
            aria-label="Use nearest station"
            title="Use nearest station"
          >
            {locating ? <span aria-hidden="true">…</span> : <Crosshair />}
          </button>
        )}
      </div>

      {showList && (
        <ul className="suggestions" id={listId} role="listbox">
          {nearby && (
            <li aria-hidden="true">
              <button type="button" disabled style={{ opacity: 0.7, cursor: 'default' }}>
                <span>Nearest to you</span>
              </button>
            </li>
          )}
          {suggestions.map((suggestion, index) => (
            <li key={suggestion.station.crs} role="none">
              <button
                type="button"
                role="option"
                aria-selected={index === active}
                onPointerDown={(event) => {
                  // Fire before the input's blur so the pick is not lost.
                  event.preventDefault();
                  pick(suggestion.station);
                }}
              >
                <span>{suggestion.station.name}</span>
                {suggestion.distanceKm !== undefined ? (
                  <span className="distance">
                    {suggestion.distanceKm < 1
                      ? `${Math.round(suggestion.distanceKm * 1000)} m`
                      : `${suggestion.distanceKm.toFixed(1)} km`}
                  </span>
                ) : (
                  <span className="crs">{suggestion.station.crs}</span>
                )}
              </button>
            </li>
          ))}
        </ul>
      )}

      {locateError && (
        // Not red: red means "last train" and nothing else. A failed geolocation
        // is stated in plain text.
        <p style={{ margin: '0.35rem 0 0', fontSize: '0.8rem', color: 'var(--text)' }}>
          {locateError}
        </p>
      )}
    </div>
  );
}
