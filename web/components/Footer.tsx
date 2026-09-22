import { Wordmark } from "./Glyph";

export function Footer() {
  return (
    <footer className="border-t border-line px-4 py-10 sm:px-6">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 text-sm text-fg-dim sm:flex-row">
        <div className="flex items-center gap-3">
          <Wordmark className="text-fg-muted" />
          <span>© 2026 Navi</span>
        </div>
        <nav className="flex items-center gap-6" aria-label="Legal">
          <a href="/privacy" className="transition-colors hover:text-fg">
            Privacy
          </a>
          <a href="/terms" className="transition-colors hover:text-fg">
            Terms
          </a>
          <a href="mailto:hello@navi.app" className="transition-colors hover:text-fg">
            Contact
          </a>
        </nav>
      </div>
    </footer>
  );
}
