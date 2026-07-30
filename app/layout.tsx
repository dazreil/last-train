import type { Metadata, Viewport } from 'next';
import { Geist_Mono, Inter_Tight } from 'next/font/google';
import RegisterServiceWorker from './components/RegisterServiceWorker';
import './globals.css';

/*
 * Rail Alphabet 2 is not licensable, so these stand in honestly rather than
 * approximating it badly.
 *
 * Both are self-hosted by next/font -- no request to Google at runtime -- and cut
 * to single weights and the latin subset. Font payload is not a vanity concern
 * here: the app exists to open in two seconds on a platform with one bar of
 * signal, and `display: swap` means the times render in a system face rather than
 * waiting on a download.
 *
 * Geist Mono rather than Martian Mono, which the design names first but allows
 * falling back from "if it reads too wide at large sizes". It does: Martian's
 * advance is 0.66em, so a 44px time eats 145px of a 375pt screen and forces every
 * station name onto two lines, which lifts the last-train block off the bottom of
 * the screen.
 */
const mono = Geist_Mono({
  subsets: ['latin'],
  weight: ['700'],
  display: 'swap',
  variable: '--font-mono',
});

const sans = Inter_Tight({
  subsets: ['latin'],
  weight: ['600', '700'],
  display: 'swap',
  variable: '--font-sans',
});

export const metadata: Metadata = {
  title: 'Last Train',
  description: 'First and last direct train between two stations.',
  applicationName: 'Last Train',
  appleWebApp: {
    capable: true,
    title: 'Last Train',
    // Matches --bg so the status bar does not sit on a pale strip in dark mode.
    statusBarStyle: 'black-translucent',
  },
  // Personal tool; nothing here should be indexed.
  robots: { index: false, follow: false },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  // Installed as a home-screen app, so it should feel like one.
  viewportFit: 'cover',
  themeColor: [
    { media: '(prefers-color-scheme: dark)', color: '#0b0d10' },
    { media: '(prefers-color-scheme: light)', color: '#f4f6f8' },
  ],
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en-GB" className={`${mono.variable} ${sans.variable}`}>
      <body>
        {children}
        <RegisterServiceWorker />
      </body>
    </html>
  );
}
