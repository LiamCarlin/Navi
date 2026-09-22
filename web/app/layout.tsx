import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "https://navi.app";
const title = "Navi — Press ⌘Space. Say what you want.";
const description =
  "Navi opens apps, answers questions, and does things on your Mac — by keyboard or voice, in under a second.";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title,
  description,
  applicationName: "Navi",
  keywords: ["Navi", "macOS", "Spotlight", "launcher", "assistant", "Mac"],
  openGraph: {
    title,
    description,
    url: siteUrl,
    siteName: "Navi",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title,
    description,
  },
  robots: { index: true, follow: true },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: dark)", color: "#0a0a0b" },
    { media: "(prefers-color-scheme: light)", color: "#f7f7f5" },
  ],
  colorScheme: "dark light",
  width: "device-width",
  initialScale: 1,
};

/* Runs before first paint: a stored choice wins, else the system scheme. Every storage access is guarded. */
const themeScript = `(function(){try{var t=localStorage.getItem("navi-theme");if(t!=="light"&&t!=="dark"){t=matchMedia("(prefers-color-scheme: light)").matches?"light":"dark"}document.documentElement.dataset.theme=t}catch(e){}})();`;

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable}`} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body className="min-h-dvh antialiased">{children}</body>
    </html>
  );
}
