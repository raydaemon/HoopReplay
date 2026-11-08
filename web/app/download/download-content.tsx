"use client";

import { RestShell } from "../rest-shell";
import { useSnapshot } from "@/lib/use-snapshot";
import { Card, CardContent } from "@/components/ui/card";

export type AndroidRelease = {
  version: string;
  versionCode: number;
  sizeMb: string;
  minAndroid: string;
  sha256: string;
  url: string;
};

const APP_STORE_URL = "https://apps.apple.com/app/hoopreplay/id6811926080";
// Brand marks from simple-icons (CC0).
const APPLE_LOGO_PATH =
  "M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701";
const GOOGLE_PLAY_LOGO_PATH =
  "M22.018 13.298l-3.919 2.218-3.515-3.493 3.543-3.521 3.891 2.202a1.49 1.49 0 0 1 0 2.594zM1.337.924a1.486 1.486 0 0 0-.112.568v21.017c0 .217.045.419.124.6l11.155-11.087L1.337.924zm12.207 10.065l3.258-3.238L3.45.195a1.466 1.466 0 0 0-.946-.179l11.04 10.973zm0 2.067l-11 10.933c.298.036.612-.016.906-.183l13.324-7.54-3.23-3.21z";
const GOOGLE_PLAY_URL = "https://play.google.com/store/apps/details?id=com.hoopreplay.android";

export function DownloadContent({ androidApk }: { androidApk: AndroidRelease | null }) {
  const { user, authReady, saving, status } = useSnapshot();
  return (
    <RestShell title="Download" status={status} saving={saving} user={user} authReady={authReady}>
      <Card>
        <CardContent className="max-w-3xl pt-6">
          <h1 className="text-3xl font-semibold">Download HoopReplay</h1>
          <p className="mt-4">
            HoopReplay records basketball games, keeps score, and tracks every player&apos;s statistics live. Get it
            free on your phone or tablet.
          </p>

          <div className="mt-8 flex flex-wrap gap-3">
            <a
              href={APP_STORE_URL}
              className="inline-flex items-center rounded-lg bg-black no-underline px-6 py-3 text-lg font-semibold whitespace-nowrap text-white hover:bg-neutral-800"
            >
              <svg viewBox="0 0 24 24" className="mr-3 size-6 fill-current" aria-hidden="true">
                <path d={APPLE_LOGO_PATH} />
              </svg>
              Download on the App Store
            </a>
            <a
              href={GOOGLE_PLAY_URL}
              className="inline-flex items-center rounded-lg bg-black no-underline px-6 py-3 text-lg font-semibold whitespace-nowrap text-white hover:bg-neutral-800"
            >
              <svg viewBox="0 0 24 24" className="mr-3 size-6 fill-current" aria-hidden="true">
                <path d={GOOGLE_PLAY_LOGO_PATH} />
              </svg>
              Get it on Google Play
            </a>
          </div>

          <h2 className="mt-10 text-xl font-semibold">iPhone and iPad</h2>
          <ol className="mt-2 list-decimal space-y-2 pl-6">
            <li>
              Open this page on your iPhone or iPad and tap <strong>Download on the App Store</strong>, or search for
              &ldquo;HoopReplay&rdquo; in the App Store.
            </li>
            <li>Tap Get, then confirm with Face ID, Touch ID, or your Apple Account password.</li>
            <li>Requires iOS 17 or later.</li>
          </ol>

          <h2 className="mt-10 text-xl font-semibold">Android</h2>
          <ol className="mt-2 list-decimal space-y-2 pl-6">
            <li>
              Open this page on your Android phone or tablet and tap <strong>Get it on Google Play</strong>, or search
              for &ldquo;HoopReplay&rdquo; in the Play Store.
            </li>
            <li>Tap Install. Updates arrive automatically through Google Play.</li>
          </ol>

          <h2 className="mt-12 text-xl font-semibold">Android APK (direct download)</h2>
          <p className="mt-2">
            If Google Play is not available on your device, you can install the APK directly instead.
          </p>

          {androidApk ? (
            <>
              <a
                href={androidApk.url}
                className="mt-4 inline-flex items-center rounded-lg bg-orange-600 no-underline px-6 py-3 text-lg font-semibold text-white hover:bg-orange-700"
                download={`HoopReplay-${androidApk.version}.apk`}
              >
                Download APK (v{androidApk.version}, {androidApk.sizeMb} MB)
              </a>

              <p className="mt-3 text-sm text-neutral-500">
                Requires {androidApk.minAndroid} or later. Package <code>com.hoopreplay.android</code>, version code{" "}
                {androidApk.versionCode}.
              </p>
            </>
          ) : (
            <p className="mt-8 rounded-lg bg-neutral-100 p-4 text-neutral-600">
              The latest APK is temporarily unavailable.
            </p>
          )}

          <h3 className="mt-8 text-lg font-semibold">How to install the APK</h3>
          <ol className="mt-2 list-decimal space-y-2 pl-6">
            <li>Open this page on your Android phone or tablet and tap the download button above.</li>
            <li>When the download finishes, open the file from the notification or from your Files app.</li>
            <li>
              If Android asks for permission to install apps from this source (Chrome or Files), allow it, then tap
              Install.
            </li>
            <li>Open HoopReplay. Camera and microphone access is only requested when you tap Record on a game.</li>
          </ol>

          <h3 className="mt-8 text-lg font-semibold">Verify the download</h3>
          <p className="mt-2">The APK is signed by ConnectedAI LLC. Its SHA-256 checksum is:</p>
          <pre className="mt-2 overflow-x-auto rounded bg-neutral-100 p-3 text-xs">
            {androidApk?.sha256 ?? "Unavailable"}
          </pre>

          <h3 className="mt-8 text-lg font-semibold">Updating</h3>
          <p className="mt-2">
            Newer versions posted here install over this one and keep your teams, games, and statistics. If you later
            switch to the Google Play version and Android reports a conflict, uninstall the APK version first; sync your
            games to your account before you do so nothing is lost.
          </p>

          <p className="mt-10 text-sm text-neutral-500">
            See also the{" "}
            <a className="underline" href="/privacy">
              Privacy Policy
            </a>
            .
          </p>
        </CardContent>
      </Card>
    </RestShell>
  );
}
