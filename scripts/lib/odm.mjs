/**
 * Reading the ORR Origin-Destination Matrix.
 *
 * One row per station pair with an estimated count of journeys in a financial year,
 * from ticket sales. About 1.6 million rows and 160 MiB for 2024-25, so it is streamed
 * a line at a time rather than read whole.
 *
 * Two facts about the file shape everything downstream:
 *
 *   - **It is symmetric.** Upminster to Fenchurch Street and Fenchurch Street to Upminster
 *     carry the same number, 636,457. A count is journeys *between* two stations, so
 *     "popular from here" means "popular pair", which for this purpose is the same thing.
 *   - **It excludes ticketless journeys.** Tapping a bank card in London is ticketless,
 *     so London flows are undercounted. Checked before building on it: Fenchurch Street
 *     still comes out joint first from Upminster, within 0.1% of West Ham.
 */

import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';

/**
 * One CSV line into cells, honouring quotes.
 *
 * Needed: local-authority names like "Bristol, City of" arrive quoted with a comma inside,
 * and a plain split would shift every column after it -- reading a station name as the
 * journey count, silently. Doubled quotes inside a quoted cell are an escaped quote.
 */
export function splitCsvLine(line) {
  const cells = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"' && line[i + 1] === '"') { cell += '"'; i += 1; }
      else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') { cells.push(cell); cell = ''; }
    else cell += ch;
  }
  cells.push(cell);
  return cells;
}

/** Header names this relies on. Checked on read, so a renamed column fails loudly. */
const REQUIRED = ['Financial_Year', 'origin_tlc', 'destination_tlc', 'journeys'];

/**
 * Journeys between every pair, keyed by origin CRS then destination CRS.
 *
 * Summed rather than overwritten, in case a year's file ever splits one pair across
 * several rows — by route or ticket type, as older matrices did.
 */
export async function readOdm(path) {
  const lines = createInterface({ input: createReadStream(path), crlfDelay: Infinity });
  let columns = null;
  let year = null;
  let rows = 0;
  const flows = new Map();

  for await (const line of lines) {
    if (!line) continue;
    const cells = splitCsvLine(line);
    if (!columns) {
      columns = Object.fromEntries(cells.map((name, i) => [name.trim(), i]));
      const missing = REQUIRED.filter((name) => !(name in columns));
      if (missing.length) throw new Error(`ODM file is missing columns: ${missing.join(', ')}`);
      continue;
    }
    if (cells.length !== Object.keys(columns).length) {
      throw new Error(`Line ${rows + 2} has ${cells.length} cells, the header ${Object.keys(columns).length}.`);
    }

    const from = cells[columns.origin_tlc]?.trim();
    const to = cells[columns.destination_tlc]?.trim();
    const journeys = Number(cells[columns.journeys]);
    year ??= cells[columns.Financial_Year]?.trim();
    rows += 1;
    if (!from || !to || from === to || !Number.isFinite(journeys) || journeys <= 0) continue;

    let byDestination = flows.get(from);
    if (!byDestination) flows.set(from, (byDestination = new Map()));
    byDestination.set(to, (byDestination.get(to) ?? 0) + journeys);
  }

  return { flows, year, rows };
}

/** The `keep` busiest destinations from each origin, busiest first. */
export function busiest(flows, keep) {
  const out = {};
  for (const [from, byDestination] of flows) {
    out[from] = [...byDestination.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, keep);
  }
  return out;
}
