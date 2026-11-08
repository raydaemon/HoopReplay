"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import type { User } from "@supabase/supabase-js";
import { isConfigured } from "@/lib/supabase";
import { useI18n } from "@/lib/i18n";
import { AppHeader } from "@/components/app-header";
import { type SectionKey, SectionNav } from "@/components/section-nav";

/**
 * Chrome shared by the resource pages. It reuses the dashboard's header and left section nav so
 * moving between the dashboard and /teams, /players or /games keeps the same frame. Pages without a
 * nav entry (such as /download) omit `current`; they show no data banners either.
 */
export function RestShell(
  { current, title, status, saving, user, authReady, children }: {
    current?: SectionKey;
    title: string;
    status: string;
    saving: boolean;
    user: User | null;
    authReady: boolean;
    children: ReactNode;
  },
) {
  const { t } = useI18n();
  const signedIn = Boolean(user);
  const [signInBefore, signInAfter] = t("Sign in on the {dashboard} to load and edit your data.").split("{dashboard}");
  return (
    <main className="shell">
      <AppHeader title={title} user={user} authReady={authReady} status={status} saving={saving} />
      <div className="appBody">
        <SectionNav current={current} />
        <div className="tabPanel">
          <div className="flex w-full flex-col gap-4">
            {current && !isConfigured && (
              <RestError>
                {t("Supabase is not configured. Add the project URL, publishable key, and sync space to your environment before this page can read or write anything.")}
              </RestError>
            )}
            {current && isConfigured && authReady && !signedIn && (
              <RestError>
                {signInBefore}<Link href="/" className="underline">{t("dashboard")}</Link>{signInAfter}
              </RestError>
            )}
            {children}
          </div>
        </div>
      </div>
    </main>
  );
}

/** Placeholder shown in place of a detail card while the cloud snapshot is still on its way. */
export function RestLoading({ label = "Loading…" }: { label?: string }) {
  const { t } = useI18n();
  return (
    <div role="status" aria-live="polite" className="rounded-lg border bg-card px-5 py-4">
      <span className="sr-only">{t(label)}</span>
      <span aria-hidden="true" className="skeleton skeletonLine" style={{ width: "40%", height: 18 }} />
      <span aria-hidden="true" className="skeleton skeletonLine" style={{ width: "70%" }} />
      <span aria-hidden="true" className="skeleton skeletonLine" style={{ width: "55%" }} />
    </div>
  );
}

/** The single error banner style shared by the shell and every resource page. */
export function RestError({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-lg bg-[#fdeaec] px-3.5 py-2.5 text-[13px] font-semibold text-[#8d2130]">
      {children}
    </div>
  );
}
