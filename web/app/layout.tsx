import type { Metadata } from "next";
import "./tailwind.css";

export const metadata: Metadata = {
  title: "HoopReplay — Live basketball stats",
  description: "Record every basketball game, track every play, and sync live statistics across devices.",
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL ?? "https://hoopreplay-tawny.vercel.app"),
  openGraph: {
    title: "HoopReplay",
    description: "Record every game. Track every play.",
    images: [{ url: "/og.png", width: 1200, height: 630, alt: "HoopReplay live basketball scoreboard and statistics" }]
  },
  twitter: { card: "summary_large_image", title: "HoopReplay", description: "Record every game. Track every play.", images: ["/og.png"] }
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
