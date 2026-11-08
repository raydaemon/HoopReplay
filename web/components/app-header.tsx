"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { type FormEvent, useEffect, useState } from "react";
import type { User } from "@supabase/supabase-js";
import { Bell, Building2, Search } from "lucide-react";
import { AccountControl } from "@/components/account-control";
import { accountLabel } from "@/lib/account";
import { cn } from "@/lib/utils";
import { useI18n } from "@/lib/i18n";

export type HeaderNotice = { id: string; title: string; subtitle: string; href: string };

/**
 * The header every page shares: brand on the left; search, workspace, notifications and the
 * account on the right. Search sends the query to the games list, and the bell lists the games
 * that are live or recording right now.
 */
export function AppHeader(
  { title = "HoopReplay", user, authReady, status, saving, notices = [], onSignIn, onSignUp, onAccountSettings }: {
    title?: string;
    user: User | null;
    authReady: boolean;
    status?: string;
    saving?: boolean;
    notices?: HeaderNotice[];
    onSignIn?: () => void;
    onSignUp?: () => void;
    onAccountSettings?: () => void;
  },
) {
  const router = useRouter();
  const { t } = useI18n();
  const [query, setQuery] = useState("");
  const [noticesOpen, setNoticesOpen] = useState(false);
  const signedIn = Boolean(user);

  useEffect(() => {
    if (!noticesOpen) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setNoticesOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [noticesOpen]);

  const search = (event: FormEvent) => {
    event.preventDefault();
    const term = query.trim();
    router.push(term ? `/games?q=${encodeURIComponent(term)}` : "/games");
  };

  return (
    <header className="appTop">
      <Link href="/" className="brand" aria-label={t("HoopReplay dashboard")}>
        <div className="eyebrow">{t("Courtside Control")}</div>
        <h1>{title}</h1>
      </Link>
      <div className="appTopTools">
        <form className="globalSearch" role="search" onSubmit={search}>
          <Search className="size-4" aria-hidden="true" />
          <input
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("Search games, players, teams…")}
            aria-label={t("Search games, players, teams")}
          />
        </form>
        {status && (
          <div className="syncPill" title={t(status)}>
            <span className={cn("size-2 rounded-full", signedIn ? "bg-[var(--green)]" : "bg-border")} aria-hidden="true" />
            <span>{saving ? t("Saving…") : t(status)}</span>
          </div>
        )}
        {signedIn && (
          <div className="workspaceChip" title={t("Workspace")}>
            <Building2 className="size-4" aria-hidden="true" />
            <span>{accountLabel(user)}</span>
          </div>
        )}
        <div className="notices">
          <button
            type="button"
            className="iconButton"
            aria-label={notices.length ? t("{count} active games", { count: notices.length }) : t("Notifications")}
            aria-haspopup="menu"
            aria-expanded={noticesOpen}
            onClick={() => setNoticesOpen((open) => !open)}
          >
            <Bell className="size-[18px]" aria-hidden="true" />
            {notices.length > 0 && <span className="noticeDot" aria-hidden="true" />}
          </button>
          {noticesOpen && (
            <>
              <div className="menuBackdrop" onMouseDown={() => setNoticesOpen(false)} />
              <div className="noticeMenu panel" role="menu" aria-label={t("Active games")}>
                <div className="noticeMenuTitle">{t("Active games")}</div>
                {notices.length === 0 && <p className="noticeEmpty">{t("Nothing is live right now.")}</p>}
                {notices.map((notice) => (
                  <Link key={notice.id} href={notice.href} role="menuitem" className="noticeRow" onClick={() => setNoticesOpen(false)}>
                    <strong>{notice.title}</strong>
                    <small>{t(notice.subtitle)}</small>
                  </Link>
                ))}
              </div>
            </>
          )}
        </div>
        <AccountControl
          user={user}
          authReady={authReady}
          onSignIn={onSignIn}
          onSignUp={onSignUp}
          onAccountSettings={onAccountSettings}
        />
      </div>
    </header>
  );
}
