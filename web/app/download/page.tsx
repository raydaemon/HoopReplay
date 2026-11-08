import type { Metadata } from "next";
import { type AndroidRelease, DownloadContent } from "./download-content";

export const metadata: Metadata = {
  title: "Download HoopReplay",
  description: "Get HoopReplay on the App Store for iPhone and iPad or on Google Play for Android.",
};

const RELEASES_URL =
  "https://ugpkignlnssfllfbznlq.supabase.co/storage/v1/object/public/downloads/android/HoopReplay-releases.json";

async function getLatestAndroidRelease(): Promise<AndroidRelease | null> {
  try {
    const response = await fetch(RELEASES_URL, { cache: "no-store" });
    if (!response.ok) return null;
    const payload = (await response.json()) as { latest?: AndroidRelease };
    return payload.latest ?? null;
  } catch {
    return null;
  }
}

export default async function DownloadPage() {
  return <DownloadContent androidApk={await getLatestAndroidRelease()} />;
}
