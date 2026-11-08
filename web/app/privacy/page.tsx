import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Privacy Policy — HoopReplay",
  description: "How HoopReplay collects, uses, and protects your data.",
};

const CONTACT_EMAIL = "myconnectedai@gmail.com";
const LAST_UPDATED = "September 14, 2026";

export default function PrivacyPage() {
  return (
    <main className="mx-auto max-w-3xl px-6 py-12 text-neutral-800">
      <h1 className="text-3xl font-semibold">HoopReplay Privacy Policy</h1>
      <p className="mt-2 text-sm text-neutral-500">Last updated: {LAST_UPDATED}</p>

      <p className="mt-6">
        HoopReplay is a basketball scoring, statistics, and game-recording app for Android, iOS, and the web,
        published by ConnectedAI LLC (&quot;we&quot;, &quot;us&quot;). This policy explains what information the
        app handles, why, and the choices you have.
      </p>

      <h2 className="mt-8 text-xl font-semibold">Summary</h2>
      <ul className="mt-2 list-disc space-y-1 pl-6">
        <li>You can use HoopReplay without an account. All teams, players, games, and statistics are stored on your device.</li>
        <li>Video you record stays on your device. We never upload, view, or store your videos.</li>
        <li>If you sign in, your email address and your team, player, game, and statistics data are synced to our cloud so you can access them on other devices.</li>
        <li>We do not show ads, do not sell your data, and do not share it with third parties for marketing.</li>
      </ul>

      <h2 className="mt-8 text-xl font-semibold">Information we collect</h2>
      <h3 className="mt-4 font-semibold">Account information (optional)</h3>
      <p className="mt-1">
        When you create an account or sign in, we collect your email address and, if you use Google sign-in, the
        name and email provided by Google. This is used only to identify your account and keep your synced data
        separate from other users.
      </p>
      <h3 className="mt-4 font-semibold">Game data you enter</h3>
      <p className="mt-1">
        Team names, player names and jersey numbers, game schedules, scores, lineups, and play-by-play statistics
        that you enter into the app. Player names typically belong to youth or amateur athletes; you are responsible
        for having permission to record them. This data is stored on your device and, only if you sign in and
        choose to sync, in our cloud database.
      </p>
      <h3 className="mt-4 font-semibold">Video and audio</h3>
      <p className="mt-1">
        The Android and iOS apps ask for camera and microphone permission so you can record games. Recordings are
        written to your device&apos;s local storage (for example, the Movies or Photos library). We do not transmit,
        access, or store recordings on our servers.
      </p>
      <h3 className="mt-4 font-semibold">Diagnostic information</h3>
      <p className="mt-1">
        We do not include third-party analytics or advertising SDKs. Our hosting and database providers may keep
        standard server logs (such as IP address and request time) for security and reliability.
      </p>

      <h2 className="mt-8 text-xl font-semibold">How we use information</h2>
      <ul className="mt-2 list-disc space-y-1 pl-6">
        <li>To provide the app&apos;s features: scoring, statistics, exports, and recording.</li>
        <li>To sync your data between devices and the web app when you are signed in.</li>
        <li>To secure accounts and prevent abuse.</li>
        <li>To respond to support requests you send us.</li>
      </ul>

      <h2 className="mt-8 text-xl font-semibold">Sharing</h2>
      <p className="mt-2">
        We share data only with service providers that host the app and database on our behalf (Vercel for the web
        app and Supabase for authentication and data storage). They process data under our instructions and their
        own security commitments. We do not sell personal information and do not share it with advertisers.
      </p>

      <h2 className="mt-8 text-xl font-semibold">Security</h2>
      <p className="mt-2">
        Data in transit between the app and our servers is encrypted with TLS. Synced data is stored in a database
        with per-user access controls so only your account can read your data.
      </p>

      <h2 className="mt-8 text-xl font-semibold">Retention and deletion</h2>
      <p className="mt-2">
        Local data stays on your device until you delete it in the app or uninstall the app. Synced data stays in
        your account until you delete it. You can delete teams, players, and games from within the app, and those
        deletions sync to the cloud. To delete your account and all synced data, email us at{" "}
        <a className="underline" href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> from the address on your
        account; we will complete the deletion within 30 days.
      </p>

      <h2 className="mt-8 text-xl font-semibold">Children</h2>
      <p className="mt-2">
        HoopReplay is intended for adults such as coaches, team managers, and parents. We do not knowingly collect
        personal information from children under 13. If you believe a child has created an account, contact us and
        we will delete it.
      </p>

      <h2 className="mt-8 text-xl font-semibold">Changes</h2>
      <p className="mt-2">
        We may update this policy from time to time. The latest version is always available at this page, and the
        date at the top shows when it was last changed.
      </p>

      <h2 className="mt-8 text-xl font-semibold">Contact</h2>
      <p className="mt-2">
        Questions or requests: <a className="underline" href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>
      </p>
    </main>
  );
}
