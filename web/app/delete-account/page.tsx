import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Delete Your Account — HoopReplay",
  description: "How to delete your HoopReplay account and the data associated with it.",
};

export default function DeleteAccountPage() {
  return (
    <main className="mx-auto max-w-3xl px-6 py-12 text-neutral-800">
      <h1 className="text-3xl font-semibold">Delete Your HoopReplay Account</h1>
      <p className="mt-4">
        HoopReplay (published by ConnectedAI LLC) lets you delete your account and all data synced to it at any
        time. This page explains how.
      </p>

      <h2 className="mt-8 text-xl font-semibold">How to delete your account</h2>
      <ol className="mt-2 list-decimal space-y-2 pl-6">
        <li>Sign in to HoopReplay.</li>
        <li>Go to Profile → Settings → Account → Delete Account.</li>
        <li>Confirm the deletion. Your account and associated synced data are permanently deleted immediately, and you are signed out.</li>
      </ol>

      <h2 className="mt-8 text-xl font-semibold">What is deleted</h2>
      <ul className="mt-2 list-disc space-y-1 pl-6">
        <li>Your account and sign-in credentials.</li>
        <li>All teams, players, games, scores, lineups, and statistics synced to your account.</li>
      </ul>

      <h2 className="mt-8 text-xl font-semibold">What is not affected</h2>
      <ul className="mt-2 list-disc space-y-1 pl-6">
        <li>
          Videos stored only in the device Photos library are controlled by iOS; delete those Photos items separately
          if they were exported there. App-local recordings are removed during account deletion.
        </li>
        <li>
          Standard server logs kept by our hosting providers for security, which are retained for a limited time
          and are not linked to your account after deletion.
        </li>
      </ul>

      <h2 className="mt-8 text-xl font-semibold">Deleting some data without deleting your account</h2>
      <p className="mt-2">Individual teams, players, and games can also be deleted inside the app without closing the account.</p>

      <p className="mt-8 text-sm text-neutral-500">
        See also our <a className="underline" href="/privacy">Privacy Policy</a>.
      </p>
    </main>
  );
}
