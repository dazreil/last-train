import type { Metadata, Viewport } from 'next';
// Latin subsets only, bundled with the site from npm. Loaded through `next/font/google`
// the build fetched them from Google, and on 27 September 2026 that fetch failed and took
// a server fix down with it. Nothing here needs the network to build.
import '@fontsource/doto/latin-900.css';
import '@fontsource/nunito/latin-500.css';
import '@fontsource/nunito/latin-600.css';
import '@fontsource/nunito/latin-700.css';
import '@fontsource/nunito/latin-800.css';
import './globals.css';

/*
 * The site: a home page, the privacy policy and support, which the App Store asks for by
 * address. The board itself lives in the iOS app; the web board this layout used to
 * carry was removed on 25 September 2026.
 *
 * Doto stands in for the app's LED face and is used for times only. Both fonts are served
 * from this site, so a page makes no request to Google.
 */

export const metadata: Metadata = {
  title: { default: 'Last Train', template: '%s · Last Train' },
  description: 'Know your last train home, and the fastest one there. An iPhone app for trains in Great Britain.',
  applicationName: 'Last Train',
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  // Dark only, like the app.
  colorScheme: 'dark',
  themeColor: '#07090f',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en-GB">
      <body>{children}</body>
    </html>
  );
}
