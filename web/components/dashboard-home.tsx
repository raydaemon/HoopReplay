"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import {
  Activity,
  ArrowRight,
  BarChart3,
  CalendarDays,
  CheckCircle2,
  ChevronRight,
  Download,
  Flame,
  ListOrdered,
  Play,
  Plus,
  Smartphone,
  TrendingDown,
  TrendingUp,
  Trophy,
  User,
  Users,
  Zap,
} from "lucide-react";
import type { Snapshot } from "@/lib/types";
import {
  buildDashboard,
  type DashboardActivity,
  type DashboardGame,
  formatGameDate,
  relativeTime,
} from "@/lib/dashboard";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useI18n } from "@/lib/i18n";

const trendChoices = [4, 8, 12] as const;

/**
 * The dashboard body: welcome, KPI row, quick actions, recent and upcoming games, activity and the
 * recorded-plays trend. Every number comes from the snapshot through `buildDashboard`.
 */
export function DashboardHome(
  { data, accountName, loading, canCreateGame, onNewGame, onImport }: {
    data: Snapshot;
    accountName: string;
    /** True until the first snapshot has arrived, so the cards show skeletons instead of zeros. */
    loading: boolean;
    canCreateGame: boolean;
    onNewGame: () => void;
    onImport: () => void;
  },
) {
  const router = useRouter();
  const { t } = useI18n();
  const [trendWeeks, setTrendWeeks] = useState<(typeof trendChoices)[number]>(8);
  const model = useMemo(() => buildDashboard(data, trendWeeks, undefined, t), [data, trendWeeks, t]);
  const { summary, recentGames, upcomingGames, recentActivity, trend } = model;

  const kpis = [
    { label: "Teams", value: summary.teamCount, href: "/teams", Icon: Users },
    { label: "Players", value: summary.playerCount, href: "/players", Icon: User },
    { label: "Total Games", value: summary.totalGames, href: "/games", Icon: Trophy },
    { label: "Active / Upcoming", value: summary.activeGames, href: "/games", Icon: Play },
    { label: "Completed", value: summary.completedGames, href: "/games", Icon: CheckCircle2 },
    { label: "Recorded Plays", value: summary.recordedPlays, href: "/stats", Icon: ListOrdered },
  ];

  return (
    <div className="dashboard">
      <section className="dashWelcome">
        <div>
          <p className="dashEyebrow">{t("Good to see you")}</p>
          <h2>
            {t("Welcome back, {name}", { name: accountName.split(" ")[0] })}
            <span className="dashBall" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8">
                <circle cx="12" cy="12" r="9" />
                <path d="M12 3v18M3 12h18M6 6c3 2 4 8 2 12M18 6c-3 2-4 8-2 12" />
              </svg>
            </span>
          </h2>
          <p className="dashTagline">{t("Every game leaves a trail. Find. Analyze. Improve.")}</p>
        </div>
        <blockquote className="dashQuote">
          <p>{t("“Film doesn’t lie.”")}</p>
          <footer>{t("— Anonymous")}</footer>
        </blockquote>
      </section>

      <section className="kpiGrid" aria-label={t("Workspace summary")}>
        {kpis.map(({ label, value, href, Icon }) => (
          loading
            ? <div key={label} className="panel kpiCard skeletonCard" aria-hidden="true"><span className="skeleton kpiSkeletonIcon" /><span className="kpiBody"><span className="skeleton skeletonLine w-12" /><span className="skeleton skeletonLine w-20" /></span></div>
            : (
              <Link key={label} href={href} className="panel kpiCard">
                <span className="kpiIcon" aria-hidden="true"><Icon className="size-5" /></span>
                <span className="kpiBody">
                  <strong>{value}</strong>
                  <small>{t(label)}</small>
                </span>
                <ChevronRight className="kpiChevron size-4" aria-hidden="true" />
              </Link>
            )
        ))}
      </section>

      <section className="dashRow dashRowActions">
        <div className="panel dashCard">
          <header className="dashCardHeader">
            <span className="dashCardIcon" aria-hidden="true"><Zap className="size-[18px]" /></span>
            <div>
              <h3>{t("Quick Actions")}</h3>
              <p>{t("Get things done quickly and keep your team moving.")}</p>
            </div>
          </header>
          <div className="quickActions">
            <button
              type="button"
              className="quickAction primaryAction"
              onClick={() => (canCreateGame ? onNewGame() : router.push("/teams"))}
              title={canCreateGame ? undefined : t("Add two teams first")}
            >
              <span className="quickActionIcon" aria-hidden="true"><Plus className="size-5" /></span>
              <span><strong>{t("New Game")}</strong><small>{canCreateGame ? t("Record and analyze") : t("Add two teams first")}</small></span>
            </button>
            <button type="button" className="quickAction" onClick={onImport}>
              <span className="quickActionIcon" aria-hidden="true"><Download className="size-5" /></span>
              <span><strong>{t("Import Game")}</strong><small>{t("Bring in exported JSON")}</small></span>
            </button>
            <Link href="/teams?new=1" className="quickAction">
              <span className="quickActionIcon" aria-hidden="true"><Users className="size-5" /></span>
              <span><strong>{t("Add Team")}</strong><small>{t("Create a new team")}</small></span>
            </Link>
            <Link href="/games" className="quickAction">
              <span className="quickActionIcon" aria-hidden="true"><Play className="size-5" /></span>
              <span><strong>{t("View Games")}</strong><small>{t("See all games")}</small></span>
            </Link>
            <Link href="/download" className="quickAction">
              <span className="quickActionIcon" aria-hidden="true"><Smartphone className="size-5" /></span>
              <span><strong>{t("Get Android App")}</strong><small>{t("Download the APK")}</small></span>
            </Link>
          </div>
        </div>
        <div className="panel dashCard workspaceCard">
          <header className="dashCardHeader">
            <span className="dashCardIcon" aria-hidden="true"><BarChart3 className="size-[18px]" /></span>
            <div>
              <h3>{t("Workspace Overview")}</h3>
            </div>
          </header>
          <p className="workspaceText">
            {t("Your hub for games, teams, players, and video analysis. Track performance, review film, and help your athletes grow.")}
          </p>
          <Link href="/games" className="dashPrimaryButton">{t("Open Games")} <ArrowRight className="size-4" aria-hidden="true" /></Link>
          <CourtArt />
        </div>
      </section>

      <section className="dashRow dashRowLists">
        <div className="panel dashCard">
          <header className="dashCardHeader compact">
            <span className="dashCardIcon" aria-hidden="true"><Trophy className="size-[18px]" /></span>
            <h3>{t("Recent Games")}</h3>
            <Link href="/games" className="dashViewAll">{t("View all")} <ArrowRight className="size-3.5" aria-hidden="true" /></Link>
          </header>
          {loading
            ? <ListSkeleton rows={3} />
            : recentGames.length === 0
            ? (
              <EmptyState
                title={summary.totalGames === 0 ? t("No games yet") : t("No completed games yet")}
                text={summary.totalGames === 0
                  ? t("Create your first game to start recording and analyzing plays.")
                  : t("Finished games show up here with their final score.")}
                action={summary.totalGames === 0 ? { label: t("Create Game"), onClick: () => (canCreateGame ? onNewGame() : router.push("/teams")) } : undefined}
              />
            )
            : <ul className="dashList">{recentGames.map((game) => <RecentGameRow key={game.id} game={game} />)}</ul>}
        </div>

        <div className="panel dashCard">
          <header className="dashCardHeader compact">
            <span className="dashCardIcon" aria-hidden="true"><CalendarDays className="size-[18px]" /></span>
            <h3>{t("Active / Upcoming")}</h3>
            <Link href="/games" className="dashViewAll">{t("View all")} <ArrowRight className="size-3.5" aria-hidden="true" /></Link>
          </header>
          {loading
            ? <ListSkeleton rows={2} />
            : upcomingGames.length === 0
            ? (
              <EmptyState
                title={t("Nothing scheduled")}
                text={t("Games that are upcoming, live or recording appear here.")}
                action={{ label: t("New Game"), onClick: () => (canCreateGame ? onNewGame() : router.push("/teams")) }}
              />
            )
            : <ul className="dashList">{upcomingGames.map((game) => <UpcomingGameRow key={game.id} game={game} />)}</ul>}
        </div>

        <div className="panel dashCard" id="activity">
          <header className="dashCardHeader compact">
            <span className="dashCardIcon" aria-hidden="true"><Activity className="size-[18px]" /></span>
            <h3>{t("Recent Activity")}</h3>
            <Link href="/games" className="dashViewAll">{t("View all")} <ArrowRight className="size-3.5" aria-hidden="true" /></Link>
          </header>
          {loading
            ? <ListSkeleton rows={4} />
            : recentActivity.length === 0
            ? <EmptyState title={t("No recent activity.")} text={t("Recorded plays, new games and new teams show up here.")} />
            : <ul className="dashList activityList">{recentActivity.map((item) => <ActivityRow key={item.id} item={item} />)}</ul>}
        </div>
      </section>

      <section className="panel dashCard trendCard">
        <header className="dashCardHeader compact">
          <span className="dashCardIcon" aria-hidden="true"><BarChart3 className="size-[18px]" /></span>
          <div>
            <h3>{t("Recorded Plays Trend")}</h3>
            <p>{t("Number of plays recorded over the last {weeks} weeks.", { weeks: trend.weeks })}</p>
          </div>
          <Select value={String(trendWeeks)} onValueChange={(value) => setTrendWeeks(Number(value) as (typeof trendChoices)[number])}>
            <SelectTrigger className="ml-auto h-9 w-40 text-sm" aria-label={t("Trend period")}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {trendChoices.map((weeks) => <SelectItem key={weeks} value={String(weeks)}>{t("Last {weeks} weeks", { weeks })}</SelectItem>)}
            </SelectContent>
          </Select>
        </header>
        <div className="trendBody">
          {loading ? <div className="skeleton trendSkeleton" aria-hidden="true" /> : <TrendChart buckets={trend.buckets} />}
          <aside className="trendSummary">
            {loading
              ? <><span className="skeleton skeletonLine w-16" /><span className="skeleton skeletonLine w-24" /></>
              : (
                <>
                  <strong>{trend.current}</strong>
                  <span>{t("Recorded Plays")}</span>
                  <TrendDelta current={trend.current} previous={trend.previous} weeks={trend.weeks} />
                </>
              )}
          </aside>
        </div>
      </section>
    </div>
  );
}

