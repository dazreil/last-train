/**
 * Which host is allowed to answer as the API.
 *
 * Vercel mints a permanent URL for every deployment — `last-train-<hash>-…` — and those
 * URLs keep serving their own build forever. Measured on 7 August 2026: three of them,
 * one preview and two production, all answering HTTP 200 and all still reporting the
 * last train south from Upminster as 18:34. The correct answer that evening was 00:33.
 * A board that is six hours wrong is worse than one that is down, because nothing about
 * it looks broken.
 *
 * The Vercel-side fix is not available on the Hobby plan: its only control is a single
 * "Require Log In" toggle covering *every* deployment including the alias the app talks
 * to, which is the setting that broke the phone in the first place. Scoped protection
 * is a paid feature. So the line is drawn here instead, where it costs nothing.
 *
 * **The alias answers; the hashed URLs do not.** `last-train-dazreils-projects.vercel.app`
 * is what the app is built against and what a browser is sent to. Everything else gets
 * told where the API actually lives.
 *
 * This cannot retire the deployments that already exist — they were built before it and
 * carry their own copy of the old code. Those have to be deleted in the dashboard, once.
 * What this does is make sure the problem stops accumulating.
 */

/** The deployment the app is built against. Mirrors `BOARD_API_BASE_URL` in `ios/project.yml`. */
export const CANONICAL_HOST = 'last-train-dazreils-projects.vercel.app';

/**
 * Loopback, so `npm run dev` and the simulator's Debug build keep working.
 *
 * Matched on the hostname alone: the port varies and carries no authority.
 */
const LOOPBACK = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);

/**
 * Whether a `Host` header belongs to the deployment that should be answering.
 *
 * `canonical` is a parameter rather than a constant read so the rule can be tested
 * without the environment, and so a fork pointing at its own deployment only has one
 * value to change. An empty `canonical` disables the check entirely, which is what any
 * environment that has not been told its own name should do — refusing every request
 * because a variable is missing would be a worse failure than the one being prevented.
 */
export function isLiveHost(host: string | null | undefined, canonical = CANONICAL_HOST): boolean {
  if (!canonical) return true;

  const name = hostname(host);
  if (!name) return false;

  return name === hostname(canonical) || LOOPBACK.has(name);
}

/**
 * The host without its port, lowercased.
 *
 * `Host` arrives as `example.com`, `example.com:3000` or `[::1]:3000`, and comparing the
 * raw string would treat `localhost:3000` and `localhost:3001` as different authorities
 * when they are the same machine.
 */
function hostname(host: string | null | undefined): string {
  if (!host) return '';

  const trimmed = host.trim().toLowerCase();
  // IPv6 literals are bracketed, and the brackets are part of the host, not the port.
  if (trimmed.startsWith('[')) {
    const close = trimmed.indexOf(']');
    return close === -1 ? trimmed : trimmed.slice(0, close + 1);
  }

  const colon = trimmed.indexOf(':');
  return colon === -1 ? trimmed : trimmed.slice(0, colon);
}
