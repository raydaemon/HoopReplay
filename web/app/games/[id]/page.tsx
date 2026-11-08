"use client";
import { titleCase } from "@/lib/text";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, BadgeCheck, CalendarDays, Check, ChevronDown, ChevronRight, Clapperboard, Copy, Download, Flag } from "lucide-react";
import { flexRender, useTable } from "@tanstack/react-table";
import { type ColumnDef, tableFeaturesSet } from "@/components/table-features";
import { type ColumnLayout, ColumnChooser, ColumnDragContext, SortableTableHead, useColumnLayout } from "@/components/column-layout";
import type { SortingState } from "@tanstack/table-core";
import { useSnapshot } from "@/lib/use-snapshot";
import { exportGameFileName, exportGameJson } from "@/lib/game-portability";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHeader, TableRow } from "@/components/ui/table";
import { RestError, RestLoading, RestShell } from "../../rest-shell";
import type { Player, StatEvent } from "@/lib/types";
import { comparePlayers } from "@/lib/player-sort";
import { periodStarters, playerLabel } from "@/lib/scoring";
import { GameAccessCard } from "@/components/game-access-card";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { HighlightsCard } from "@/components/highlights-card";
import { supabase } from "@/lib/supabase";
import { PDF_PRICE_LABEL } from "@/lib/pdf-checkout";
import { ScoreMode } from "@/components/score-mode";
import { EditPlayDialog, type PlayEdit } from "@/components/score-dialogs";
import { isScoringType } from "@/lib/scoring";
import { useI18n } from "@/lib/i18n";
import { format } from "@/lib/i18n-core";

const statColumns = ["MIN", "PTS", "+/-", "FGM", "FGA", "FG%", "3PM", "3PA", "3P%", "FTM", "FTA", "FT%", "OREB", "DREB", "REB", "AST", "STL", "BLK", "TO", "PF"];
const statTypes: Record<string, string[]> = { FGM: ["PTS_2", "PTS_3"], FGA: ["PTS_2", "MISS_2", "PTS_3", "MISS_3"], "3PM": ["PTS_3"], "3PA": ["PTS_3", "MISS_3"], FTM: ["FT_MADE"], FTA: ["FT_MADE", "FT_MISS"], OREB: ["OREB"], DREB: ["DREB"], REB: ["REB"], AST: ["AST"], STL: ["STL"], BLK: ["BLK"], TO: ["TOV"], PF: ["FOUL"] };

function valueFor(events: { type: string; value: number }[], stat: string): number | string {
  // Includes manual +1/-1 adjustments so the points column adds up to the scoreboard.
  if (stat === "PTS") return events.filter((event) => isScoringType(event.type)).reduce((sum, event) => sum + event.value, 0);
  if (stat === "FG%") {
    const made = valueFor(events, "FGM");
    const attempts = valueFor(events, "FGA");
    return Number(attempts) ? `${((Number(made) / Number(attempts)) * 100).toFixed(1)}%` : "—";
  }
  if (stat.endsWith("%")) {
    const made = valueFor(events, `${stat[0]}PM`);
    const attempts = valueFor(events, `${stat[0]}PA`);
    return attempts ? `${((Number(made) / Number(attempts)) * 100).toFixed(1)}%` : "—";
  }
  return (statTypes[stat] ?? []).reduce((sum, type) => sum + events.filter((event) => event.type === type).length, 0);
}

function plusMinusForPlayer(events: StatEvent[], playerId: number, teamId: number) {
  const plusMinus = new Map<number, number>();
  const ordered = [...events].sort((a, b) => a.period - b.period || b.game_clock_ms - a.game_clock_ms || a.id - b.id);
  let playersOnCourt = new Set<number>();
  let currentPeriod: number | null = null;
  for (const event of ordered) {
    if (currentPeriod !== event.period) {
      currentPeriod = event.period;
      playersOnCourt = recordedStarters(events, teamId, event.period);
    }
    if (event.team_id === teamId && (event.type === "STARTER" || event.type === "SUB_IN")) {
      if (event.player_id !== null) playersOnCourt.add(event.player_id);
      continue;
    }
    if (event.team_id === teamId && event.type === "SUB_OUT") {
      if (event.player_id !== null) playersOnCourt.delete(event.player_id);
      continue;
    }
    if (event.team_id === teamId && event.type === "SUBSTITUTION") {
      if (event.player_id !== null) playersOnCourt.delete(event.player_id);
      if (event.related_player_id != null) playersOnCourt.add(event.related_player_id);
      continue;
    }
    if (!["PTS_2", "PTS_3", "FT_MADE"].includes(event.type)) continue;
    const differential = event.team_id === teamId ? event.value : -event.value;
    for (const player of playersOnCourt) plusMinus.set(player, (plusMinus.get(player) ?? 0) + differential);
  }
  return plusMinus.get(playerId) ?? 0;
}

function teamPlusMinus(events: StatEvent[], teamId: number) {
  const scoringTypes = ["PTS_2", "PTS_3", "FT_MADE"];
  return events.filter((event) => scoringTypes.includes(event.type))
    .reduce((sum, event) => sum + (event.team_id === teamId ? event.value : -event.value), 0);
}