function RecentGameRow({ game }: { game: DashboardGame }) {
  const { t } = useI18n();
  const winnerName = game.winner === "home" ? game.homeName : game.winner === "away" ? game.awayName : null;
  return (
    <li>
      <Link href={game.href} className="dashListRow gameRow">
        <span className="rowMark" aria-hidden="true"><Trophy className="size-4" /></span>
        <span className="rowBody">
          <strong>{game.title}</strong>
          <small>{formatGameDate(game.scheduledAt)}</small>
        </span>
        <span className="rowMeta">
          <span className="rowScore" aria-label={`${game.awayName} ${game.awayScore}, ${game.homeName} ${game.homeScore}`}>
            <b className={game.winner === "away" ? "won" : ""}>{game.awayScore}</b>
            <i>–</i>
            <b className={game.winner === "home" ? "won" : ""}>{game.homeScore}</b>
          </span>
          <span className={`resultBadge ${winnerName ? "win" : "tie"}`}>
            {winnerName ? <><CheckCircle2 className="size-3" aria-hidden="true" /><span className="sr-only">{t("Winner:")} </span>{winnerName}</> : t("Tie")}
          </span>
        </span>
        <ChevronRight className="rowChevron size-4" aria-hidden="true" />
      </Link>
    </li>
  );
}

