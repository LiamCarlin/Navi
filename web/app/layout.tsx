import type { Metadata, Viewport } from "next";
import { EB_Garamond, Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { SmoothScroll } from "@/components/motion/SmoothScroll";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });
const garamond = EB_Garamond({ variable: "--font-garamond", subsets: ["latin"], weight: ["400", "500"], style: ["normal", "italic"] });

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
  openGraph: { title, description, url: siteUrl, siteName: "Navi", type: "website" },
  twitter: { card: "summary_large_image", title, description },
  robots: { index: true, follow: true },
};

export const viewport: Viewport = {
  themeColor: "#3d8fe6",
  colorScheme: "light",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable} ${garamond.variable}`}>
      <body className="min-h-dvh antialiased">
        <SmoothScroll />
        {children}
      </body>
    </html>
  );
}
