"use client";
import { titleCase } from "@/lib/text";

import { FormEvent, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { RestError, RestShell } from "../rest-shell";
import { tombstones, useSnapshot } from "@/lib/use-snapshot";
import { useI18n } from "@/lib/i18n";
import { nextId } from "@/lib/local-id";
import type { Game } from "@/lib/types";
import { isScoringType } from "@/lib/scoring";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { DataTable } from "@/components/data-table";
import type { ColumnDef } from "@/components/table-features";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Eye, Pencil, Plus, Trash2 } from "lucide-react";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

const statuses = [
  "DRAFT",
  "READY",
  "RECORDING",
  "PAUSED",
  "PROCESSING",
  "COMPLETED",
  "FAILED",
  "ERROR",
] as const;
const qualities = ["HIGHEST", "UHD", "FHD", "HD", "SD"];
const filters = ["all", "active", "completed"] as const;

/** `datetime-local` speaks local wall time with no zone, so convert either way by hand. */
function toLocalInput(epoch: number) {
  const date = new Date(epoch - new Date(epoch).getTimezoneOffset() * 60_000);
  return date.toISOString().slice(0, 16);
}

const blankForm = (teams: { id: number }[]) => ({
  title: "",
  home_id: (teams[0]?.id ?? "") as number | "",
  away_id: (teams[1]?.id ?? "") as number | "",
  status: "DRAFT",
  scheduled_at: toLocalInput(Date.now()),
  video_quality: "HIGHEST",
  period_count: 4,
  minutes: 8,
  home_score: 0,
  away_score: 0,
});

type GameRow = Game & { home: string; away: string; plays: number };