function teamMinutes(players: Player[], events: StatEvent[], periodDurationMs: number, currentPeriod: number, currentClockMs: number, fullGame = false) {
  const periods = [...new Set(events.map((event) => event.period))];
  if (fullGame) {
    const completedPeriods = Math.max(periods.length, Math.max(0, currentPeriod - 1) + (currentClockMs <= 0 ? 1 : 0), periods.length === 1 ? 2 : 0);
    const totalMs = completedPeriods * Math.min(players.length, 5) * periodDurationMs;
    const totalSeconds = Math.round(totalMs / 1_000);
    return `${String(Math.floor(totalSeconds / 60)).padStart(2, "0")}:${String(totalSeconds % 60).padStart(2, "0")}`;
  }
  const latestClockInCurrentPeriod = Math.min(...events.filter((event) => event.period === currentPeriod).map((event) => event.game_clock_ms), Infinity);
  if (periods.length > 0) {
    const completedPeriods = periods.filter((period) => period < currentPeriod).length + (latestClockInCurrentPeriod <= 10_000 ? 1 : 0);
    const totalMs = Math.min(periods.length, Math.max(0, completedPeriods)) * Math.min(players.length, 5) * periodDurationMs;
    const totalSeconds = Math.round(totalMs / 1_000);
    return `${String(Math.floor(totalSeconds / 60)).padStart(2, "0")}:${String(totalSeconds % 60).padStart(2, "0")}`;
  }
  const totalMs = periods.reduce((sum, period) => {
    const teamPlayerCount = Math.min(players.length, 5);
    if (period < currentPeriod || (period === currentPeriod && (currentClockMs <= 0 || latestClockInCurrentPeriod <= 10_000))) return sum + teamPlayerCount * periodDurationMs;
    if (period === currentPeriod) return sum + Math.max(0, periodDurationMs - currentClockMs) * 5;
    return sum;
  }, 0);
  const totalSeconds = Math.round(totalMs / 1_000);
  return `${String(Math.floor(totalSeconds / 60)).padStart(2, "0")}:${String(totalSeconds % 60).padStart(2, "0")}`;
}

