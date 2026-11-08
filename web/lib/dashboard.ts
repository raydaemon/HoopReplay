import type { Game, Snapshot } from "./types";
import { format } from "./i18n-core";

/** `t` from `useI18n`; the default keeps every label English. */
type Translate = (key: string, vars?: Record<string, string | number>) => string;

/** The headline numbers on the dashboard. Everything is derived from the snapshot, never typed in. */
export type DashboardSummary = {
  teamCount: number;
  playerCount: number;
  totalGames: number;
  activeGames: number;
  completedGames: number;
  recordedPlays: number;
};

export type DashboardGame = {
  id: number;
  href: string;
  title: string;
  awayName: string;
  homeName: string;
  awayScore: number;
  homeScore: number;
  scheduledAt: number;
  status: string;
  /** Which side won a finished game; `null` while the game is still open or the scores are level. */
  winner: "home" | "away" | null;
  /** The status as the dashboard words it: Upcoming, Live, Recording, Draft… */
  statusLabel: string;
  statusTone: "upcoming" | "live" | "recording" | "muted";
};

export type DashboardActivity = {
  id: string;
  kind: "plays" | "completed" | "game" | "team";
  title: string;
  subtitle: string;
  at: number;
  href?: string;
};

export type TrendBucket = { label: string; start: number; count: number };

export type DashboardTrend = {
  weeks: number;
  buckets: TrendBucket[];
  /** Plays in the shown window and in the window right before it, for the delta line. */
  current: number;
  previous: number;
};

export type DashboardModel = {
  summary: DashboardSummary;
  recentGames: DashboardGame[];
  upcomingGames: DashboardGame[];
  recentActivity: DashboardActivity[];
  trend: DashboardTrend;
};

const WEEK_MS = 7 * 24 * 60 * 60 * 1_000;

function statusPresentation(status: string, t: Translate): Pick<DashboardGame, "statusLabel" | "statusTone"> {
  switch (status) {
    case "READY":
      return { statusLabel: t("Upcoming"), statusTone: "upcoming" };
    case "RECORDING":
      return { statusLabel: t("Recording"), statusTone: "recording" };
    case "PAUSED":
      return { statusLabel: t("Live"), statusTone: "live" };
    case "COMPLETED":
      return { statusLabel: t("Final"), statusTone: "muted" };
    default:
      return {
        statusLabel: t(status ? status[0] + status.slice(1).toLowerCase() : "Draft"),
        statusTone: "muted",
      };
  }
}

function describeGame(game: Game, teamName: (id: number) => string, t: Translate): DashboardGame {
  const awayName = teamName(game.away_id);
  const homeName = teamName(game.home_id);
  const finished = game.status === "COMPLETED";
  return {
    id: game.id,
    href: `/games/${game.uuid_id ?? game.id}`,
    title: game.title || t("{away} vs {home}", { away: awayName, home: homeName }),
    awayName,
    homeName,
    awayScore: game.away_score,
    homeScore: game.home_score,
    scheduledAt: game.scheduled_at,
    status: game.status,
    winner: !finished || game.home_score === game.away_score
      ? null
      : game.home_score > game.away_score ? "home" : "away",
    ...statusPresentation(game.status, t),
  };
}

