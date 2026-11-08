"use client";

import Link from "next/link";
import type { ComponentType } from "react";
import {
  BarChart3,
  Download,
  LayoutDashboard,
  type LucideProps,
  Play,
  Settings,
  Shield,
  User,
  Users,
} from "lucide-react";
import { useI18n } from "@/lib/i18n";

type NavIcon = ComponentType<LucideProps>;

/**
 * The left panel's main sections. Each one is a route of its own so the panel behaves the same
 * whichever page you arrive on.
 */
export const sections = [
  { key: "dashboard", label: "Dashboard", Icon: LayoutDashboard as NavIcon, href: "/" },
  { key: "games", label: "Games", Icon: Play as NavIcon, href: "/games" },
  { key: "teams", label: "Teams", Icon: Users as NavIcon, href: "/teams" },
  { key: "clubs", label: "Clubs", Icon: Shield as NavIcon, href: "/clubs" },
  { key: "players", label: "Players", Icon: User as NavIcon, href: "/players" },
  { key: "stats", label: "Stats", Icon: BarChart3 as NavIcon, href: "/stats" },
] as const;

/**
 * Import and settings are tools rather than places, so they sit below the sections. They are still
 * tabs of the dashboard and are addressed with a `tab` query parameter.
 */
export const utilities = [
  { key: "import", label: "Import", Icon: Download as NavIcon, href: "/?tab=import" },
  { key: "settings", label: "Settings", Icon: Settings as NavIcon, href: "/?tab=settings" },
] as const;

export const navItems = [...sections, ...utilities];

export type SectionKey = (typeof navItems)[number]["key"];

/** The keys the dashboard page keeps as in-place tabs rather than routes. */
const dashboardTabs: SectionKey[] = ["dashboard", "import", "settings"];

/**
 * The left panel. Resource pages render every entry as a link; the dashboard passes `onSelect`
 * so its own tabs (dashboard, import, settings) switch in place instead of reloading.
 */
export function SectionNav(
  { current, onSelect }: { current?: SectionKey; onSelect?: (key: SectionKey) => void },
) {
  const { t } = useI18n();
  const link = ({ key, label, Icon, href }: (typeof navItems)[number]) => {
    const active = key === current;
    const body = (
      <>
        <span className="tabGlyph" aria-hidden="true"><Icon className="size-[18px]" strokeWidth={2.2} /></span>
        <span>{t(label)}</span>
      </>
    );
    if (onSelect && dashboardTabs.includes(key)) {
      return (
        <button
          key={key}
          type="button"
          className={active ? "tabLink active" : "tabLink"}
          aria-current={active ? "page" : undefined}
          onClick={() => onSelect(key)}
        >
          {body}
        </button>
      );
    }
    return (
      <Link
        key={key}
        href={href}
        className={active ? "tabLink active" : "tabLink"}
        aria-current={active ? "page" : undefined}
      >
        {body}
      </Link>
    );
  };
  return (
    <nav className="tabNav" aria-label={t("Sections")}>
      {sections.map(link)}
      <span className="tabNavDivider" aria-hidden="true" />
      {utilities.map(link)}
      <div className="tabNavFooter" aria-hidden="true">
        <span className="tabNavFooterMark">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8">
            <circle cx="12" cy="12" r="9" />
            <path d="M12 3v18M3 12h18M6 6c3 2 4 8 2 12M18 6c-3 2-4 8-2 12" />
          </svg>
        </span>
        <strong>{t("Better film.")}<br />{t("Stronger teams.")}</strong>
        <small>{t("Turn every game into growth.")}</small>
      </div>
    </nav>
  );
}
