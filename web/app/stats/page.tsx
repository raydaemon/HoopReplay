"use client";

import { useMemo, useState } from "react";
import { RestShell } from "../rest-shell";
import { useSnapshot } from "@/lib/use-snapshot";
import { useI18n } from "@/lib/i18n";
import { DataTable } from "@/components/data-table";
import type { ColumnDef } from "@/components/table-features";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

/** A box score line: one player, aggregated over whichever games are in scope. */
type StatRow = {
  id: number;
  number: string;
  name: string;
  team: string;
  games: number;
  points: number;
  fgm: number;
  fga: number;
  tpm: number;
  tpa: number;
  ftm: number;
  fta: number;
  rebounds: number;
  assists: number;
  steals: number;
  blocks: number;
  turnovers: number;
  fouls: number;
};

const ALL = "all";

/** Made/attempted with the percentage, or an em dash when the player never shot. */
function shooting(made: number, attempted: number) {
  return attempted === 0
    ? "—"
    : `${made}/${attempted} · ${Math.round((made / attempted) * 100)}%`;
}

export default function StatsPage() {
  const { data, user, authReady, loading, saving, status, reload } = useSnapshot();
  const { t } = useI18n();
  const [gameId, setGameId] = useState<string>(ALL);
  const [teamId, setTeamId] = useState<string>(ALL);

  const teams = useMemo(
    () => [...data.teams].sort((a, b) => a.name.localeCompare(b.name)),
    [data.teams],
  );
  // Only games the chosen team played in are offered, so the two filters never contradict each other.
  const games = useMemo(
    () =>
      teamId === ALL
        ? data.games
        : data.games.filter((game) => String(game.home_id) === teamId || String(game.away_id) === teamId),
    [data.games, teamId],
  );
  const pickTeam = (next: string) => {
    setTeamId(next);
    if (
      next !== ALL &&
      gameId !== ALL &&
      !data.games.some(
        (game) => String(game.id) === gameId && (String(game.home_id) === next || String(game.away_id) === next),
      )
    ) {
      setGameId(ALL);
    }
  };

  const rows = useMemo<StatRow[]>(() => {
    const teamName = new Map(data.teams.map((team) => [team.id, team.name] as const));
    const blank = (id: number, number: string, name: string, team: string): StatRow => ({
      id,
      number,
      name,
      team,
      games: 0,
      points: 0,
      fgm: 0,
      fga: 0,
      tpm: 0,
      tpa: 0,
      ftm: 0,
      fta: 0,
      rebounds: 0,
      assists: 0,
      steals: 0,
      blocks: 0,
      turnovers: 0,
      fouls: 0,
    });
    const totals = new Map<number, StatRow>(
      data.players
        .filter((player) => teamId === ALL || String(player.team_id) === teamId)
        .map((player) => [
        player.id,
        blank(
          player.id,
          player.number,
          player.name || "—",
          teamName.get(player.team_id) ?? "—",
        ),
      ]),
    );
    // Which games each player actually appeared in, so GP counts appearances rather than rows.
    const appearances = new Map<number, Set<number>>();

    for (const event of data.events) {
      // A reverted event was undone by the scorer, so it must not reach the box score.
      if (event.reverted) continue;
      if (gameId !== ALL && event.game_id !== Number(gameId)) continue;
      if (event.player_id == null) continue;
      const row = totals.get(event.player_id);
      if (!row) continue;
      const seen = appearances.get(event.player_id) ?? new Set<number>();
      seen.add(event.game_id);
      appearances.set(event.player_id, seen);

      switch (event.type) {
        case "PTS_2":
          row.points += 2;
          row.fgm += 1;
          row.fga += 1;
          break;
        case "MISS_2":
          row.fga += 1;
          break;
        case "PTS_3":
          row.points += 3;
          row.fgm += 1;
          row.fga += 1;
          row.tpm += 1;
          row.tpa += 1;
          break;
        case "MISS_3":
          row.fga += 1;
          row.tpa += 1;
          break;
        case "FT_MADE":
          row.points += 1;
          row.ftm += 1;
          row.fta += 1;
          break;
        case "FT_MISS":
          row.fta += 1;
          break;
        case "REB":
          row.rebounds += 1;
          break;
        case "AST":
          row.assists += 1;
          break;
        case "STL":
          row.steals += 1;
          break;
        case "BLK":
          row.blocks += 1;
          break;
        case "TOV":
          row.turnovers += 1;
          break;
        case "FOUL":
          row.fouls += 1;
          break;
      }
    }

    for (const [id, seen] of appearances) {
      const row = totals.get(id);
      if (row) row.games = seen.size;
    }
    return [...totals.values()]
      .filter((row) => row.games > 0)
      .sort((a, b) => b.points - a.points);
  }, [data.events, data.players, data.teams, gameId, teamId]);

  const totals = useMemo(
    () =>
      rows.reduce(
        (sum, row) => ({
          points: sum.points + row.points,
          rebounds: sum.rebounds + row.rebounds,
          assists: sum.assists + row.assists,
        }),
        { points: 0, rebounds: 0, assists: 0 },
      ),
    [rows],
  );

  const numeric = (key: keyof StatRow, header: string): ColumnDef<StatRow> => ({
    accessorKey: key,
    header,
    enableGlobalFilter: false,
    meta: { cellClassName: "text-right tabular-nums", headClassName: "text-right" },
  });

  const columns: ColumnDef<StatRow>[] = [
    { accessorKey: "number", header: "#", cell: ({ row }) => row.original.number || "—", meta: { headClassName: "w-px", cellClassName: "tabular-nums" } },
    { accessorKey: "name", header: t("Player") },
    { accessorKey: "team", header: t("Team") },
    numeric("games", "GP"),
    numeric("points", "PTS"),
    numeric("rebounds", "REB"),
    numeric("assists", "AST"),
    numeric("steals", "STL"),
    numeric("blocks", "BLK"),
    numeric("turnovers", "TOV"),
    numeric("fouls", "PF"),
    {
      id: "fg",
      header: "FG",
      enableSorting: false,
      enableGlobalFilter: false,
      meta: { cellClassName: "text-right tabular-nums", headClassName: "text-right" },
      cell: ({ row }) => shooting(row.original.fgm, row.original.fga),
    },
    {
      id: "tp",
      header: "3P",
      enableSorting: false,
      enableGlobalFilter: false,
      meta: { cellClassName: "text-right tabular-nums", headClassName: "text-right" },
      cell: ({ row }) => shooting(row.original.tpm, row.original.tpa),
    },
    {
      id: "ft",
      header: "FT",
      enableSorting: false,
      enableGlobalFilter: false,
      meta: { cellClassName: "text-right tabular-nums", headClassName: "text-right" },
      cell: ({ row }) => shooting(row.original.ftm, row.original.fta),
    },
  ];

  return (
    <RestShell
      current="stats"
      title={t("Stats")}
      status={status}
      saving={saving}
      user={user}
      authReady={authReady}
    >
      <Card>
        <CardHeader>
          <CardTitle>{t("Box score")}</CardTitle>
          <span className="text-xs text-muted-foreground">
            {totals.points} PTS · {totals.rebounds} REB · {totals.assists} AST
          </span>
        </CardHeader>
        <CardContent className="px-0">
          <DataTable
            columns={columns}
            data={rows}
            searchPlaceholder={t("Search players…")}
            empty={t("No stats recorded yet.")}
            loading={loading}
            storageKey="stats-box-score"
            onRefresh={reload}
            toolbar={
              <>
                <Select value={teamId} onValueChange={pickTeam}>
                  <SelectTrigger size="xs" className="w-44" aria-label={t("Filter by team")}>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={ALL}>{t("All teams")}</SelectItem>
                    {teams.map((team) => (
                      <SelectItem key={team.id} value={String(team.id)}>
                        {team.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Select value={gameId} onValueChange={setGameId}>
                  <SelectTrigger size="xs" className="w-44" aria-label={t("Filter by game")}>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={ALL}>{t("All games")}</SelectItem>
                    {games.map((game) => (
                      <SelectItem key={game.id} value={String(game.id)}>
                        {game.title || t("Game {id}", { id: game.id })}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </>
            }
          />
        </CardContent>
      </Card>
    </RestShell>
  );
}