/** Rounds a timestamp down to the start of its local day, so plays recorded in one sitting group together. */
function dayKey(at: number) {
  const date = new Date(at);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/** Plays recorded per week, oldest first, over the `weeks` before `now`. */
export function buildTrend(snapshot: Snapshot, weeks: number, now = Date.now()): DashboardTrend {
  const end = dayKey(now) + 24 * 60 * 60 * 1_000;
  const windowStart = end - weeks * WEEK_MS;
  const previousStart = windowStart - weeks * WEEK_MS;
  const buckets: TrendBucket[] = Array.from({ length: weeks }, (_, index) => {
    const start = windowStart + index * WEEK_MS;
    return {
      start,
      count: 0,
      label: new Date(start).toLocaleDateString(undefined, { month: "short", day: "numeric" }),
    };
  });
  let current = 0;
  let previous = 0;
  for (const event of snapshot.events) {
    if (event.reverted) continue;
    const at = event.created_at;
    if (at >= windowStart && at < end) {
      current += 1;
      const index = Math.min(weeks - 1, Math.floor((at - windowStart) / WEEK_MS));
      buckets[index].count += 1;
    } else if (at >= previousStart && at < windowStart) {
      previous += 1;
    }
  }
  return { weeks, buckets, current, previous };
}

/** Everything the dashboard shows, computed once per snapshot. */
export function buildDashboard(snapshot: Snapshot, trendWeeks = 8, now = Date.now(), t: Translate = format): DashboardModel {
  const teamById = new Map(snapshot.teams.map((team) => [team.id, team]));
  const teamName = (id: number) => teamById.get(id)?.name ?? t("Unknown team");
  const games = snapshot.games.map((game) => describeGame(game, teamName, t));
  const gameById = new Map(games.map((game) => [game.id, game]));
  const liveEvents = snapshot.events.filter((event) => !event.reverted);

  const summary: DashboardSummary = {
    teamCount: snapshot.teams.length,
    playerCount: snapshot.players.length,
    totalGames: games.length,
    activeGames: games.filter((game) => game.status !== "COMPLETED").length,
    completedGames: games.filter((game) => game.status === "COMPLETED").length,
    recordedPlays: liveEvents.length,
  };

  const recentGames = games
    .filter((game) => game.status === "COMPLETED")
    .sort((a, b) => b.scheduledAt - a.scheduledAt)
    .slice(0, 4);

  // Live and recording games come first, then whatever is scheduled next.
  const priority: Record<DashboardGame["statusTone"], number> = { recording: 0, live: 0, upcoming: 1, muted: 2 };
  const upcomingGames = games
    .filter((game) => game.status !== "COMPLETED")
    .sort((a, b) => priority[a.statusTone] - priority[b.statusTone] || a.scheduledAt - b.scheduledAt)
    .slice(0, 4);

  // Activity is reconstructed from timestamps: plays batched per game and day, games and teams
  // by creation, and completed games by their last recorded play.
  const activity: DashboardActivity[] = [];
  const playBatches = new Map<string, { gameId: number; count: number; latest: number }>();
  const lastPlay = new Map<number, number>();
  for (const event of liveEvents) {
    const key = `${event.game_id}:${dayKey(event.created_at)}`;
    const batch = playBatches.get(key) ?? { gameId: event.game_id, count: 0, latest: 0 };
    batch.count += 1;
    batch.latest = Math.max(batch.latest, event.created_at);
    playBatches.set(key, batch);
    lastPlay.set(event.game_id, Math.max(lastPlay.get(event.game_id) ?? 0, event.created_at));
  }
  for (const [key, batch] of playBatches) {
    const game = gameById.get(batch.gameId);
    if (!game) continue;
    activity.push({
      id: `plays:${key}`,
      kind: "plays",
      title: batch.count === 1 ? t("{count} play recorded", { count: batch.count }) : t("{count} plays recorded", { count: batch.count }),
      subtitle: game.title,
      at: batch.latest,
      href: game.href,
    });
  }
  for (const game of snapshot.games) {
    const described = gameById.get(game.id)!;
    activity.push({
      id: `game:${game.id}`,
      kind: "game",
      title: t("Game created"),
      subtitle: described.title,
      at: game.created_at,
      href: described.href,
    });
    if (game.status === "COMPLETED") {
      activity.push({
        id: `completed:${game.id}`,
        kind: "completed",
        title: t("Game marked as completed"),
        subtitle: `${described.title} · ${described.awayScore}–${described.homeScore}`,
        at: lastPlay.get(game.id) ?? game.created_at,
        href: described.href,
      });
    }
  }
  for (const team of snapshot.teams) {
    activity.push({
      id: `team:${team.id}`,
      kind: "team",
      title: t("Team created"),
      subtitle: team.name,
      at: team.created_at,
      href: "/teams",
    });
  }
  const recentActivity = activity
    .filter((item) => Number.isFinite(item.at) && item.at > 0)
    .sort((a, b) => b.at - a.at)
    .slice(0, 6);

  return { summary, recentGames, upcomingGames, recentActivity, trend: buildTrend(snapshot, trendWeeks, now) };
}

/** "2 hours ago" style wording for the activity feed. */
export function relativeTime(at: number, now = Date.now(), t: Translate = format) {
  const seconds = Math.round((now - at) / 1_000);
  if (seconds < 45) return t("just now");
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return t("{count} min ago", { count: minutes });
  const hours = Math.round(minutes / 60);
  if (hours < 24) return hours === 1 ? t("{count} hour ago", { count: hours }) : t("{count} hours ago", { count: hours });
  const days = Math.round(hours / 24);
  if (days < 7) return days === 1 ? t("{count} day ago", { count: days }) : t("{count} days ago", { count: days });
  if (days < 30) {
    const weeks = Math.round(days / 7);
    return weeks === 1 ? t("{count} week ago", { count: weeks }) : t("{count} weeks ago", { count: weeks });
  }
  return new Date(at).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

export function formatGameDate(at: number, withTime = false) {
  const date = new Date(at);
  const day = date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
  if (!withTime) return day;
  return `${day} · ${date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}`;
}
