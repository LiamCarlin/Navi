import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono, Newsreader } from "next/font/google";
import { SmoothScroll } from "@/components/motion/SmoothScroll";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });
const newsreader = Newsreader({ variable: "--font-newsreader", subsets: ["latin"], style: ["normal", "italic"], axes: ["opsz"] });

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "https://navi.app";
const title = "Navi: ⌘Space, but it does things";
const description =
  "Navi replaces Spotlight on your Mac. Open apps, get answers, and hand it tasks it does in the background, by keyboard or voice.";

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
    { media: "(prefers-color-scheme: dark)", color: "#0b0b0c" },
    { media: "(prefers-color-scheme: light)", color: "#f4f3ee" },
  ],
  colorScheme: "dark light",
  width: "device-width",
  initialScale: 1,
};

/* Runs before first paint: a stored choice wins, else the system scheme. Every storage access is guarded. */
const themeScript = `(function(){try{var s=localStorage.getItem("navi-theme");var t=s;if(t!=="light"&&t!=="dark"){t=matchMedia("(prefers-color-scheme: light)").matches?"light":"dark"}document.documentElement.dataset.theme=t;if(s==="light"||s==="dark"){var m=document.createElement("meta");m.name="theme-color";m.content=s==="light"?"#f4f3ee":"#0b0b0c";document.head.prepend(m)}}catch(e){}})();`;

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable} ${newsreader.variable}`} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body className="min-h-dvh antialiased">
        <SmoothScroll />
        {children}
        <div className="grain" aria-hidden="true" />
      </body>
    </html>
  );
}
