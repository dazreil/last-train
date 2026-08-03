/**
 * NaPTAN: the coordinates behind every station in this project.
 *
 * Shared by `generate-stations.mjs` (the 67-station web app) and
 * `generate-national.mjs` (all ~2,600), because both make exactly the same join and
 * it is not a join worth getting subtly different in two places.
 *
 * NaPTAN is the DfT's, published under the Open Government Licence, and free. It is
 * also the reason this project needs no third-party station list: measured against
 * the 2,622 stops the RTT token can query, this module resolves 2,619 of them. The
 * three it does not are two rail-air interchanges that are not rail stations, and
 * Winslow, which is too new for NaPTAN to have published. See IOS.md §6.
 *
 * Getting there takes three joins, and the first one alone silently misses the
 * busiest stations in Britain:
 *
 *   1. **By TIPLOC**, which is the ATCO code with its `9100` prefix removed. Covers
 *      2,612. The API's `longCode` is the key.
 *   2. **By name**, for the 7 that TIPLOC misses. NaPTAN splits large stations into
 *      platform groups under suffixed codes -- `WATRLOO` is `WATRLMN`, `VICTRIA` is
 *      `VICTRIC` and `VICTRIE`, `CLPHMJN` is five separate rows -- so the generic
 *      TIPLOC the API returns matches nothing. Waterloo, Victoria, London Bridge,
 *      Clapham Junction and Vauxhall all land here.
 *   3. **By OS grid reference**, for the 6 rows that carry `Latitude,Longitude` of
 *      `0,0` but a real `Easting,Northing`. That is the Elizabeth line central core:
 *      Bond Street, Canary Wharf, Tottenham Court Road, Custom House, Woolwich and
 *      Barking Riverside.
 *
 * Matching by name is only safe because it was checked: across every station where
 * both routes resolve, the two never disagreed by more than 500m. That check is
 * cheap to repeat and worth repeating if this is ever edited.
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const CACHE = join(ROOT, '.rtt-cache');

export const NAPTAN_RAIL_CSV =
  'https://naptan.api.dft.gov.uk/v1/access-nodes?dataFormat=csv&atcoAreaCodes=910';

// ------------------------------------------------------------------------- csv

export function parseCsvLine(line) {
  const out = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"') {
        if (line[i + 1] === '"') {
          field += '"';
          i++;
        } else quoted = false;
      } else field += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') {
      out.push(field);
      field = '';
    } else field += ch;
  }
  out.push(field);
  return out;
}

// ------------------------------------------------------------------- geometry

export const haversineMetres = (a, b) => {
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
};

// ------------------------------------------------- OSGB36 grid ref -> WGS84

/**
 * Inverse transverse Mercator on the Airy 1830 ellipsoid, then a Helmert
 * transform onto WGS84. Accurate to a few metres, which is ample for deciding
 * which platform you are standing on.
 */
function gridToOsgb36LatLon(easting, northing) {
  const a = 6377563.396;
  const b = 6356256.909;
  const f0 = 0.9996012717;
  const lat0 = (49 * Math.PI) / 180;
  const lon0 = (-2 * Math.PI) / 180;
  const n0 = -100_000;
  const e0 = 400_000;

  const e2 = 1 - (b * b) / (a * a);
  const n = (a - b) / (a + b);
  const n2 = n * n;
  const n3 = n2 * n;

  let lat = lat0;
  let m = 0;
  do {
    lat = (northing - n0 - m) / (a * f0) + lat;
    const ma = (1 + n + 1.25 * n2 + 1.25 * n3) * (lat - lat0);
    const mb = (3 * n + 3 * n2 + 2.625 * n3) * Math.sin(lat - lat0) * Math.cos(lat + lat0);
    const mc = (1.875 * n2 + 1.875 * n3) * Math.sin(2 * (lat - lat0)) * Math.cos(2 * (lat + lat0));
    const md = (35 / 24) * n3 * Math.sin(3 * (lat - lat0)) * Math.cos(3 * (lat + lat0));
    m = b * f0 * (ma - mb + mc - md);
  } while (Math.abs(northing - n0 - m) >= 0.00001);

  const sinLat = Math.sin(lat);
  const cosLat = Math.cos(lat);
  const nu = (a * f0) / Math.sqrt(1 - e2 * sinLat * sinLat);
  const rho = (a * f0 * (1 - e2)) / Math.pow(1 - e2 * sinLat * sinLat, 1.5);
  const eta2 = nu / rho - 1;

  const tanLat = Math.tan(lat);
  const t2 = tanLat * tanLat;
  const t4 = t2 * t2;
  const t6 = t4 * t2;
  const sec = 1 / cosLat;
  const nu3 = nu ** 3;
  const nu5 = nu ** 5;
  const nu7 = nu ** 7;

  const vii = tanLat / (2 * rho * nu);
  const viii = (tanLat / (24 * rho * nu3)) * (5 + 3 * t2 + eta2 - 9 * t2 * eta2);
  const ix = (tanLat / (720 * rho * nu5)) * (61 + 90 * t2 + 45 * t4);
  const x = sec / nu;
  const xi = (sec / (6 * nu3)) * (nu / rho + 2 * t2);
  const xii = (sec / (120 * nu5)) * (5 + 28 * t2 + 24 * t4);
  const xiia = (sec / (5040 * nu7)) * (61 + 662 * t2 + 1320 * t4 + 720 * t6);

  const d = easting - e0;
  return {
    lat: lat - vii * d ** 2 + viii * d ** 4 - ix * d ** 6,
    lon: lon0 + x * d - xi * d ** 3 + xii * d ** 5 - xiia * d ** 7,
  };
}

