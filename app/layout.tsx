import type { Metadata, Viewport } from 'next';
import RegisterServiceWorker from './components/RegisterServiceWorker';
import './globals.css';

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
    <html lang="en-GB">
      <body>
        {children}
        <RegisterServiceWorker />
      </body>
    </html>
  );
}