function formatClock(ms: number) {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(totalSeconds / 60)).padStart(2, "0")}:${String(totalSeconds % 60).padStart(2, "0")}`;
}

function playLabel(type: string) {
  const labels: Record<string, string> = {
    PTS_2: "2PT made", PTS_3: "3PT made", FT_MADE: "FT made", FT_MISS: "FT missed",
    MISS_2: "2PT missed", MISS_3: "3PT missed", REB: "REB", AST: "AST", STL: "STL",
    BLK: "BLK", TOV: "TOV", FOUL: "Foul", FOULED: "Foul drawn", STARTER: "Starter", SUB_IN: "Sub in", SUB_OUT: "Sub out",
    ADJ: "Score adjustment",
  };
  return labels[type] ?? type;
}

const playFilters = [
  { id: "all", label: "All" }, { id: "scoring", label: "Scoring" }, { id: "fouls", label: "Fouls" },
  { id: "subs", label: "Subs" }, { id: "away", label: "Away" }, { id: "home", label: "Home" },
] as const;
type PlayFilter = (typeof playFilters)[number]["id"];

const isScoringPlay = (type: string) => type.startsWith("PTS_") || type === "FT_MADE" || type === "ADJ";
const isSubstitutionPlay = (type: string) => ["SUB_IN", "SUB_OUT", "SUBSTITUTION", "STARTER"].includes(type);

/** "Q1".."Q4" for a four-period game, "H1"/"H2" for halves, otherwise "Period N"; overtime is "OT1", "OT2", ... */
function periodGroupLabel(period: number, periodCount: number, t: (key: string, vars?: Record<string, string | number>) => string = format) {
  if (period > periodCount) return `OT${period - periodCount}`;
  if (periodCount === 4) return `Q${period}`;
  if (periodCount === 2) return `H${period}`;
  return t("Period {n}", { n: period });
}

/**
 * Who started the period for this team: only recorded STARTER events count, in first-appearance
 * order and capped at five, the same as the Android recorder. A stat never implies that a player was
 * on the floor, so minutes come solely from STARTER / SUB_IN / SUB_OUT history.
 */
function recordedStarters(events: StatEvent[], teamId: number, period: number) {
  return new Set(periodStarters(events, teamId, period).slice(0, 5));
}

function substitutionClock(events: StatEvent[], event: StatEvent) {
  if (event.type !== "SUB_IN") return event.game_clock_ms;
  const pairedOut = events
    .filter((candidate) => candidate.type === "SUB_OUT" && candidate.team_id === event.team_id && candidate.period === event.period && candidate.game_clock_ms >= event.game_clock_ms && candidate.game_clock_ms - event.game_clock_ms <= 5_000)
    .sort((a, b) => a.game_clock_ms - b.game_clock_ms || Math.abs(a.id - event.id) - Math.abs(b.id - event.id))[0];
  return pairedOut?.game_clock_ms ?? event.game_clock_ms;
}

function playingTimeMs(events: StatEvent[], playerId: number, teamId: number, periodDurationMs: number) {
  let totalMs = 0;
  const periods = [...new Set(events.map((event) => event.period))].sort((a, b) => a - b);
  for (const period of periods) {
    let activeFrom: number | null = recordedStarters(events, teamId, period).has(playerId) ? periodDurationMs : null;
    const substitutions = events
      .filter((event) => event.period === period && (event.player_id === playerId || event.related_player_id === playerId) && ["SUB_IN", "SUB_OUT", "SUBSTITUTION"].includes(event.type))
      .sort((a, b) => b.game_clock_ms - a.game_clock_ms || a.id - b.id);
    for (const event of substitutions) {
      const enters = event.type === "SUB_IN" || (event.type === "SUBSTITUTION" && event.related_player_id === playerId);
      if (enters) {
        if (activeFrom === null) activeFrom = substitutionClock(events, event);
      } else if (activeFrom !== null) {
        totalMs += Math.max(0, activeFrom - event.game_clock_ms);
        activeFrom = null;
      }
    }
    if (activeFrom !== null) totalMs += activeFrom;
  }
  return totalMs;
}

function minutesForPlayer(events: StatEvent[], playerId: number, teamId: number, periodDurationMs: number) {
  const totalSeconds = Math.round(playingTimeMs(events, playerId, teamId, periodDurationMs) / 1_000);
  return `${String(Math.floor(totalSeconds / 60)).padStart(2, "0")}:${String(totalSeconds % 60).padStart(2, "0")}`;
}

/** Every column of the box score, in default order; the parent owns the shared layout state. */
const statTableColumnIds = ["player", ...statColumns];
/** Synthetic row id for plays recorded with "Assign later"; no real player has a negative id. */
const UNASSIGNED_ID = -1;

/** One box-score cell; the on-screen table and the PDF both read through here. */
function statCell(player: Player, stat: string, events: StatEvent[], teamId: number, gameDurationMs: number) {
  if (player.id === UNASSIGNED_ID) return stat === "MIN" || stat === "+/-" ? "—" : valueFor(events.filter((event) => event.team_id === teamId && event.player_id === null), stat);
  if (stat === "MIN") return minutesForPlayer(events, player.id, player.team_id, gameDurationMs);
  if (stat === "+/-") return plusMinusForPlayer(events, player.id, player.team_id);
  return valueFor(events.filter((event) => event.player_id === player.id), stat);
}
function statTeamTotal(stat: string, players: Player[], events: StatEvent[], teamId: number, gameDurationMs: number, currentPeriod: number, currentClockMs: number, fullGame: boolean) {
  if (stat === "MIN") return teamMinutes(players, events, gameDurationMs, currentPeriod, currentClockMs, fullGame);
  if (stat === "+/-") return teamPlusMinus(events, teamId);
  return valueFor(events.filter((event) => event.team_id === teamId), stat);
}
/** Roster rows of a box score: numbered players first, then an Unassigned row when "Assign later" plays exist. */
function boxScoreRows(players: Player[], events: StatEvent[], teamId: number): Player[] {
  const roster = [...players].sort(comparePlayers);
  const unassigned = events.some((event) => event.team_id === teamId && event.player_id === null && event.type !== "VIDEO");
  return unassigned ? [...roster, { id: UNASSIGNED_ID, team_id: teamId, name: "Unassigned", number: "" }] : roster;
}

function TeamStatsTable({ players, events, teamId, gameDurationMs, currentPeriod, currentClockMs, fullGame = false, layout }: { players: Player[]; events: StatEvent[]; teamId: number; gameDurationMs: number; currentPeriod: number; currentClockMs: number; fullGame?: boolean; layout: ColumnLayout }) {
  const { t } = useI18n();
  const [sorting, setSorting] = useState<SortingState>([]);
  const columns = useMemo<ColumnDef<Player>[]>(() => [
    { id: "player", header: t("Player"), enableHiding: false, accessorFn: (player) => `${player.name} ${player.number}`, cell: ({ row }) => `${row.original.id === UNASSIGNED_ID ? t("Unassigned") : row.original.name}${row.original.number ? ` #${row.original.number}` : ""}` },
    ...statColumns.map((stat): ColumnDef<Player> => ({
      id: stat,
      header: stat,
      accessorFn: (player: Player) => statCell(player, stat, events, teamId, gameDurationMs),
    })),
  ], [events, gameDurationMs, teamId, t]);
  const data = useMemo(() => boxScoreRows(players, events, teamId), [players, events, teamId]);
  const table = useTable({
    features: tableFeaturesSet, data, columns,
    // A box score lists the whole roster: the shared feature set paginates at ten rows by default,
    // which silently dropped every player past the tenth (there is no pager on this table).
    state: { sorting, columnOrder: layout.columnOrder, columnVisibility: layout.columnVisibility, pagination: { pageIndex: 0, pageSize: Math.max(data.length, 1) } },
    onSortingChange: setSorting, onColumnOrderChange: layout.onColumnOrderChange, onColumnVisibilityChange: layout.onColumnVisibilityChange,
  });
  const teamTotal = (stat: string) => statTeamTotal(stat, players, events, teamId, gameDurationMs, currentPeriod, currentClockMs, fullGame);
  const headClass = (id: string) => `h-[27px] whitespace-nowrap px-1 text-center ${id === "player" ? "text-left" : ""}`;
  return <ColumnDragContext id={`box-score-${teamId}`} columnIds={layout.columnOrder} onColumnOrderChange={layout.onColumnOrderChange}>
    <Table className="statsTable text-[10px]">
      <TableHeader>{table.getHeaderGroups().map((headerGroup) => <TableRow key={headerGroup.id}>{headerGroup.headers.map((header) => <SortableTableHead key={header.id} columnId={header.column.id} className={headClass(header.column.id)}><button type="button" className="min-h-0 border-0 p-0 font-semibold" onClick={header.column.getToggleSortingHandler()}>{flexRender(header.column.columnDef.header, header.getContext())}{({ asc: " ↑", desc: " ↓" } as Record<string, string>)[header.column.getIsSorted() as string] ?? ""}</button></SortableTableHead>)}</TableRow>)}</TableHeader>
      <TableBody>
        {table.getRowModel().rows.map((row) => <TableRow key={row.id}>{row.getVisibleCells().map((cell) => <TableCell className={`whitespace-nowrap px-1 py-1 text-center ${cell.column.id === "player" ? "text-left" : ""}`} key={cell.id}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</TableCell>)}</TableRow>)}
        <TableRow>{table.getVisibleLeafColumns().map((column) => column.id === "player" ? <TableCell className="whitespace-nowrap px-1 py-1 font-semibold" key={column.id}>{t("Team Total")}</TableCell> : <TableCell className="px-1 py-1 text-center font-semibold" key={column.id}>{teamTotal(column.id)}</TableCell>)}</TableRow>
      </TableBody>
    </Table>
  </ColumnDragContext>;
}

function PeriodStats({ game, events, players, teamName, layout }: { game: { period_count: number; period_duration_ms: number; current_period: number; clock_remaining_ms: number; away_id: number; home_id: number }; events: StatEvent[]; players: Player[]; teamName: (id: number) => string; layout: ColumnLayout }) {
  const availablePeriods = useMemo(() => {
    const recorded = events.map((event) => event.period);
    return Array.from({ length: Math.max(game.period_count, ...recorded, 1) }, (_, index) => index + 1);
  }, [events, game.period_count]);
  const { t } = useI18n();
  const [period, setPeriod] = useState(1);
  const selectedPeriod = availablePeriods.includes(period) ? period : availablePeriods[0];
  const periodEvents = useMemo(() => events.filter((event) => event.period === selectedPeriod), [events, selectedPeriod]);
  return <Card>
    <CardHeader className="flex-wrap gap-y-3">
      <div><CardTitle>{t("Stats By Period")}</CardTitle><p className="mt-1 text-sm text-muted-foreground">{t("View player stats and team totals for each period")}</p></div>
      <div className="ml-auto flex flex-wrap gap-1.5" role="group" aria-label={t("Period statistics")}>
        {availablePeriods.map((item) => <Button key={item} size="sm" variant={item === selectedPeriod ? "default" : "outline"} aria-pressed={item === selectedPeriod} onClick={() => setPeriod(item)}>{periodGroupLabel(item, game.period_count, t)}</Button>)}
      </div>
    </CardHeader>
    <CardContent className="space-y-4 px-2 sm:px-6">
      {[game.away_id, game.home_id].map((teamId, index) => <div key={teamId}>
        <h3 className="mb-2 text-sm font-semibold">{index === 0 ? t("{team} (Away)", { team: teamName(teamId) }) : t("{team} (Home)", { team: teamName(teamId) })}</h3>
        <div className="overflow-x-auto"><TeamStatsTable players={players.filter((player) => player.team_id === teamId)} events={periodEvents} teamId={teamId} gameDurationMs={game.period_duration_ms} currentPeriod={game.current_period} currentClockMs={game.clock_remaining_ms} layout={layout} /></div>
      </div>)}
    </CardContent>
  </Card>;
}

export default function GameDetailsPage() {
  const { data, user, authReady, loading, saving, status, mutate } = useSnapshot();
  const { t } = useI18n();
  const params = useParams<{ id: string }>();
  const game = data.games.find((item) => item.uuid_id === params.id);
  const events = useMemo(() => data.events.filter((event) => event.game_id === game?.id && !event.reverted), [data.events, game?.id]);
  const teamName = (id: number) => data.teams.find((team) => team.id === id)?.name ?? t("Unknown");
  const orderedEvents = useMemo(() => [...events].sort((a, b) => a.period - b.period || b.game_clock_ms - a.game_clock_ms || a.id - b.id), [events]);
  // A substitution batch may swap several players at once. Its Sub out / Sub in events share the team,
  // period and clock and are written in pairs in id order, so each Sub in pairs with the earliest
  // still-unpaired Sub out recorded within a few seconds of it (created_at can differ by a few ms).
  const substitutionPairs = useMemo(() => {
    const pairs = new Map<number, StatEvent>();
    const pairedIns = new Set<number>();
    const groups = new Map<string, StatEvent[]>();
    for (const event of events) {
      if (event.type !== "SUB_OUT" && event.type !== "SUB_IN") continue;
      const key = `${event.team_id}|${event.period}|${event.game_clock_ms}`;
      groups.set(key, [...(groups.get(key) ?? []), event]);
    }
    const sameBatch = (a: StatEvent, b: StatEvent) => Math.abs(a.created_at - b.created_at) <= 5000;
    for (const group of groups.values()) {
      const waitingOuts: StatEvent[] = [];
      for (const event of [...group].sort((a, b) => a.id - b.id)) {
        if (event.type === "SUB_OUT") { waitingOuts.push(event); continue; }
        const index = waitingOuts.findIndex((out) => sameBatch(out, event));
        if (index === -1) continue;
        const [out] = waitingOuts.splice(index, 1);
        pairs.set(out.id, event);
        pairedIns.add(event.id);
      }
    }
    return { pairs, pairedIns };
  }, [events]);
  const [playFilter, setPlayFilter] = useState<PlayFilter>("all");
  const [collapsedPeriods, setCollapsedPeriods] = useState<Set<number>>(() => new Set());
  const togglePeriod = (period: number) => setCollapsedPeriods((old) => { const next = new Set(old); if (next.has(period)) next.delete(period); else next.add(period); return next; });
  // Running score after every play, computed over the full list so filters never change the scoreboard.
  const runningScores = useMemo(() => {
    if (!game) return new Map<number, { away: number; home: number }>();
    const scores = new Map<number, { away: number; home: number }>();
    let away = 0, home = 0;
    for (const event of orderedEvents) {
      if (isScoringPlay(event.type)) { if (event.team_id === game.away_id) away += event.value; else if (event.team_id === game.home_id) home += event.value; }
      scores.set(event.id, { away, home });
    }
    return scores;
  }, [orderedEvents, game]);
  const periodGroups = useMemo(() => {
    if (!game) return [];
    const matches = (event: StatEvent) => {
      if (playFilter === "scoring") return isScoringPlay(event.type);
      if (playFilter === "fouls") return event.type === "FOUL" || event.type === "FOULED";
      if (playFilter === "subs") return isSubstitutionPlay(event.type);
      if (playFilter === "away") return event.team_id === game.away_id;
      if (playFilter === "home") return event.team_id === game.home_id;
      return true;
    };
    const groups: { period: number; plays: StatEvent[]; total: number; endScore: { away: number; home: number } }[] = [];
    for (const event of orderedEvents) {
      if (event.type === "SUB_IN" && substitutionPairs.pairedIns.has(event.id)) continue;
      let group = groups.find((item) => item.period === event.period);
      if (!group) { group = { period: event.period, plays: [], total: 0, endScore: { away: 0, home: 0 } }; groups.push(group); }
      group.total += 1;
      group.endScore = runningScores.get(event.id) ?? group.endScore;
      if (matches(event)) group.plays.push(event);
    }
    return groups;
  }, [orderedEvents, game, playFilter, substitutionPairs, runningScores]);
  /** The action and player text of a play, as the timeline shows it (a Sub out carries its paired Sub in). */
  const describePlay = (event: StatEvent) => {
    const player = event.player_id === null ? null : data.players.find((item) => item.id === event.player_id);
    const name = event.type === "ADJ" ? "" : player ? playerLabel(player) : t("Unassigned");
    const substitutionIn = event.type === "SUB_OUT" ? substitutionPairs.pairs.get(event.id) : undefined;
    const substitutionInPlayer = substitutionIn?.player_id === null || substitutionIn?.player_id === undefined ? null : data.players.find((item) => item.id === substitutionIn.player_id);
    const pairedIn = event.type === "SUBSTITUTION" && event.related_player_id ? data.players.find((item) => item.id === event.related_player_id) : undefined;
    const displayName = pairedIn ? `${name} → ${playerLabel(pairedIn)}` : substitutionInPlayer ? `${name} → ${playerLabel(substitutionInPlayer)}` : name;
    return { action: t(event.type === "SUB_OUT" ? "Substitution" : playLabel(event.type)), displayName };
  };
  const [copied, setCopied] = useState(false);
  /** Every play (filters ignored) as tab-separated lines, one per play: the clipboard text and the replay video's source. */
  const playsText = () => {
    if (!game) return "";
    const lines = [[t("Period"), t("Time"), t("Team"), t("Play"), t("Player"), t("Points"), t("Score")].join("\t")];
    for (const event of orderedEvents) {
      if (event.type === "SUB_IN" && substitutionPairs.pairedIns.has(event.id)) continue;
      const { action, displayName } = describePlay(event);
      const scoring = isScoringPlay(event.type);
      const score = runningScores.get(event.id) ?? { away: 0, home: 0 };
      const team = event.team_id === game.home_id ? t("{team} (Home)", { team: teamName(event.team_id) }) : t("{team} (Away)", { team: teamName(event.team_id) });
      lines.push([periodGroupLabel(event.period, game.period_count, t), formatClock(event.game_clock_ms), team, action, displayName, scoring ? (event.value > 0 ? `+${event.value}` : String(event.value)) : "", scoring ? `${score.away} - ${score.home}` : ""].join("\t"));
    }
    return lines.join("\n");
  };
  const copyPlays = async () => {
    await navigator.clipboard.writeText(playsText());
    setCopied(true);
    window.setTimeout(() => setCopied(false), 2000);
  };
  const [accessOpen, setAccessOpen] = useState(false);
  const [endingOpen, setEndingOpen] = useState(false);
  // The statistics PDF costs $0.99 once per game: pdfPaid mirrors the user's pdf_purchases row.
  const [pdfPaid, setPdfPaid] = useState(false);
  const [payOpen, setPayOpen] = useState(false);
  const [payError, setPayError] = useState("");
  // Set once Stripe confirms the payment; the download waits until the game data has arrived.
  const pendingDownload = useRef(false);
  const gameUuid = game?.uuid_id;
  /** The statistics PDF: US Letter landscape, both box scores on one page whenever they fit. */
  const saveStatsPdf = async () => {
    if (!game) return;
    const [{ jsPDF }, { default: autoTable }] = await Promise.all([import("jspdf"), import("jspdf-autotable")]);
    const doc = new jsPDF({ orientation: "landscape", unit: "pt", format: "letter" });
    const title = game.title || `${teamName(game.away_id)} vs ${teamName(game.home_id)}`;
    doc.setFontSize(16).text(title, 36, 40);
    doc.setFontSize(10).text(`${teamName(game.away_id)} ${game.away_score} - ${game.home_score} ${teamName(game.home_id)} · ${titleCase(game.status)} · ${new Date(game.scheduled_at).toLocaleDateString()}`, 36, 56);
    let y = 76;
    for (const [teamId, side] of [[game.away_id, "Away"], [game.home_id, "Home"]] as const) {
      const roster = data.players.filter((player) => player.team_id === teamId);
      const rows = boxScoreRows(roster, events, teamId);
      doc.setFontSize(11).text(`${teamName(teamId)} (${side})`, 36, y);
      autoTable(doc, {
        startY: y + 6,
        margin: { left: 36, right: 36 },
        theme: "grid",
        styles: { fontSize: 7, cellPadding: 2, halign: "center" },
        columnStyles: { 0: { halign: "left", cellWidth: 110 } },
        headStyles: { fillColor: [234, 88, 12] },
        footStyles: { fillColor: [245, 245, 245], textColor: 20, fontStyle: "bold" },
        head: [["Player", ...statColumns]],
        body: rows.map((player) => [`${player.name}${player.number ? ` #${player.number}` : ""}`, ...statColumns.map((stat) => String(statCell(player, stat, events, teamId, game.period_duration_ms)))]),
        foot: [[{ content: "Team Total", styles: { halign: "left" } }, ...statColumns.map((stat) => String(statTeamTotal(stat, roster, events, teamId, game.period_duration_ms, game.current_period, game.clock_remaining_ms, true)))]],
      });
      y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 24;
    }
    doc.save(exportGameFileName(data, game).replace(/\.json$/, ".pdf"));
  };
  useEffect(() => {
    if (!pendingDownload.current || !pdfPaid || !game) return;
    pendingDownload.current = false;
    void saveStatsPdf();
  // eslint-disable-next-line react-hooks/exhaustive-deps -- fire once per confirmed payment
  }, [pdfPaid, game]);
  useEffect(() => {
    if (!supabase || !user || !gameUuid) return;
    let cancelled = false;
    void supabase.from("hoop_pdf_purchases").select("game_uuid").eq("game_uuid", gameUuid).maybeSingle()
      .then(({ data: row }) => { if (!cancelled) setPdfPaid(Boolean(row)); });
    return () => { cancelled = true; };
  }, [user, gameUuid]);
  // Stripe sends the browser back with ?paid=<session>; the server verifies it before the PDF prints.
  useEffect(() => {
    if (!supabase || !user) return;
    const url = new URL(window.location.href);
    const sessionId = url.searchParams.get("paid");
    if (!sessionId) return;
    url.searchParams.delete("paid");
    window.history.replaceState(null, "", url.pathname + url.search);
    void (async () => {
      const token = (await supabase!.auth.getSession()).data.session?.access_token ?? "";
      const res = await fetch(`/api/pdf-checkout?session=${encodeURIComponent(sessionId)}`, { headers: { Authorization: `Bearer ${token}` } });
      const json = await res.json().catch(() => ({}));
      if (json.paid) {
        pendingDownload.current = true;
        setPdfPaid(true);
      } else setPayError(json.error ?? t("Payment was not completed."));
    })();
  }, [user, t]);
  const downloadPdf = () => pdfPaid ? void saveStatsPdf() : setPayOpen(true);
  const startCheckout = async () => {
    if (!supabase || !game) return;
    setPayError("");
    const token = (await supabase.auth.getSession()).data.session?.access_token ?? "";
    const res = await fetch("/api/pdf-checkout", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ game_uuid: game.uuid_id, title: game.title || `${teamName(game.away_id)} vs ${teamName(game.home_id)}` }),
    });
    const json = await res.json().catch(() => ({}));
    if (json.url) window.location.href = json.url;
    else { setPayOpen(false); setPayError(json.error ?? t("Could not start checkout.")); }
  };
  // One free AI replay video per game (Gemini + Veo). The server owns the row; the page polls while it renders.
  type Replay = { status: "none" | "generating" | "ready" | "failed"; video_url?: string | null; error?: string | null };
  const [replay, setReplay] = useState<Replay | null>(null);
  const [replayError, setReplayError] = useState("");
  const replayFetch = async (init?: RequestInit): Promise<Replay> => {
    const token = (await supabase!.auth.getSession()).data.session?.access_token ?? "";
    const res = await fetch(`/api/replay-video?game_uuid=${encodeURIComponent(gameUuid ?? "")}`, { ...init, headers: { ...init?.headers, Authorization: `Bearer ${token}` } });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(json.error ?? t("Replay video request failed."));
    return json;
  };
  const replayGenerating = replay?.status === "generating";
  useEffect(() => {
    if (!supabase || !user || !gameUuid) return;
    let cancelled = false;
    let timer: number | undefined;
    const poll = async () => {
      try {
        const next = await replayFetch();
        if (cancelled) return;
        setReplay(next);
        if (next.status === "generating") timer = window.setTimeout(poll, 10000);
      } catch (error) { if (!cancelled) setReplayError(error instanceof Error ? error.message : t("Replay video request failed.")); }
    };
    void poll();
    return () => { cancelled = true; window.clearTimeout(timer); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user, gameUuid, replayGenerating]);
  const generateVideo = async () => {
    if (!supabase || !game) return;
    setReplayError("");
    setReplay({ status: "generating" });
    try {
      setReplay(await replayFetch({
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ game_uuid: game.uuid_id, title: game.title || `${teamName(game.away_id)} vs ${teamName(game.home_id)}`, away: teamName(game.away_id), home: teamName(game.home_id), away_score: game.away_score, home_score: game.home_score, plays: playsText() }),
      }));
    } catch (error) {
      setReplay({ status: "failed" });
      setReplayError(error instanceof Error ? error.message : t("Could not start the video."));
    }
  };
  const [editingPlay, setEditingPlay] = useState<StatEvent | null>(null);
  /** The other half of a substitution: a Sub out's paired Sub in, or a Sub in's paired Sub out. */
  const substitutionPartner = (event: StatEvent): StatEvent | null => {
    if (event.type === "SUB_OUT") return substitutionPairs.pairs.get(event.id) ?? null;
    if (event.type !== "SUB_IN") return null;
    const outId = [...substitutionPairs.pairs.entries()].find(([, subIn]) => subIn.id === event.id)?.[0];
    return outId === undefined ? null : events.find((candidate) => candidate.id === outId) ?? null;
  };
  /**
   * Mirrors the Android EditPlayPanel save: the play takes the new player, period and clock, and a
   * substitution drags its partner to the same moment so the pair never splits. A player created
   * inside the dialog joins the roster in the same write.
   */
  const savePlayEdit = (edit: PlayEdit) => {
    if (!editingPlay) return;
    const partnerId = substitutionPartner(editingPlay)?.id;
    mutate((draft) => ({
      ...draft,
      players: edit.player && !draft.players.some((row) => row.id === edit.player?.id) ? [...draft.players, edit.player] : draft.players,
      events: draft.events.map((row) => row.id === editingPlay.id
        ? { ...row, player_id: edit.player?.id ?? null, period: edit.period, game_clock_ms: edit.ms }
        : row.id === partnerId ? { ...row, period: edit.period, game_clock_ms: edit.ms } : row),
    }));
    setEditingPlay(null);
  };
  /** Delete reverts the play, like Undo, and takes its points off the scoreboard. */
  const deletePlay = () => {
    if (!editingPlay || !game) return;
    const play = editingPlay;
    mutate((draft) => ({
      ...draft,
      events: draft.events.map((row) => row.id === play.id ? { ...row, reverted: 1 } : row),
      games: draft.games.map((row) => row.id === game.id && isScoringType(play.type) ? {
        ...row,
        home_score: Math.max(0, row.home_score - (play.team_id === row.home_id ? play.value : 0)),
        away_score: Math.max(0, row.away_score - (play.team_id === row.away_id ? play.value : 0)),
      } : row),
    }));
    setEditingPlay(null);
  };
  const statsLayout = useColumnLayout("game-stats", statTableColumnIds);
  const statsChoosable = statsLayout.columnOrder.map((id) => ({
    id, label: id === "player" ? t("Player") : id, visible: statsLayout.columnVisibility[id] !== false, canHide: id !== "player",
    toggle: () => statsLayout.onColumnVisibilityChange((old) => ({ ...old, [id]: old[id] === false })),
  }));
  const canEdit = !game || !game.access_role || game.access_role === "owner" || game.access_role === "editor";
  const canEnd = Boolean(game) && canEdit && game?.status !== "COMPLETED";
  const isOwner = Boolean(user && game && (game.access_role === "owner" || (!game.access_role && (!game.owner_id || game.owner_id === user.id))));
  /** Mirrors the Android "End" action: the game is marked COMPLETED while scores and stats stay editable. */
  const endGame = () => {
    if (!game) return;
    mutate((draft) => ({ ...draft, games: draft.games.map((row) => row.id === game.id ? { ...row, status: "COMPLETED" } : row) }));
    setEndingOpen(false);
  };
  const exportJson = () => {
    if (!game) return;
    const blob = new Blob([JSON.stringify(exportGameJson(data, game), null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = exportGameFileName(data, game);
    anchor.click();
    URL.revokeObjectURL(url);
  };
  return <RestShell current="games" title={t("Game details")} status={status} saving={saving} user={user} authReady={authReady}>
    <div className="flex items-center justify-between gap-3"><Button asChild variant="ghost"><Link href="/games"><ArrowLeft className="size-4" />{t("Back to games")}</Link></Button>{game && <div className="flex items-center gap-2">{user && (game.access_role === "owner" || (!game.access_role && (!game.owner_id || game.owner_id === user.id))) && <Button onClick={() => setAccessOpen(true)}>{t("Add access")}</Button>}{canEnd && <Button variant="outline" className="whitespace-nowrap" onClick={() => setEndingOpen(true)}><Flag className="size-4" />{t("End")}</Button>}<Button variant="outline" onClick={exportJson}><Download className="size-4" />{t("Export")}</Button>{user && game.uuid_id && <Button variant="outline" className="whitespace-nowrap" onClick={downloadPdf}>{pdfPaid ? <BadgeCheck className="size-4 text-green-600" /> : <Download className="size-4" />}{pdfPaid ? t("Download PDF") : t("Download PDF ({price})", { price: PDF_PRICE_LABEL })}</Button>}{isOwner && game.uuid_id && replay && replay.status !== "ready" && <Button variant="outline" className="whitespace-nowrap" disabled={replayGenerating} onClick={generateVideo}><Clapperboard className="size-4" />{replayGenerating ? t("Generating Video…") : t("Generate Video")}</Button>}{replay?.status === "ready" && replay.video_url && <Button asChild variant="outline" className="whitespace-nowrap"><a href="#replay-video"><BadgeCheck className="size-4 text-green-600" />{t("Replay Video")}</a></Button>}</div>}</div>
    {payError && <RestError>{payError}</RestError>}
    {(replayError || replay?.error) && <RestError>{replayError || replay?.error}</RestError>}
    {game && <ConfirmDialog open={payOpen} onOpenChange={setPayOpen} title={t("Download statistics PDF")} description={t("The statistics PDF for this game costs {price}, charged once per game through Stripe. After paying you come back here and the PDF downloads.", { price: PDF_PRICE_LABEL })} confirmLabel={t("Pay {price}", { price: PDF_PRICE_LABEL })} confirmVariant="default" onConfirm={startCheckout} />}
    {game && <ConfirmDialog open={endingOpen} onOpenChange={setEndingOpen} title={t("End game?")} description={t("{game} will be marked as completed. Scores and stats stay editable.", { game: game.title || `${teamName(game.away_id)} vs ${teamName(game.home_id)}` })} confirmLabel={t("End")} confirmVariant="default" onConfirm={endGame} />}
    {!game ? (loading ? <RestLoading /> : <RestError>{t("Game not found.")}</RestError>) : <>
      <Card className="border-orange-200"><CardContent className="flex flex-wrap items-center justify-between gap-x-6 gap-y-3 px-5 py-4"><div className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1"><span className="rounded-md border border-orange-300 bg-orange-50 px-2 py-0.5 text-xs font-semibold tracking-[0.12em] text-orange-600">{t(titleCase(game.status))}</span><CardTitle className="truncate text-xl sm:text-2xl">{game.title || `${teamName(game.away_id)} vs ${teamName(game.home_id)}`}</CardTitle><span className="inline-flex items-center gap-1.5 text-sm text-muted-foreground"><CalendarDays className="size-4 text-orange-500" />{new Date(game.scheduled_at).toLocaleString()}</span></div>{!canEdit && <div className="flex items-center gap-3 text-sm text-muted-foreground"><span className="truncate">{teamName(game.away_id)} <span className="text-xs">{t("Away")}</span> <b className="text-2xl font-bold tabular-nums text-foreground">{game.away_score}</b></span><span>—</span><span className="truncate"><b className="text-2xl font-bold tabular-nums text-foreground">{game.home_score}</b> {teamName(game.home_id)} <span className="text-xs">{t("Home")}</span></span></div>}</CardContent></Card>
      {user && <GameAccessCard game={game} teams={data.teams.filter(team => team.id === game.home_id || team.id === game.away_id)} userId={user.id} dialogOpen={accessOpen} onDialogOpenChange={setAccessOpen} hideTrigger />}
      {canEdit && <ScoreMode game={game} data={data} events={events} mutate={mutate} paused={editingPlay !== null} />}
      {editingPlay && <EditPlayDialog key={editingPlay.id} event={editingPlay} label={t(editingPlay.type === "SUB_OUT" ? "Substitution" : playLabel(editingPlay.type))} players={data.players.filter((player) => player.team_id === editingPlay.team_id)} allPlayers={data.players} periodDurationMs={game.period_duration_ms} periodCount={game.period_count} onSave={savePlayEdit} onDelete={deletePlay} onDismiss={() => setEditingPlay(null)} />}
      {[game.away_id, game.home_id].map((teamId, index) => { const roster = data.players.filter((player) => player.team_id === teamId); return <Card key={teamId}><CardHeader><CardTitle>{index === 0 ? t("{team} (Away)", { team: teamName(teamId) }) : t("{team} (Home)", { team: teamName(teamId) })}</CardTitle><ColumnChooser columns={statsChoosable} onReset={statsLayout.reset} className="ml-auto" /></CardHeader><CardContent className="overflow-x-auto px-2 sm:px-6"><TeamStatsTable players={roster} events={events} teamId={teamId} gameDurationMs={game.period_duration_ms} currentPeriod={game.current_period} currentClockMs={game.clock_remaining_ms} fullGame layout={statsLayout} /></CardContent></Card>; })}
      <PeriodStats game={game} events={events} players={data.players} teamName={teamName} layout={statsLayout} />
      {replayGenerating && <Card className="print:hidden"><CardHeader><CardTitle>{t("Replay Video")}</CardTitle></CardHeader><CardContent className="text-sm text-muted-foreground">{t("Generating an AI highlight of this game. This usually takes one to three minutes; the video appears here when it is ready.")}</CardContent></Card>}
      {replay?.status === "ready" && replay.video_url && <Card id="replay-video" className="scroll-mt-24 print:hidden"><CardHeader><CardTitle>{t("Replay Video")}</CardTitle></CardHeader><CardContent><video controls playsInline preload="metadata" src={replay.video_url} className="aspect-video w-full rounded-md bg-black" /></CardContent></Card>}
      {user && game.uuid_id && <HighlightsCard gameUuid={game.uuid_id} away={{ id: game.away_id, label: t("{team} (Away)", { team: teamName(game.away_id) }) }} home={{ id: game.home_id, label: t("{team} (Home)", { team: teamName(game.home_id) }) }} players={data.players} events={events} canEdit={canEdit} />}
      <Card><CardHeader className="flex-wrap gap-y-3"><CardTitle>{t("Play-by-play")} <span className="text-sm font-normal text-muted-foreground">{t("{count} total", { count: events.length })}{canEdit && orderedEvents.length > 0 ? ` · ${t("Click a play to edit it")}` : ""}</span></CardTitle>
        <div className="ml-auto flex flex-wrap items-center gap-1.5"><div className="flex flex-wrap gap-1.5" role="group" aria-label={t("Play filters")}>{playFilters.map((filter) => <Button key={filter.id} size="sm" variant={playFilter === filter.id ? "default" : "outline"} aria-pressed={playFilter === filter.id} onClick={() => setPlayFilter(filter.id)}>{t(filter.label)}</Button>)}</div>{orderedEvents.length > 0 && <Button size="sm" variant="outline" className="whitespace-nowrap" aria-label={t("Copy all plays")} onClick={copyPlays}>{copied ? <Check className="size-4" /> : <Copy className="size-4" />}{copied ? t("Copied") : t("Copy")}</Button>}</div>
      </CardHeader><CardContent className="px-0">
        {orderedEvents.length ? <div className="playTimelineWeb">
          <div className="playTimelineWebHeader"><span>{t("{team} (Away)", { team: teamName(game.away_id) })}</span><b>{t("Time")}</b><span>{t("{team} (Home)", { team: teamName(game.home_id) })}</span></div>
          {periodGroups.map((group) => {
            const collapsed = collapsedPeriods.has(group.period);
            const label = periodGroupLabel(group.period, game.period_count, t);
            return <div key={group.period} className="playTimelineWebPeriod" data-period={group.period} data-collapsed={collapsed || undefined}>
              <button type="button" className="playTimelineWebPeriodHeader" aria-expanded={!collapsed} aria-controls={`period-${group.period}-plays`} onClick={() => togglePeriod(group.period)}>
                {collapsed ? <ChevronRight className="size-4" /> : <ChevronDown className="size-4" />}
                <b>{label}</b>
                <span>{playFilter === "all" ? t("{count} plays", { count: group.total }) : t("{shown} of {total} plays", { shown: group.plays.length, total: group.total })}</span>
                <em>{group.endScore.away} - {group.endScore.home}</em>
              </button>
              {!collapsed && <div id={`period-${group.period}-plays`}>
                {group.plays.length ? group.plays.map((event) => {
                  const isHome = event.team_id === game.home_id;
                  const { action, displayName } = describePlay(event);
                  const scoring = isScoringPlay(event.type);
                  const score = runningScores.get(event.id) ?? { away: 0, home: 0 };
                  const cells = <>
                    <div className={`playTimelineWebEvent ${isHome ? "home" : "away"}`}><span>{isHome ? displayName : action}</span><strong>{isHome ? action : displayName}</strong>{scoring && <em>{event.value > 0 ? `+${event.value}` : event.value}</em>}</div>
                    <div className="playTimelineWebTime"><strong>{formatClock(event.game_clock_ms)}</strong>{scoring && <span>{score.away} - {score.home}</span>}</div>
                  </>;
                  // Editors open the play with a click; viewers get the plain row.
                  return canEdit
                    ? <button type="button" className={`playTimelineWebRow ${scoring ? "scoring" : ""}`} key={event.id} aria-label={t("Edit play: {action} {player} {clock}", { action, player: displayName, clock: formatClock(event.game_clock_ms) })} onClick={() => setEditingPlay(event)}>{cells}</button>
                    : <div className={`playTimelineWebRow ${scoring ? "scoring" : ""}`} key={event.id}>{cells}</div>;
                }) : <p className="playTimelineWebEmpty">{t("No {filter} plays in {period}.", { filter: t(playFilters.find((filter) => filter.id === playFilter)?.label ?? "").toLowerCase(), period: label })}</p>}
              </div>}
            </div>;
          })}
        </div> : <p className="px-4 py-6 text-sm text-muted-foreground">{t("No plays recorded.")}</p>}
      </CardContent></Card>
    </>}
  </RestShell>;
}