function UpcomingGameRow({ game }: { game: DashboardGame }) {
  return (
    <li>
      <Link href={game.href} className="dashListRow gameRow">
        <span className="rowMark" aria-hidden="true">
          {game.statusTone === "upcoming" ? <CalendarDays className="size-4" /> : <Flame className="size-4" />}
        </span>
        <span className="rowBody">
          <strong>{game.title}</strong>
          <small>{formatGameDate(game.scheduledAt, true)}</small>
        </span>
        <span className="rowMeta">
          <span className={`statusBadge ${game.statusTone}`}>
            {game.statusTone !== "upcoming" && <span className="statusPulse" aria-hidden="true" />}
            {game.statusLabel}
          </span>
        </span>
        <ChevronRight className="rowChevron size-4" aria-hidden="true" />
      </Link>
    </li>
  );
}

function ActivityRow({ item }: { item: DashboardActivity }) {
  const { t } = useI18n();
  const Icon = item.kind === "plays" ? Play : item.kind === "completed" ? CheckCircle2 : item.kind === "team" ? Users : Trophy;
  const body = (
    <>
      <span className="rowMark" aria-hidden="true"><Icon className="size-4" /></span>
      <span className="rowBody">
        <strong>{item.title}</strong>
        <small>{item.subtitle} · <time dateTime={new Date(item.at).toISOString()}>{relativeTime(item.at, undefined, t)}</time></small>
      </span>
      <ChevronRight className="rowChevron size-4" aria-hidden="true" />
    </>
  );
  return <li>{item.href ? <Link href={item.href} className="dashListRow">{body}</Link> : <div className="dashListRow">{body}</div>}</li>;
}