/** Helmert, OSGB36 -> WGS84 (the inverse of the published WGS84 -> OSGB36 set). */
function osgb36ToWgs84(latRad, lonRad) {
  const a1 = 6377563.396;
  const b1 = 6356256.909;
  const e1 = 1 - (b1 * b1) / (a1 * a1);
  const sinLat = Math.sin(latRad);
  const cosLat = Math.cos(latRad);
  const nu1 = a1 / Math.sqrt(1 - e1 * sinLat * sinLat);

  const x1 = nu1 * cosLat * Math.cos(lonRad);
  const y1 = nu1 * cosLat * Math.sin(lonRad);
  const z1 = (1 - e1) * nu1 * sinLat;

  const tx = 446.448;
  const ty = -125.157;
  const tz = 542.06;
  const s = -20.4894e-6;
  const arcsec = Math.PI / 180 / 3600;
  const rx = 0.1502 * arcsec;
  const ry = 0.247 * arcsec;
  const rz = 0.8421 * arcsec;

  const x2 = tx + x1 * (1 + s) - y1 * rz + z1 * ry;
  const y2 = ty + x1 * rz + y1 * (1 + s) - z1 * rx;
  const z2 = tz - x1 * ry + y1 * rx + z1 * (1 + s);

  const a2 = 6378137.0;
  const b2 = 6356752.3142;
  const e22 = 1 - (b2 * b2) / (a2 * a2);
  const p = Math.hypot(x2, y2);

  let lat = Math.atan2(z2, p * (1 - e22));
  for (let i = 0; i < 12; i++) {
    const nu2 = a2 / Math.sqrt(1 - e22 * Math.sin(lat) ** 2);
    const next = Math.atan2(z2 + e22 * nu2 * Math.sin(lat), p);
    if (Math.abs(next - lat) < 1e-13) {
      lat = next;
      break;
    }
    lat = next;
  }

  return { lat: (lat * 180) / Math.PI, lon: (Math.atan2(y2, x2) * 180) / Math.PI };
}

export function gridToWgs84(easting, northing) {
  const osgb = gridToOsgb36LatLon(Number(easting), Number(northing));
  return osgb36ToWgs84(osgb.lat, osgb.lon);
}

// ------------------------------------------------------------------- loading

/** Station names are compared with punctuation and the NaPTAN suffix removed. */
export const canonicalName = (value) =>
  String(value ?? '')
    .toLowerCase()
    .replace(/\brail station\b/g, '')
    .replace(/[^a-z0-9]/g, '');

const stripSuffix = (name) => String(name ?? '').replace(/\s+Rail Station$/i, '').trim();

const CACHE_FILE = join(CACHE, 'naptan-rail-rows.json');

async function fetchRows(log) {
  try {
    const cached = JSON.parse(readFileSync(CACHE_FILE, 'utf8'));
    if (Array.isArray(cached?.rows) && cached.rows.length) {
      log(`  NaPTAN from cache (${cached.rows.length} rail rows)`);
      return cached.rows;
    }
  } catch {
    /* no cache; fetch it */
  }

  log('  fetching NaPTAN rail access nodes...');
  const res = await fetch(NAPTAN_RAIL_CSV);
  if (!res.ok) throw new Error(`NaPTAN download failed: HTTP ${res.status}`);
  const lines = (await res.text()).split(/\r?\n/).filter(Boolean);

  const header = parseCsvLine(lines[0]);
  const col = (name) => {
    const index = header.indexOf(name);
    if (index === -1) throw new Error(`NaPTAN column "${name}" missing; format changed`);
    return index;
  };
  const iAtco = col('ATCOCode');
  const iName = col('CommonName');
  const iEast = col('Easting');
  const iNorth = col('Northing');
  const iLon = col('Longitude');
  const iLat = col('Latitude');
  const iStatus = col('Status');
  const iLocality = col('LocalityName');
  const iParent = col('ParentLocalityName');
  const iTown = col('Town');

  const rows = [];
  for (let i = 1; i < lines.length; i++) {
    const row = parseCsvLine(lines[i]);
    const atco = row[iAtco];
    if (!atco?.startsWith('9100')) continue;
    rows.push({
      tiploc: atco.slice(4).trim().toUpperCase(),
      name: row[iName],
      lat: row[iLat],
      lon: row[iLon],
      east: row[iEast],
      north: row[iNorth],
      status: row[iStatus],
      locality: row[iLocality],
      parent: row[iParent],
      town: row[iTown],
    });
  }

  try {
    mkdirSync(CACHE, { recursive: true });
    writeFileSync(CACHE_FILE, JSON.stringify({ rows }));
  } catch {
    /* the cache is an optimisation, never a requirement */
  }
  return rows;
}

