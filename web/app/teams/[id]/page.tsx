"use client";

import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { ArrowLeft, Eye, GitMerge, ListPlus, Pencil, Plus, Trash2 } from "lucide-react";
import { tombstones, useSnapshot } from "@/lib/use-snapshot";
import { newId } from "@/lib/local-id";
import { joinName, splitName } from "@/lib/player-name";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { DataTable } from "@/components/data-table";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { ColumnDef } from "@/components/table-features";
import type { Player } from "@/lib/types";
import { comparePlayers } from "@/lib/player-sort";
import { addTeamMember, loadTeamMembers, removeTeamMember, type TeamMember } from "@/lib/game-access";
import { RestError, RestLoading, RestShell } from "../../rest-shell";
import { useI18n } from "@/lib/i18n";

const emptyForm = { first: "", last: "", number: "" };

export default function TeamDetailsPage() {
  const { data, user, authReady, loading, saving, status, mutate, reload } = useSnapshot();
  const { t } = useI18n();
  const params = useParams<{ id: string }>();
  const router = useRouter();
  const team = data.teams.find((item) => item.id === params.id);
  const players = useMemo(
    () =>
      data.players
        .filter((player) => player.team_id === team?.id)
        .sort(comparePlayers),
    [data.players, team?.id],
  );

  const [dialogOpen, setDialogOpen] = useState(false);
  const [batchOpen, setBatchOpen] = useState(false);
  const [batchText, setBatchText] = useState("");
  const [form, setForm] = useState(emptyForm);
  const [editing, setEditing] = useState<Player | null>(null);
  const [mergeSourceId, setMergeSourceId] = useState("");
  const [pendingMerge, setPendingMerge] = useState<Player | null>(null);
  const [pendingDelete, setPendingDelete] = useState<Player | null>(null);
  const [error, setError] = useState("");
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [memberEmail, setMemberEmail] = useState("");
  const [teamMembers, setTeamMembers] = useState<TeamMember[]>([]);
  const [memberBusy, setMemberBusy] = useState(false);
  const [pendingMember, setPendingMember] = useState<TeamMember | null>(null);

  const reloadMembers = useCallback(async () => {
    if (!team || !user) return setTeamMembers([]);
    try { setTeamMembers(await loadTeamMembers(team, user.id)); }
    catch (reason) { setError(reason instanceof Error ? reason.message : t("Unable to load team members.")); }
  }, [team, user, t]);
  useEffect(() => { const initial = window.setTimeout(reloadMembers, 0); return () => clearTimeout(initial); }, [reloadMembers]);

  const runMemberAction = async (action: () => Promise<void>) => {
    setMemberBusy(true);
    try { await action(); await reloadMembers(); setError(""); }
    catch (reason) { setError(reason instanceof Error ? reason.message : t("Team member update failed.")); }
    finally { setMemberBusy(false); }
  };

  const submitMember = (event: FormEvent) => {
    event.preventDefault();
    if (!team || !user || !memberEmail.trim()) return;
    void runMemberAction(async () => { await addTeamMember(team, user.id, memberEmail); setMemberEmail(""); });
  };

  const reset = () => {
    setEditing(null);
    setMergeSourceId("");
    setForm(emptyForm);
    setError("");
    setDialogOpen(false);
  };

  function submitBatch(event: FormEvent) {
    event.preventDefault();
    if (!team) return;
    // One player per line, whitespace collapsed; an optional leading number is the jersey.
    const parsed = batchText.split(/\r?\n/)
      .map((line) => line.replace(/\s+/g, " ").trim())
      .filter(Boolean)
      .map((line) => {
        const withNumber = line.match(/^(\d{1,3}) (.+)$/);
        return withNumber ? { number: withNumber[1], name: withNumber[2] } : { number: "", name: line };
      });
    if (!parsed.length) return setError(t("Paste at least one player, one per line."));
    // The same player pasted twice (or already on the roster) is added only once.
    const seen = new Set(players.map((player) => `${player.number}\u0000${player.name}`));
    const fresh = parsed.filter((entry) => {
      const key = `${entry.number}\u0000${entry.name}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
    if (fresh.length) {
      mutate((d) => ({ ...d, players: [...d.players, ...fresh.map((entry) => ({ id: newId(), team_id: team.id, ...entry }))] }));
    }
    setBatchText("");
    setError("");
    setBatchOpen(false);
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!team) return;
    const name = joinName(form.first, form.last);
    const number = form.number.trim();
    // The schema requires at least one of the two, so reject the empty pair up front.
    if (!name && !number) return setError(t("A player needs a name or a jersey number."));
    mutate((d) => ({ ...d, players: editing
      ? d.players.map((player) => player.id === editing.id ? { ...player, name, number } : player)
      : [...d.players, { id: newId(), team_id: team.id, name, number }],
    }));
    reset();
  }

  function remove(player: Player) {
    mutate((d) => ({
      ...d,
      players: d.players.filter((row) => row.id !== player.id),
      events: d.events.map((event) => event.player_id === player.id ? { ...event, player_id: null } : event),
      deletions: [...d.deletions, ...tombstones("players", [player.id])],
    }));
    setPendingDelete(null);
  }

  function mergePlayer(source: Player) {
    if (!editing || !team) return;
    const target = editing;
    const name = joinName(form.first, form.last);
    const number = form.number.trim();
    if (!name && !number) return setError(t("A player needs a name or a jersey number."));
    mutate((d) => ({
      ...d,
      players: d.players
        .filter((player) => player.id !== source.id)
        .map((player) => player.id === target.id ? { ...player, name, number } : player),
      events: d.events.map((event) => ({
        ...event,
        player_id: event.player_id === source.id ? target.id : event.player_id,
        related_player_id: event.related_player_id === source.id ? target.id : event.related_player_id,
      })),
      deletions: [...d.deletions, ...tombstones("players", [source.id])],
    }));
    setPendingMerge(null);
    reset();
  }

  const columns: ColumnDef<Player>[] = [
    { accessorKey: "number", header: "#", cell: ({ row }) => row.original.number || "—" },
    { id: "first", accessorFn: (row) => splitName(row.name).first, header: t("First name"), cell: ({ row }) => splitName(row.original.name).first || "—" },
    { id: "last", accessorFn: (row) => splitName(row.name).last, header: t("Last name"), cell: ({ row }) => splitName(row.original.name).last || "—" },
    { id: "actions", header: "", enableSorting: false, enableGlobalFilter: false, meta: { cellClassName: "text-right", headClassName: "text-right" }, cell: ({ row }) => <div className="flex justify-end gap-1.5">
      <Button asChild variant="outline" size="icon" className="size-[27px] min-h-0 min-w-0 p-0" aria-label={t("View player")} title={t("View player")}><Link href={`/players/${row.original.id}`}><Eye className="size-3" /></Link></Button>
      <Button variant="outline" size="icon" className="size-[27px] min-h-0 min-w-0 p-0" aria-label={t("Edit player")} title={t("Edit player")} onClick={() => { const player = row.original; const names = splitName(player.name); setEditing(player); setMergeSourceId(""); setForm({ first: names.first, last: names.last, number: player.number }); setError(""); setDialogOpen(true); }}><Pencil className="size-3" /></Button>
      <Button variant="destructive" size="icon" className="size-[27px] min-h-0 min-w-0 p-0" aria-label={t("Delete player")} title={t("Delete player")} onClick={() => setPendingDelete(row.original)}><Trash2 className="size-3" /></Button>
    </div> },
  ];

  function deleteTeam() {
    if (!team) return;
    if (data.games.some((game) => game.home_id === team.id || game.away_id === team.id)) {
      setError(t("This team is used by a game. Delete the related game first."));
      setDeleteOpen(false);
      return;
    }
    const playerIds = data.players.filter((player) => player.team_id === team.id).map((player) => player.id);
    mutate((d) => ({
      ...d,
      teams: d.teams.filter((item) => item.id !== team.id),
      players: d.players.filter((player) => player.team_id !== team.id),
      deletions: [...d.deletions, ...tombstones("teams", [team.id]), ...tombstones("players", playerIds)],
    }));
    router.push("/teams");
  }

  return (
    <RestShell current="teams" title={t("Team details")} status={status} saving={saving} user={user} authReady={authReady}>
      <Button asChild variant="ghost" className="w-fit"><Link href="/teams"><ArrowLeft className="size-4" />{t("Back to teams")}</Link></Button>
      {error && <RestError>{error}</RestError>}
      {!team ? (loading ? <RestLoading /> : <RestError>{t("Team not found.")}</RestError>) : <>
        <Card>
          <CardHeader><CardTitle>{team.name}</CardTitle><p className="text-sm text-muted-foreground">{t("Created {date}", { date: new Date(team.created_at).toLocaleDateString() })}</p></CardHeader>
        </Card>
        <Card>
          <CardHeader><CardTitle>{t("Team members ({count})", { count: teamMembers.length })}</CardTitle></CardHeader>
          <CardContent className="space-y-4">
            <form className="flex flex-col gap-3 sm:flex-row sm:items-end" onSubmit={submitMember}>
              <div className="flex-1 space-y-1.5"><Label htmlFor="team-member-email">{t("Add team member")}</Label><Input id="team-member-email" type="email" value={memberEmail} onChange={event => setMemberEmail(event.target.value)} placeholder="member@example.com" /></div>
              <Button type="submit" disabled={memberBusy || !user}>{t("Add member")}</Button>
            </form>
            {teamMembers.length ? teamMembers.map(member => <div className="flex items-center justify-between rounded-md border p-2 text-sm" key={member.member_email}><span>{member.member_email}</span><Button variant="ghost" size="icon" aria-label={t("Remove team member")} onClick={() => setPendingMember(member)}><Trash2 className="size-4" /></Button></div>) : <p className="text-sm text-muted-foreground">{t("No members yet.")}</p>}
          </CardContent>
        </Card>
        <Dialog open={dialogOpen} onOpenChange={(open) => !open && reset()}>
          <DialogContent>
            <form onSubmit={submit}>
              <DialogHeader>
                <DialogTitle>{editing ? t("Edit player") : t("Add player")}</DialogTitle>
                <DialogDescription>{editing ? t("Update player #{id}.", { id: editing.id }) : t("Add a player to {name}.", { name: team.name })}</DialogDescription>
              </DialogHeader>
                <div className="flex flex-col gap-3">
                <div className="flex flex-wrap gap-3">
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
                {editing && players.length > 1 && (
                  <div className="rounded-md border border-dashed p-3">
                    <Label htmlFor="merge-player">{t("Merge another player into this player")}</Label>
                    <div className="mt-1.5 flex flex-col gap-2 sm:flex-row sm:items-center">
                      <Select value={mergeSourceId || undefined} onValueChange={setMergeSourceId}>
                        <SelectTrigger id="merge-player" className="flex-1">
                          <SelectValue placeholder={t("Select a player to merge…")} />
                        </SelectTrigger>
                        <SelectContent>
                        {players.filter((player) => player.id !== editing.id).map((player) => (
                          <SelectItem key={player.id} value={String(player.id)}>
                            {player.name || `#${player.number || "—"}`} {player.number ? `(#${player.number})` : ""}
                          </SelectItem>
                        ))}
                        </SelectContent>
                      </Select>
                      <Button
                        type="button"
                        variant="outline"
                        disabled={!mergeSourceId || !user}
                        onClick={() => setPendingMerge(players.find((player) => player.id === mergeSourceId) ?? null)}
                      >
                        <GitMerge className="size-4" /> {t("Merge player")}
                      </Button>
                    </div>
                    <p className="mt-1.5 text-xs text-muted-foreground">{t("Game records move to the current player, and the source player is deleted.")}</p>
                  </div>
                )}
                <DialogFooter className="mt-4">
                  <Button type="button" variant="outline" onClick={reset}>{t("Cancel")}</Button>
                  <Button type="submit" disabled={!user}>{editing ? t("Save player") : t("Add player")}</Button>
                </DialogFooter>
              </div>
            </form>
          </DialogContent>
        </Dialog>
        <Dialog open={batchOpen} onOpenChange={(open) => { if (!open) { setBatchOpen(false); setError(""); } }}>
          <DialogContent>
            <form onSubmit={submitBatch}>
              <DialogHeader>
                <DialogTitle>{t("Batch add players")}</DialogTitle>
                <DialogDescription>
                  {t("One player per line, optionally starting with a jersey number (e.g. “23 Lucas Li”). Duplicate lines and players already on {name} are skipped.", { name: team.name })}
                </DialogDescription>
              </DialogHeader>
              <div className="flex flex-col gap-3">
                <div className="flex flex-col gap-1.5">
                  <Label htmlFor="batch-players">{t("Players")}</Label>
                  <Textarea
                    id="batch-players"
                    value={batchText}
                    onChange={(event) => setBatchText(event.target.value)}
                    placeholder={"23 Lucas Li\nNathan Liu\nMax Ngai"}
                    rows={10}
                  />
                </div>
                <DialogFooter className="mt-4">
                  <Button type="button" variant="outline" onClick={() => { setBatchOpen(false); setError(""); }}>{t("Cancel")}</Button>
                  <Button type="submit" disabled={!user}>{t("Add players")}</Button>
                </DialogFooter>
              </div>
            </form>
          </DialogContent>
        </Dialog>
        <Card>
          <CardHeader>
            <CardTitle>{t("Players ({count})", { count: players.length })}</CardTitle>
          </CardHeader>
          <CardContent className="px-0">
            <DataTable
              storageKey={`team-${team.id}`}
              columns={columns}
              data={players}
              searchPlaceholder={t("Search players…")}
              empty={t("No players yet.")}
              loading={loading}
              onRefresh={reload}
              toolbar={
                <div className="ml-auto flex gap-1.5">
                  <Button
                    variant="ghost"
                    size="icon-xs"
                    onClick={() => { setBatchText(""); setError(""); setBatchOpen(true); }}
                    aria-label={t("Batch add players")}
                    title={t("Batch add players")}
                  >
                    <ListPlus className="size-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon-xs"
                    onClick={() => { setForm(emptyForm); setError(""); setDialogOpen(true); }}
                    aria-label={t("Add player")}
                    title={t("Add player")}
                  >
                    <Plus className="size-4" />
                  </Button>
                </div>
              }
            />
          </CardContent>
        </Card>
        <ConfirmDialog open={pendingDelete !== null} title={t("Delete {name}?", { name: pendingDelete?.name || `#${pendingDelete?.number ?? ""}` })} description={t("Existing events are kept as team events.")} onConfirm={() => pendingDelete && remove(pendingDelete)} onOpenChange={(open) => !open && setPendingDelete(null)} />
        <ConfirmDialog
          open={pendingMerge !== null}
          title={t("Merge player?")}
          description={pendingMerge && editing ? t("Move all records from {source} to {target} and delete the source player?", { source: pendingMerge.name || `#${pendingMerge.number}`, target: editing.name || `#${editing.number}` }) : t("Merge the selected player into this player?")}
          confirmLabel={t("Merge and delete source")}
          confirmVariant="default"
          onConfirm={() => pendingMerge && mergePlayer(pendingMerge)}
          onOpenChange={(open) => !open && setPendingMerge(null)}
        />
        <div className="flex justify-start">
          <Button variant="destructive" disabled={!user} onClick={() => setDeleteOpen(true)}>{t("Delete team")}</Button>
        </div>
      </>}
      <ConfirmDialog
        open={deleteOpen}
        onOpenChange={setDeleteOpen}
        title={t("Delete team?")}
        description={team ? t("Delete {name} and all of its players?", { name: team.name }) : t("Delete this team and all of its players?")}
        onConfirm={deleteTeam}
      />
      <ConfirmDialog open={Boolean(pendingMember)} title={t("Remove team member?")} description={t("Remove {email} from the team?", { email: pendingMember?.member_email ?? t("this member") })} confirmLabel={t("Remove")} onOpenChange={open => { if (!open) setPendingMember(null); }} onConfirm={() => { const member = pendingMember; setPendingMember(null); if (member && team && user) void runMemberAction(() => removeTeamMember(team, user.id, member.member_email)); }} />
    </RestShell>
  );
}
