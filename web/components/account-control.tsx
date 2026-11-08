"use client";

import Link from "next/link";
import { useState } from "react";
import type { User } from "@supabase/supabase-js";
import { accountLabel, initials } from "@/lib/account";
import { supabase } from "@/lib/supabase";
import { useI18n } from "@/lib/i18n";

/**
 * The top-right identity control, shared by every page: signed in it shows the account name with
 * its avatar and opens a menu; signed out it offers Sign in and Register. It never renders as
 * nothing, so the header always tells the user who they are or how to sign in.
 *
 * The sign-in form lives on the dashboard, so pages that do not host it leave the handlers out and
 * the buttons become links that ask the dashboard to open it.
 */
export function AccountControl(
  { user, authReady, onSignIn, onSignUp, onAccountSettings }: {
    user: User | null;
    authReady: boolean;
    onSignIn?: () => void;
    onSignUp?: () => void;
    onAccountSettings?: () => void;
  },
) {
  const [menuOpen, setMenuOpen] = useState(false);
  const { t } = useI18n();
  // Until the session is known, hold the space rather than flashing Sign in at a signed-in user.
  if (!authReady) return <div className="account" aria-hidden="true" />;
  const name = accountLabel(user);
  if (!user) {
    return (
      <div className="authActions">
        {onSignIn
          ? <button onClick={onSignIn}>{t("Sign in")}</button>
          : <Link href="/?auth=login">{t("Sign in")}</Link>}
        {onSignUp
          ? <button className="primary" onClick={onSignUp}>{t("Register")}</button>
          : <Link href="/?auth=signup" className="primary">{t("Register")}</Link>}
      </div>
    );
  }
  return (
    <div className="account">
      <button
        className="avatarButton"
        aria-haspopup="menu"
        aria-expanded={menuOpen}
        aria-label={t("Account menu")}
        onClick={() => setMenuOpen((open) => !open)}
      >
        <span className="avatar">{initials(name)}</span>
        <span className="accountName">{name}</span>
        <span aria-hidden="true">▾</span>
      </button>
      {menuOpen && (
        <>
          <div className="menuBackdrop" onMouseDown={() => setMenuOpen(false)} />
          <div className="accountMenu panel" role="menu">
            <div className="accountIdentity">
              <span className="avatar large">{initials(name)}</span>
              <div>
                <strong>{name}</strong>
                <small>{user.email}</small>
              </div>
            </div>
            {onAccountSettings
              ? (
                <button
                  role="menuitem"
                  onClick={() => {
                    setMenuOpen(false);
                    onAccountSettings();
                  }}
                >
                  <span>{t("Account settings")}</span>
                  <span aria-hidden="true">›</span>
                </button>
              )
              : (
                <Link
                  href="/?tab=settings"
                  role="menuitem"
                  className="accountMenuLink"
                  onClick={() => setMenuOpen(false)}
                >
                  <span>{t("Account settings")}</span>
                  <span aria-hidden="true">›</span>
                </Link>
              )}
            <button
              className="signOut"
              role="menuitem"
              onClick={() => {
                setMenuOpen(false);
                void supabase?.auth.signOut();
              }}
            >
              {t("Sign out")}
            </button>
          </div>
        </>
      )}
    </div>
  );
}