/**
 * Turn one CSV row into a place, or null if it has no usable position.
 *
 * A row carrying both a lat/lon and a grid reference is also returned as a free
 * self-test for the converter, which is what `checks` collects.
 */
function toPlace(row, checks) {
  const lat = Number(row.lat);
  const lon = Number(row.lon);
  const east = Number(row.east);
  const north = Number(row.north);

  const hasLatLon =
    Number.isFinite(lat) && Number.isFinite(lon) && lat !== 0 && lon !== 0 && row.lat !== '';
  const hasGrid = Number.isFinite(east) && Number.isFinite(north) && east > 0 && north > 0;

  if (hasLatLon && hasGrid) checks.push({ expected: { lat, lon }, got: gridToWgs84(east, north) });

  let coords = null;
  let source = null;
  if (hasLatLon) {
    coords = { lat, lon };
    source = 'naptan';
  } else if (hasGrid) {
    // The Elizabeth line central core stations land here.
    coords = gridToWgs84(east, north);
    source = 'naptan-grid';
  }
  if (!coords) return null;

  return {
    name: stripSuffix(row.name),
    lat: Number(coords.lat.toFixed(6)),
    lon: Number(coords.lon.toFixed(6)),
    source,
    status: row.status || 'active',
    locality: row.locality || null,
    parent: row.parent || null,
    town: row.town || null,
  };
}

/**
 * Build the indexes, and refuse to hand back coordinates the converter cannot
 * reproduce on real data.
 *
 * `byTiploc` holds active rows only, which is the behaviour
 * `generate-stations.mjs` has always had -- inactive rows are reachable only through
 * `resolve()`, and only after everything else has failed.
 */
export async function loadNaptan({ log = console.log } = {}) {
  const rows = await fetchRows(log);

  const byTiploc = new Map();
  const byName = new Map();
  const inactiveByTiploc = new Map();
  const inactiveByName = new Map();
  const checks = [];

  for (const row of rows) {
    if (!row.tiploc) continue;
    const place = toPlace(row, checks);
    if (!place) continue;

    const active = place.status === 'active';
    const tiplocIndex = active ? byTiploc : inactiveByTiploc;
    const nameIndex = active ? byName : inactiveByName;

    if (!tiplocIndex.has(row.tiploc)) tiplocIndex.set(row.tiploc, place);
    const key = canonicalName(place.name);
    if (key && !nameIndex.has(key)) nameIndex.set(key, place);
  }

  // Validate the grid conversion before trusting it for anything.
  const errors = checks.map((c) => haversineMetres(c.expected, c.got)).sort((a, b) => a - b);
  const median = errors[Math.floor(errors.length / 2)];
  const p99 = errors[Math.floor(errors.length * 0.99)];
  log(
    `  ${byTiploc.size} TIPLOCs with coordinates ` +
      `(grid converter checked on ${checks.length} rows: median ${median.toFixed(1)}m, p99 ${p99.toFixed(1)}m)`
  );
  if (median > 15) {
    throw new Error(
      `OSGB->WGS84 conversion is wrong (median error ${median.toFixed(1)}m). Refusing to emit coordinates.`
    );
  }

  /**
   * Resolve a station to a position, reporting which join found it.
   *
   * Order matters and is the order of trust: an exact TIPLOC on an active row, then
   * the station's name, then the same two against rows NaPTAN has marked inactive.
   * Barbican is the only station that reaches the last step, and a stale coordinate
   * for a station that exists beats no coordinate at all.
   */
  const resolve = (tiplocs, name) => {
    for (const tiploc of tiplocs ?? []) {
      const hit = byTiploc.get(String(tiploc).trim().toUpperCase());
      if (hit) return { ...hit, via: 'tiploc' };
    }
    const byNameHit = byName.get(canonicalName(name));
    if (byNameHit) return { ...byNameHit, via: 'name' };

    for (const tiploc of tiplocs ?? []) {
      const hit = inactiveByTiploc.get(String(tiploc).trim().toUpperCase());
      if (hit) return { ...hit, via: 'tiploc-inactive' };
    }
    const inactiveName = inactiveByName.get(canonicalName(name));
    if (inactiveName) return { ...inactiveName, via: 'name-inactive' };

    return null;
  };

  return {
    byTiploc,
    byName,
    resolve,
    stats: { rows: rows.length, active: byTiploc.size, gridChecks: checks.length, median, p99 },
  };
}
