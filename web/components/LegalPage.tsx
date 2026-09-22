import Link from "next/link";
import { Wordmark } from "./Glyph";
import { Footer } from "./Footer";

export function LegalPage({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="relative">
      <header className="mx-auto flex h-16 max-w-3xl items-center px-4 sm:px-6">
        <Link href="/" className="text-lg" aria-label="Navi home">
          <Wordmark />
        </Link>
      </header>
      <main className="mx-auto max-w-3xl px-4 py-16 sm:px-6">
        <h1 className="h-section">{title}</h1>
        <div className="mt-8 space-y-4 text-fg-muted">{children}</div>
        <Link href="/" className="mt-10 inline-block text-sm text-accent hover:underline">
          ← Back to Navi
        </Link>
      </main>
      <Footer />
    </div>
  );
}
