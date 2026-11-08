"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { RestError, RestShell } from "../rest-shell";
import { tombstones, useSnapshot } from "@/lib/use-snapshot";
import { nextId } from "@/lib/local-id";
import type { Team } from "@/lib/types";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { DataTable } from "@/components/data-table";
import type { ColumnDef } from "@/components/table-features";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Eye, Pencil, Plus, Trash2 } from "lucide-react";
import { useI18n } from "@/lib/i18n";

type TeamRow = Team & { players: number };

export default function TeamsPage() {
  const { data, user, authReady, loading, saving, status, mutate, reload } = useSnapshot();
  const { t } = useI18n();
  const router = useRouter();
  const [name, setName] = useState("");
  const [editing, setEditing] = useState<Team | null>(null);
  const [error, setError] = useState("");
  const [pendingDelete, setPendingDelete] = useState<Team | null>(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  // The dashboard's Add Team action arrives as ?new=1 and opens the form straight away.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reading the URL once on arrival
    if (new URLSearchParams(window.location.search).get("new") === "1") setDialogOpen(true);
  }, []);

  const rows = useMemo<TeamRow[]>(() => {
    const counts = new Map<number, number>();
    for (const player of data.players) {
      counts.set(player.team_id, (counts.get(player.team_id) ?? 0) + 1);
    }
    return data.teams.map((team) => ({ ...team, players: counts.get(team.id) ?? 0 }));
  }, [data.players, data.teams]);

  const reset = () => {
    setEditing(null);
    setName("");
    setError("");
    setDialogOpen(false);
  };

  function submit(event: FormEvent) {
    event.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) return setError(t("A team needs a name."));
    if (editing) {
      mutate((d) => ({
        ...d,
        teams: d.teams.map((team) => team.id === editing.id ? { ...team, name: trimmed } : team),
      }));
    } else {
      mutate((d) => ({
        ...d,
        teams: [...d.teams, { id: nextId(d.teams), name: trimmed, created_at: Date.now() }],
      }));
    }
    reset();
  }

  function remove(team: Team) {
    if (data.games.some((game) => game.home_id === team.id || game.away_id === team.id)) {
      setPendingDelete(null);
      setError(t("This team is used by a game. Delete the related game first."));
      return;
    }
    const players = data.players.filter((player) => player.team_id === team.id);
    mutate((d) => ({
      ...d,
      teams: d.teams.filter((row) => row.id !== team.id),
      players: d.players.filter((row) => row.team_id !== team.id),
      deletions: [
        ...d.deletions,
        ...tombstones("teams", [team.id]),
        ...tombstones("players", players.map((player) => player.id)),
      ],
    }));
    if (editing?.id === team.id) reset();
    setPendingDelete(null);
    setError("");
  }

  // Rebuilt each render on purpose: the action cells close over the current snapshot.
  const columns: ColumnDef<TeamRow>[] = [
    { accessorKey: "name", header: t("Name") },
    { accessorKey: "players", header: t("Players") },
    {
      accessorKey: "created_at",
      header: t("Created"),
      cell: ({ row }) => new Date(row.original.created_at).toLocaleDateString(),
    },
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
            aria-label={t("View team")}
            title={t("View team")}
            onClick={() => router.push(`/teams/${row.original.id}`)}
          ><Eye className="size-3" /></Button>
          <Button
            variant="outline"
            size="icon"
            className="size-[27px] min-h-0 min-w-0 p-0"
            aria-label={t("Edit team")}
            title={t("Edit team")}
            onClick={() => {
              setEditing(row.original);
              setName(row.original.name);
              setError("");
              setDialogOpen(true);
            }}
          >
            <Pencil className="size-3" />
          </Button>
          <Button
            variant="destructive"
            size="icon"
            className="size-[27px] min-h-0 min-w-0 p-0"
            aria-label={t("Delete team")}
            title={t("Delete team")}
            onClick={() => setPendingDelete(row.original)}
          ><Trash2 className="size-3" /></Button>
        </div>
      ),
    },
  ];

  return (
    <RestShell
      current="teams"
      title={t("Teams")}
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
              <DialogTitle>{editing ? t("Edit team") : t("Add team")}</DialogTitle>
              <DialogDescription>{editing ? t("Update team #{id}.", { id: editing.id }) : t("Create a new team.")}</DialogDescription>
            </DialogHeader>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="team-name">{t("Name")}</Label>
              <Input
                id="team-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder={t("Team name")}
                className="max-w-80"
              />
            </div>
            <DialogFooter className="mt-4">
              <Button type="button" variant="outline" onClick={reset}>{t("Cancel")}</Button>
              <Button type="submit" disabled={!user}>{editing ? t("Save team") : t("Create team")}</Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
      <Card>
        <CardHeader>
          <CardTitle>{t("All teams")}</CardTitle>
          {!loading && <span className="text-xs font-bold text-muted-foreground">{rows.length}</span>}
        </CardHeader>
        <CardContent className="px-0">
          <DataTable
            storageKey="teams"
            columns={columns}
            data={rows}
            searchPlaceholder={t("Search teams…")}
            empty={t("No teams yet.")}
            loading={loading}
            onRefresh={reload}
            toolbar={
              <Button variant="ghost" size="icon-xs" className="ml-auto" onClick={() => { setEditing(null); setName(""); setError(""); setDialogOpen(true); }} aria-label={t("Add team")} title={t("Add team")}>
                <Plus className="size-4" />
              </Button>
            }
          />
        </CardContent>
      </Card>
      <ConfirmDialog
        open={pendingDelete !== null}
        title={t("Delete {name}?", { name: pendingDelete?.name ?? "" })}
        description={t("This also deletes all of its players.")}
        onConfirm={() => pendingDelete && remove(pendingDelete)}
        onOpenChange={(open) => !open && setPendingDelete(null)}
      />
    </RestShell>
  );
}
