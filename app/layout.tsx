import type { Metadata, Viewport } from 'next';
import { Doto, Nunito } from 'next/font/google';
import './globals.css';

/*
 * The site: a home page, the privacy policy and support, which the App Store asks for by
 * address. The board itself lives in the iOS app; the web board this layout used to
 * carry was removed on 25 September 2026.
 *
 * Doto stands in for the app's LED face and is used for times only. Both fonts are
 * self-hosted by next/font, so a page makes no request to Google.
 */
const led = Doto({ subsets: ['latin'], weight: ['900'], display: 'swap', variable: '--font-led' });
const sans = Nunito({ subsets: ['latin'], weight: ['500', '600', '700', '800'], display: 'swap', variable: '--font-sans' });

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
    <html lang="en-GB" className={`${led.variable} ${sans.variable}`}>
      <body>{children}</body>
    </html>
  );
}
