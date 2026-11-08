"use client";

import { FormEvent, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { RestError, RestShell } from "../rest-shell";
import { tombstones, useSnapshot } from "@/lib/use-snapshot";
import { newId } from "@/lib/local-id";
import { joinName, splitName } from "@/lib/player-name";
import type { Player } from "@/lib/types";
import { comparePlayers } from "@/lib/player-sort";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { DataTable } from "@/components/data-table";
import type { ColumnDef } from "@/components/table-features";
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
import { useI18n } from "@/lib/i18n";

const emptyForm = { first: "", last: "", number: "", team_id: "" as string };
/** Radix selects cannot hold an empty item value, so the "no filter" choice gets a sentinel. */
const ALL_TEAMS = "all";

type PlayerRow = Player & { team: string };

export default function PlayersPage() {
  const { data, user, authReady, loading, saving, status, mutate, reload } = useSnapshot();
  const { t } = useI18n();
  const router = useRouter();
  const [form, setForm] = useState(emptyForm);
  const [editing, setEditing] = useState<Player | null>(null);
  const [teamFilter, setTeamFilter] = useState<string>(ALL_TEAMS);
  const [pendingDelete, setPendingDelete] = useState<Player | null>(null);
  const [error, setError] = useState("");
  const [dialogOpen, setDialogOpen] = useState(false);

  const teamById = useMemo(
    () => new Map(data.teams.map((team) => [team.id, team])),
    [data.teams],
  );
  const rows = useMemo<PlayerRow[]>(
    () =>
      data.players
        .filter((player) => teamFilter === ALL_TEAMS || player.team_id === teamFilter)
        .map((player) => ({ ...player, team: teamById.get(player.team_id)?.name ?? t("Unknown") }))
        .sort((a, b) => comparePlayers(a, b) || a.team.localeCompare(b.team)),
    [data.players, teamById, teamFilter, t],
  );

  const reset = () => {
    setEditing(null);
    setForm(emptyForm);
    setError("");
    setDialogOpen(false);
  };

  function submit(event: FormEvent) {
    event.preventDefault();
    const name = joinName(form.first, form.last);
    const number = form.number.trim();
    if (form.team_id === "") return setError(t("Pick a team for this player."));
    // The schema requires at least one of the two, so reject the empty pair up front.
    if (!name && !number) return setError(t("A player needs a name or a jersey number."));
    const team_id = form.team_id;
    if (editing) {
      mutate((d) => ({
        ...d,
        players: d.players.map((player) =>
          player.id === editing.id ? { ...player, name, number, team_id } : player
        ),
      }));
    } else {
      mutate((d) => ({
        ...d,
        players: [...d.players, { id: newId(), team_id, name, number }],
      }));
    }
    reset();
  }

  function remove(player: Player) {
    mutate((d) => ({
      ...d,
      players: d.players.filter((row) => row.id !== player.id),
      // Events keep a foreign key to the player, so orphan them before the row disappears.
      events: d.events.map((event) =>
        event.player_id === player.id ? { ...event, player_id: null } : event
      ),
      deletions: [...d.deletions, ...tombstones("players", [player.id])],
    }));
    if (editing?.id === player.id) reset();
    setPendingDelete(null);
    setError("");
  }

  // Rebuilt each render on purpose: the action cells close over the current snapshot.
  const columns: ColumnDef<PlayerRow>[] = [
    { accessorKey: "number", header: "#", cell: ({ row }) => row.original.number || "—" },
    { id: "first", accessorFn: (row: PlayerRow) => splitName(row.name).first, header: t("First name"), cell: ({ row }) => splitName(row.original.name).first || "—" },
    { id: "last", accessorFn: (row: PlayerRow) => splitName(row.name).last, header: t("Last name"), cell: ({ row }) => splitName(row.original.name).last || "—" },
    { accessorKey: "team", header: t("Team") },
    {
      id: "actions",
      header: "",
      enableSorting: false,
      enableGlobalFilter: false,
      meta: { cellClassName: "text-right", headClassName: "text-right" },
      cell: ({ row }) => (
        <div className="flex justify-end gap-1.5">
          <Button
            variant="outline"
            size="icon"
            className="size-[27px] min-h-0 min-w-0 p-0"
            aria-label={t("View player")}
            title={t("View player")}
            onClick={() => router.push(`/teams/${row.original.team_id}`)}
          ><Eye className="size-3" /></Button>
          <Button
            variant="outline"
            size="icon"
            className="size-[27px] min-h-0 min-w-0 p-0"
            aria-label={t("Edit player")}
            title={t("Edit player")}
            onClick={() => {
              setEditing(row.original);
              setForm({
                ...splitName(row.original.name),
                number: row.original.number,
                team_id: row.original.team_id,
              });
              setError("");
              setDialogOpen(true);
            }}
          >
            <Pencil className="size-4" />
          </Button>
          <Button
            variant="destructive"
            size="icon"
            className="size-[27px] min-h-0 min-w-0 p-0"
            aria-label={t("Delete player")}
            title={t("Delete player")}
            onClick={() => setPendingDelete(row.original)}
          ><Trash2 className="size-3" /></Button>
        </div>
      ),
    },
  ];

  return (
    <RestShell
      current="players"
      title={t("Players")}
      status={status}
      saving={saving}
      user={user}
      authReady={authReady}
    >
      {error && <RestError>{error}</RestError>}
      <Dialog open={dialogOpen} onOpenChange={(open) => !open && reset()}>
      <DialogContent>
        <form onSubmit={submit}>
          <DialogHeader>
            <DialogTitle>{editing ? t("Edit player") : t("Add player")}</DialogTitle>
            <DialogDescription>{editing ? t("Update player #{id}.", { id: editing.id }) : t("Create a new player.")}</DialogDescription>
          </DialogHeader>
          <div className="flex flex-col gap-3">
            <div className="flex flex-wrap gap-3">
              <div className="flex min-w-44 flex-1 flex-col gap-1.5">
                <Label htmlFor="player-team">{t("Team")}</Label>
                <Select
                  value={form.team_id === "" ? undefined : String(form.team_id)}
                  onValueChange={(value) => setForm({ ...form, team_id: value })}
                >
                  <SelectTrigger id="player-team">
                    <SelectValue placeholder={t("Select a team")} />
                  </SelectTrigger>
                  <SelectContent>
                    {data.teams.map((team) => (
                      <SelectItem key={team.id} value={String(team.id)}>{team.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="flex min-w-44 flex-1 flex-col gap-1.5">
                <Label htmlFor="player-first">{t("First name")}</Label>
                <Input
                  id="player-first"
                  value={form.first}
                  onChange={(event) => setForm({ ...form, first: event.target.value })}
                  placeholder={t("First name")}
                />
              </div>
              <div className="flex min-w-44 flex-1 flex-col gap-1.5">
                <Label htmlFor="player-last">{t("Last name")}</Label>
                <Input
                  id="player-last"
                  value={form.last}
                  onChange={(event) => setForm({ ...form, last: event.target.value })}
                  placeholder={t("Last name")}
                />
              </div>
              <div className="flex min-w-44 flex-1 flex-col gap-1.5">
                <Label htmlFor="player-number">{t("Number")}</Label>
                <Input
                  id="player-number"
                  value={form.number}
                  onChange={(event) => setForm({ ...form, number: event.target.value })}
                  placeholder="00"
                />
              </div>
            </div>
            <DialogFooter className="mt-4">
              <Button type="button" variant="outline" onClick={reset}>{t("Cancel")}</Button>
              <Button type="submit" disabled={!user || data.teams.length === 0}>{editing ? t("Save player") : t("Create player")}</Button>
            </DialogFooter>
            {data.teams.length === 0 && (
              <p className="text-sm text-muted-foreground">
                {t("Create a team first — every player belongs to one.")}
              </p>
            )}
          </div>
        </form>
      </DialogContent>
      </Dialog>

      <Card>
        <CardHeader>
          <CardTitle>{t("All players")}</CardTitle>
          {!loading && <span className="text-xs font-bold text-muted-foreground">{rows.length}</span>}
        </CardHeader>
        <CardContent className="px-0">
          <DataTable
            storageKey="players"
            columns={columns}
            data={rows}
            searchPlaceholder={t("Search players…")}
            empty={t("No players yet.")}
            loading={loading}
            onRefresh={reload}
            toolbar={
              <>
              <Select value={teamFilter} onValueChange={setTeamFilter}>
                <SelectTrigger size="xs" className="w-44" aria-label={t("Filter by team")}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={ALL_TEAMS}>{t("All teams")}</SelectItem>
                  {data.teams.map((team) => (
                    <SelectItem key={team.id} value={String(team.id)}>{team.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Button variant="ghost" size="icon-xs" className="ml-auto" onClick={() => { setEditing(null); setForm(emptyForm); setError(""); setDialogOpen(true); }} aria-label={t("Add player")} title={t("Add player")}><Plus className="size-4" /></Button>
              </>
            }
          />
        </CardContent>
      </Card>
      <ConfirmDialog
        open={pendingDelete !== null}
        title={t("Delete {name}?", { name: pendingDelete?.name || `#${pendingDelete?.number ?? ""}` })}
        description={t("Existing events are kept as team events.")}
        onConfirm={() => pendingDelete && remove(pendingDelete)}
        onOpenChange={(open) => !open && setPendingDelete(null)}
      />
    </RestShell>
  );
}