function TrendChart({ buckets }: { buckets: { label: string; count: number }[] }) {
  const { t } = useI18n();
  const max = Math.max(1, ...buckets.map((bucket) => bucket.count));
  // Four divisions with a tidy step, so the tallest bar fills most of the chart.
  const magnitude = 10 ** Math.floor(Math.log10(Math.max(1, max / 4)));
  const step = [1, 2, 2.5, 5, 10].map((factor) => factor * magnitude).find((candidate) => candidate * 4 >= max) ?? magnitude * 10;
  const top = step * 4;
  const ticks = [4, 3, 2, 1, 0].map((index) => index * step);
  return (
    <figure className="trendChart" role="img" aria-label={t("Plays per week: {list}", { list: buckets.map((bucket) => `${bucket.label} ${bucket.count}`).join(", ") })}>
      <div className="trendAxis" aria-hidden="true">{ticks.map((tick) => <span key={tick}>{tick}</span>)}</div>
      <div className="trendBars" aria-hidden="true">
        {buckets.map((bucket) => (
          <div key={bucket.label} className="trendColumn">
            <div className="trendBarTrack">
              <div className="trendBar" style={{ height: `${Math.max(bucket.count > 0 ? 3 : 0, (bucket.count / top) * 100)}%` }} title={`${bucket.label}: ${bucket.count}`} />
            </div>
            <span className="trendLabel">{bucket.label}</span>
          </div>
        ))}
      </div>
    </figure>
  );
}

function TrendDelta({ current, previous, weeks }: { current: number; previous: number; weeks: number }) {
  const { t } = useI18n();
  if (previous === 0) {
    return <em className="trendDelta flat">{current > 0 ? t("New this period") : t("No plays yet")}<small>{t("vs. previous {weeks} weeks", { weeks })}</small></em>;
  }
  const change = Math.round(((current - previous) / previous) * 100);
  const up = change >= 0;
  return (
    <em className={`trendDelta ${up ? "up" : "down"}`}>
      {up ? <TrendingUp className="size-4" aria-hidden="true" /> : <TrendingDown className="size-4" aria-hidden="true" />}
      {up ? "+" : ""}{change}%
      <small>{t("vs. previous {weeks} weeks", { weeks })}</small>
    </em>
  );
}

function EmptyState({ title, text, action }: { title: string; text: string; action?: { label: string; onClick: () => void } }) {
  return (
    <div className="dashEmpty">
      <strong>{title}</strong>
      <p>{text}</p>
      {action && <button type="button" className="dashPrimaryButton" onClick={action.onClick}>{action.label}</button>}
    </div>
  );
}

function ListSkeleton({ rows }: { rows: number }) {
  return (
    <ul className="dashList" aria-hidden="true">
      {Array.from({ length: rows }, (_, index) => (
        <li key={index} className="dashListRow skeletonRow">
          <span className="skeleton rowMark" />
          <span className="rowBody"><span className="skeleton skeletonLine w-32" /><span className="skeleton skeletonLine w-20" /></span>
        </li>
      ))}
    </ul>
  );
}

/** The faint half-court in the workspace card's corner. */
function CourtArt() {
  return (
    <svg className="courtArt" viewBox="0 0 160 110" aria-hidden="true">
      <rect x="4" y="4" width="152" height="102" rx="6" />
      <path d="M80 4v102" />
      <circle cx="80" cy="55" r="16" />
      <path d="M4 32h32v46H4M156 32h-32v46h32" />
      <path d="M36 32a30 30 0 0 1 0 46M124 32a30 30 0 0 0 0 46" />
    </svg>
  );
}