export default function GamesPage() {
  const { data, user, authReady, loading, saving, status, mutate, reload } = useSnapshot();
  const { t } = useI18n();
  const [form, setForm] = useState(() => blankForm([]));
  const [editing, setEditing] = useState<Game | null>(null);
  const [error, setError] = useState("");
  const [filter, setFilter] = useState<(typeof filters)[number]>("all");
  const [pendingDelete, setPendingDelete] = useState<Game | null>(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  // The header's global search lands here as ?q=, and the dashboard's New Game action as ?new=1.
  const [initialSearch, setInitialSearch] = useState("");
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reading the URL once on arrival
    setInitialSearch(params.get("q") ?? "");
    if (params.get("new") === "1") setDialogOpen(true);
  }, []);

  const sortedTeams = useMemo(
    () => [...data.teams].sort((a, b) => a.name.localeCompare(b.name)),
    [data.teams],
  );
  const teamById = useMemo(
    () => new Map(data.teams.map((team) => [team.id, team])),
    [data.teams],
  );
  const rows = useMemo<GameRow[]>(() => {
    const counts = new Map<number, number>();
    const scores = new Map<number, { home: number; away: number }>();
    for (const event of data.events) {
      if (event.reverted) continue;
      counts.set(event.game_id, (counts.get(event.game_id) ?? 0) + 1);
      if (isScoringType(event.type)) {
        const score = scores.get(event.game_id) ?? { home: 0, away: 0 };
        if (event.team_id === data.games.find((game) => game.id === event.game_id)?.home_id) score.home += event.value;
        else score.away += event.value;
        scores.set(event.game_id, score);
      }
    }
    return data.games
      .filter((game) =>
        filter === "all" ||
        (filter === "completed" ? game.status === "COMPLETED" : game.status !== "COMPLETED")
      )
      .map((game) => ({
        ...game,
        home_score: scores.get(game.id)?.home ?? game.home_score,
        away_score: scores.get(game.id)?.away ?? game.away_score,
        home: teamById.get(game.home_id)?.name ?? t("Unknown"),
        away: teamById.get(game.away_id)?.name ?? t("Unknown"),
        plays: counts.get(game.id) ?? 0,
      }))
      .sort((a, b) => b.scheduled_at - a.scheduled_at);
  }, [data.events, data.games, filter, teamById, t]);

  const reset = () => {
    setEditing(null);
    setForm(blankForm(sortedTeams));
    setError("");
    setDialogOpen(false);
  };

  function submit(event: FormEvent) {
    event.preventDefault();
    const { home_id, away_id } = form;
    if (home_id === "" || away_id === "") return setError(t("Pick both a home and an away team."));
    if (home_id === away_id) return setError(t("A game needs two different teams."));
    if (form.period_count < 1 || form.minutes <= 0) {
      return setError(t("Periods and period length must be greater than zero."));
    }
    const period_duration_ms = Math.round(form.minutes * 60_000);
    const scheduled_at = new Date(form.scheduled_at).getTime();
    if (!Number.isFinite(scheduled_at)) return setError(t("Enter a valid date and time."));
    const title = form.title.trim() ||
      `${teamById.get(home_id)?.name ?? "Home"} vs ${teamById.get(away_id)?.name ?? "Away"}`;
    const shared = {
      title,
      home_id,
      away_id,
      status: form.status,
      scheduled_at,
      video_quality: form.video_quality,
      period_count: form.period_count,
      period_duration_ms,
      home_score: Math.max(0, form.home_score),
      away_score: Math.max(0, form.away_score),
    };
    if (editing) {
      mutate((d) => ({
        ...d,
        games: d.games.map((game) => game.id === editing.id ? { ...game, ...shared } : game),
      }));
    } else {
      mutate((d) => ({
        ...d,
        games: [...d.games, {
          ...shared,
          id: nextId(d.games),
          current_period: 1,
          clock_remaining_ms: period_duration_ms,
          created_at: Date.now(),
        }],
      }));
    }
    reset();
  }

  function remove(game: Game) {
    const events = data.events.filter((event) => event.game_id === game.id);
    const segments = data.segments.filter((segment) => segment.game_id === game.id);
    mutate((d) => ({
      ...d,
      games: d.games.filter((row) => row.id !== game.id),
      events: d.events.filter((row) => row.game_id !== game.id),
      segments: d.segments.filter((row) => row.game_id !== game.id),
      deletions: [
        ...d.deletions,
        ...tombstones("games", [game.id]),
        ...tombstones("events", events.map((event) => event.id)),
        ...tombstones("segments", segments.map((segment) => segment.id)),
      ],
    }));
    if (editing?.id === game.id) reset();
    setPendingDelete(null);
    setError("");
  }

  // Rebuilt each render on purpose: the action cells close over the current snapshot.
  const columns: ColumnDef<GameRow>[] = [
    { accessorKey: "home", header: t("Home") },
    { accessorKey: "away", header: t("Away") },
    {
      id: "score",
      header: t("Score"),
      enableSorting: false,
      cell: ({ row }) => `${row.original.home_score}–${row.original.away_score}`,
    },
    {
      accessorKey: "status",
      header: t("Status"),
      cell: ({ row }) => (
        <Badge variant={row.original.status === "COMPLETED" ? "secondary" : "default"}>
          {t(titleCase(row.original.status))}
        </Badge>
      ),
    },
    {
      accessorKey: "scheduled_at",
      header: t("Scheduled"),
      cell: ({ row }) => new Date(row.original.scheduled_at).toLocaleString(),
    },
    { accessorKey: "plays", header: t("Plays") },
    {
      accessorKey: "access_role",
      header: t("Access"),
      cell: ({ row }) => <Badge variant="secondary">{t(titleCase(row.original.access_role ?? "owner"))}</Badge>,
    },
    {
      id: "actions",
      header: "",
      enableSorting: false,
      enableGlobalFilter: false,
      meta: { cellClassName: "text-right", headClassName: "text-right" },
      cell: ({ row }) => (
        <div className="flex justify-end gap-1.5">
          <Button asChild variant="outline" size="icon" className="size-[27px] min-h-0 min-w-0 p-0" aria-label={t("View game")} title={t("View game")}>
            <Link href={`/games/${row.original.uuid_id}`}><Eye className="size-3" /></Link>
          </Button>
          <Button
            variant="outline"
            size="icon"
            className="size-[27px] min-h-0 min-w-0 p-0"
            aria-label={t("Edit game")}
            title={t("Edit game")}
            disabled={row.original.access_role === "viewer"}
            onClick={() => {
              const game = row.original;
              setEditing(game);
              setForm({
                title: game.title,
                home_id: game.home_id,
                away_id: game.away_id,
                status: game.status,
                scheduled_at: toLocalInput(game.scheduled_at),
                video_quality: game.video_quality,
                period_count: game.period_count,
                minutes: game.period_duration_ms / 60_000,
                home_score: game.home_score,
                away_score: game.away_score,
              });
              setError("");
              setDialogOpen(true);
            }}
          >
            <Pencil className="size-4" />
          </Button>
          <Button
            variant="destructive"
            disabled={Boolean(row.original.access_role && row.original.access_role !== "owner")}
            size="icon"
            className="size-[27px] min-h-0 min-w-0 p-0"
            aria-label={t("Delete game")}
            title={t("Delete game")}
            onClick={() => setPendingDelete(row.original)}
          ><Trash2 className="size-3" /></Button>
        </div>
      ),
    },
  ];

  const field = "flex min-w-44 flex-1 flex-col gap-1.5";

  return (
    <RestShell
      current="games"
      title={t("Games")}
      status={status}
      saving={saving}
      user={user}
      authReady={authReady}
    >
      {error && <RestError>{error}</RestError>}
      <Dialog open={dialogOpen} onOpenChange={(open) => !open && reset()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <form onSubmit={submit}>
          <DialogHeader>
            <DialogTitle>{editing ? t("Edit game") : t("Add game")}</DialogTitle>
            <DialogDescription>{editing ? t("Update game #{id}.", { id: editing.id }) : t("Create a new game.")}</DialogDescription>
          </DialogHeader>
          <div className="flex flex-col gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="game-title">{t("Title")}</Label>
              <Input
                id="game-title"
                value={form.title}
                onChange={(event) => setForm({ ...form, title: event.target.value })}
                placeholder={t("Generated from the two teams if left blank")}
              />
            </div>
            <div className="flex flex-wrap gap-3">
              <div className={field}>
                <Label htmlFor="game-home">{t("Home team")}</Label>
                <Select
                  value={form.home_id === "" ? undefined : String(form.home_id)}
                  onValueChange={(value) => setForm({ ...form, home_id: Number(value) })}
                >
                  <SelectTrigger id="game-home">
                    <SelectValue placeholder={t("Select a team")} />
                  </SelectTrigger>
                  <SelectContent>
                    {sortedTeams.map((team) => (
                      <SelectItem key={team.id} value={String(team.id)}>{team.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className={field}>
                <Label htmlFor="game-away">{t("Away team")}</Label>
                <Select
                  value={form.away_id === "" ? undefined : String(form.away_id)}
                  onValueChange={(value) => setForm({ ...form, away_id: Number(value) })}
                >
                  <SelectTrigger id="game-away">
                    <SelectValue placeholder={t("Select a team")} />
                  </SelectTrigger>
                  <SelectContent>
                    {sortedTeams.map((team) => (
                      <SelectItem key={team.id} value={String(team.id)}>{team.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className={field}>
                <Label htmlFor="game-status">{t("Status")}</Label>
                <Select
                  value={form.status}
                  onValueChange={(value) => setForm({ ...form, status: value })}
                >
                  <SelectTrigger id="game-status">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {statuses.map((value) => (
                      <SelectItem key={value} value={value}>{t(titleCase(value))}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className={field}>
                <Label htmlFor="game-scheduled">{t("Scheduled")}</Label>
                <Input
                  id="game-scheduled"
                  type="datetime-local"
                  value={form.scheduled_at}
                  onChange={(event) => setForm({ ...form, scheduled_at: event.target.value })}
                />
              </div>
              <div className={field}>
                <Label htmlFor="game-quality">{t("Video quality")}</Label>
                <Select
                  value={form.video_quality}
                  onValueChange={(value) => setForm({ ...form, video_quality: value })}
                >
                  <SelectTrigger id="game-quality">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {qualities.map((value) => (
                      <SelectItem key={value} value={value}>{t(titleCase(value))}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className={field}>
                <Label htmlFor="game-periods">{t("Periods")}</Label>
                <Input
                  id="game-periods"
                  type="number"
                  min={1}
                  value={form.period_count}
                  onChange={(event) =>
                    setForm({ ...form, period_count: Number(event.target.value) })}
                />
              </div>
              <div className={field}>
                <Label htmlFor="game-minutes">{t("Minutes per period")}</Label>
                <Input
                  id="game-minutes"
                  type="number"
                  min={1}
                  value={form.minutes}
                  onChange={(event) => setForm({ ...form, minutes: Number(event.target.value) })}
                />
              </div>
              <div className={field}>
                <Label htmlFor="game-home-score">{t("Home score")}</Label>
                <Input
                  id="game-home-score"
                  type="number"
                  min={0}
                  value={form.home_score}
                  onChange={(event) => setForm({ ...form, home_score: Number(event.target.value) })}
                />
              </div>
              <div className={field}>
                <Label htmlFor="game-away-score">{t("Away score")}</Label>
                <Input
                  id="game-away-score"
                  type="number"
                  min={0}
                  value={form.away_score}
                  onChange={(event) => setForm({ ...form, away_score: Number(event.target.value) })}
                />
              </div>
            </div>
            <DialogFooter className="mt-4">
              <Button type="button" variant="outline" onClick={reset}>{t("Cancel")}</Button>
              <Button type="submit" disabled={!user || data.teams.length < 2}>{editing ? t("Save game") : t("Create game")}</Button>
            </DialogFooter>
            {data.teams.length < 2 && (
              <p className="text-sm text-muted-foreground">
                {t("Create at least two teams before scheduling a game.")}
              </p>
            )}
          </div>
        </form>
      </DialogContent>
      </Dialog>

      <Card>
        <CardHeader>
          <CardTitle>{t("All games")}</CardTitle>
          {!loading && <span className="text-xs font-bold text-muted-foreground">{data.games.length}</span>}
        </CardHeader>
        <CardContent className="px-0">
          <DataTable
            key={initialSearch}
            initialSearch={initialSearch}
            storageKey="games"
            columns={columns}
            data={rows}
            searchPlaceholder={t("Search games…")}
            empty={t("No games yet.")}
            loading={loading}
            onRefresh={reload}
            toolbar={
              <>
              <div className="flex flex-wrap gap-1.5" aria-label={t("Filter games")}>
                {filters.map((value) => (
                  <Button
                    key={value}
                    type="button"
                    size="xs"
                    variant={filter === value ? "default" : "outline"}
                    onClick={() => setFilter(value)}
                  >
                    {t(value[0].toUpperCase() + value.slice(1))}
                  </Button>
                ))}
              </div>
              <Button variant="ghost" size="icon-xs" className="ml-auto" onClick={() => { setEditing(null); setForm(blankForm(sortedTeams)); setError(""); setDialogOpen(true); }} aria-label={t("Add game")} title={t("Add game")}><Plus className="size-4" /></Button>
              </>
            }
          />
        </CardContent>
      </Card>
      <ConfirmDialog
        open={pendingDelete !== null}
        title={t("Delete {name}?", { name: pendingDelete?.title ?? "" })}
        description={t("This also deletes all of its events and video clips.")}
        onConfirm={() => pendingDelete && remove(pendingDelete)}
        onOpenChange={(open) => !open && setPendingDelete(null)}
      />
    </RestShell>
  );
}
