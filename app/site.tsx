import Link from 'next/link';

/**
 * Where people write to. Shown on the privacy and support pages, which the App Store
 * links to. Null shows "coming soon" rather than a made-up address.
 */
export const CONTACT_EMAIL: string | null = 'dazreil@gmail.com';

export function Contact() {
  return CONTACT_EMAIL ? <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> : <>the contact address, coming soon</>;
}

type Here = 'home' | 'privacy' | 'support';

export function Nav({ here }: { here: Here }) {
  const current = (page: Here) => (page === here ? ({ 'aria-current': 'page' } as const) : {});
  return (
    <nav className="nav">
      <Link href="/" className="mark" {...current('home')}>
        LAST TRAIN
      </Link>
      <Link href="/privacy" {...current('privacy')}>
        Privacy
      </Link>
      <Link href="/support" {...current('support')}>
        Support
      </Link>
    </nav>
  );
}

export function Footer() {
  return (
    <footer className="footer">
      Last Train is not made by, or linked to, National Rail or any train company. © 2026 Daryl Smith ·{' '}
      <Link href="/privacy">Privacy</Link> · <Link href="/support">Support</Link>
    </footer>
  );
}
