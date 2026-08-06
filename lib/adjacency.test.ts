import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { COMPASS_POINTS } from './compass.ts';

/**
 * The adjacency table is generated, so these check the *shape of the answer* rather
 * than any particular station.
 *
 * One failure mode matters more than the rest. A waypoint that is too **narrow** — one
 * a fast service skips — makes `filterTo` silently drop trains, and a departure board
 * that quietly omits the last train is worse than one that is wrong in a way you can
 * see. Everything here is aimed at that.
 */
const table = JSON.parse(readFileSync(new URL('../data/adjacency.json', import.meta.url), 'utf8'));
const stations: Record<string, Record<string, {
  waypoint: string | null;
  firstCalls: string[];
  destinations: string[];
  samples: number;
}>> = table.stations;

test('every sector is a real compass point', () => {
  for (const [crs, sectors] of Object.entries(stations)) {
    for (const point of Object.keys(sectors)) {
      assert.ok(COMPASS_POINTS.includes(point as never), `${crs} has sector "${point}"`);
    }
  }
});

/**
 * Three is the threshold the generator applies, and the reason is the whole point of
 * the guard: a sector seen once has probably only been seen in its stopping pattern,
 * and a waypoint drawn from that will not be called at by the fast services.
 */
test('a waypoint is never drawn from fewer than three sampled routes', () => {
  for (const [crs, sectors] of Object.entries(stations)) {
    for (const [point, sector] of Object.entries(sectors)) {
      if (sector.waypoint) {
        assert.ok(sector.samples >= 3, `${crs} ${point} has a waypoint from ${sector.samples} samples`);
      }
    }
  }
});

/**
 * The defining property. A waypoint has to select one direction and only that
 * direction, so it must not be somewhere the *other* directions' trains also call —
 * otherwise `filterTo` steals services from the neighbouring bucket.
 */
test('a waypoint never appears as another direction’s first call', () => {
  for (const [crs, sectors] of Object.entries(stations)) {
    for (const [point, sector] of Object.entries(sectors)) {
      if (!sector.waypoint) continue;
      for (const [other, otherSector] of Object.entries(sectors)) {
        if (other === point) continue;
        assert.ok(
          !otherSector.firstCalls.includes(sector.waypoint),
          `${crs}: ${point} waypoint ${sector.waypoint} is also a ${other} first call`
        );
      }
    }
  }
});

test('a waypoint is never the station itself', () => {
  for (const [crs, sectors] of Object.entries(stations)) {
    for (const sector of Object.values(sectors)) {
      assert.notEqual(sector.waypoint, crs);
    }
  }
});

/**
 * Null is a legitimate and expected answer, not a gap to be filled.
 *
 * Upminster westbound has no waypoint because the Fenchurch Street main line and the
 * Romford branch share no station: nothing selects one without selecting the other. If
 * this ever stops being true the generator has started inventing waypoints, and the
 * board will start dropping trains.
 */
test('a sector with irreconcilable routes gets no waypoint rather than a wrong one', () => {
  const upminster = stations.UPM;
  if (!upminster?.west) return; // not yet walked
  assert.equal(upminster.west.waypoint, null);
  assert.ok(upminster.west.firstCalls.length > 1);
});

test('the Ockendon branch is pinned, which is the case that prompted all this', () => {
  const upminster = stations.UPM;
  if (!upminster?.south) return; // not yet walked
  assert.equal(upminster.south.waypoint, 'OCK');
  // It carries on past Grays -- which is why "towards Grays" was the wrong label.
  assert.ok(upminster.south.destinations.includes('PSE'));
});
