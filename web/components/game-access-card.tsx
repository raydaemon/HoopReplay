"use client";

import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import type { Game, Team } from "@/lib/types";
import {
  addGamePermission, loadAccessManagement, removeGamePermission,
  type AccessRole, type AccessSubject, type Club, type GamePermission,
} from "@/lib/game-access";
import { errorMessage } from "@/lib/use-snapshot";
import { Badge } from "@/components/ui/badge";
import { titleCase } from "@/lib/text";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { Trash2, X } from "lucide-react";
import { useI18n } from "@/lib/i18n";

type PendingRemoval = { label: string; run: () => Promise<void> };

export function GameAccessCard({ game, teams, userId, dialogOpen, onDialogOpenChange, hideTrigger = false, showPanel = true }: { game: Game; teams: Team[]; userId: string; dialogOpen?: boolean; onDialogOpenChange?: (open: boolean) => void; hideTrigger?: boolean; showPanel?: boolean }) {
  const { t } = useI18n();
  const ownerId = game.owner_id ?? userId;
  const role = game.access_role ?? (ownerId === userId ? "owner" : "viewer");
  const isOwner = role === "owner";
  const [permissions, setPermissions] = useState<GamePermission[]>([]);
  const [clubs, setClubs] = useState<Club[]>([]);
  const [grantRole, setGrantRole] = useState<AccessRole>("viewer");
  const [subject, setSubject] = useState<AccessSubject>("user");
  const [subjectValue, setSubjectValue] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [internalDialogOpen, setInternalDialogOpen] = useState(false);
  const accessDialogOpen = dialogOpen ?? internalDialogOpen;
  const setAccessDialogOpen = onDialogOpenChange ?? setInternalDialogOpen;
  const [pendingRemoval, setPendingRemoval] = useState<PendingRemoval | null>(null);

  const reload = useCallback(async () => {
    if (!isOwner) return;
    try {
      const data = await loadAccessManagement(game, userId);
      setPermissions(data.permissions); setClubs(data.clubs);
      setError("");
    } catch (reason) { setError(errorMessage(reason, t("Unable to load access settings"))); }
  }, [game, isOwner, userId, t]);

  useEffect(() => {
    const initial = window.setTimeout(reload, 0);
    return () => window.clearTimeout(initial);
  }, [reload]);

  const clubNames = useMemo(() => new Map(clubs.map(club => [club.id, club.name])), [clubs]);
  const teamNames = useMemo(() => new Map(teams.map(team => [team.id, team.name])), [teams]);
  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    try { await action(); await reload(); setError(""); }
    catch (reason) { setError(errorMessage(reason, t("Access update failed"))); }
    finally { setBusy(false); }
  };
  const subjectLabel = (permission: GamePermission) => permission.subject_type === "everyone" ? t("All signed-in users")
    : permission.subject_type === "user" ? permission.subject_email
    : permission.subject_type === "club" ? t("Club: {name}", { name: clubNames.get(permission.subject_club_id ?? "") ?? t("Unknown") })
    : t("Team: {name}", { name: teamNames.get(permission.subject_team_id ?? "") ?? t("Unknown") });

  function grant(event: FormEvent) {
    event.preventDefault();
    if (subject !== "everyone" && !subjectValue) return setError(t("Choose or enter who receives access."));
    void run(async () => { await addGamePermission(game, userId, grantRole, subject, subjectValue); setSubjectValue(""); setAccessDialogOpen(false); });
  }

  // The header owns the primary Add access action. Do not reserve a blank card
  // in the game detail page until there is an actual permission to review.
  const panelVisible = showPanel && (!isOwner || permissions.length > 0);

  return <Card className={panelVisible ? undefined : "hidden"}>
    <CardHeader><CardTitle className="flex items-center justify-between gap-3">{t("Access")} <Badge variant="secondary">{t(titleCase(role))}</Badge></CardTitle></CardHeader>
    <CardContent className="space-y-5">
      {!isOwner ? <p className="text-sm text-muted-foreground">{role === "editor" ? t("You can edit this game and its plays.") : t("You have read-only access to this game.")}</p> : <>
        <Dialog open={accessDialogOpen} onOpenChange={setAccessDialogOpen}>
          {!hideTrigger && <DialogTrigger asChild><Button>{t("Add access")}</Button></DialogTrigger>}
          <DialogContent>
            <DialogClose asChild><Button className="absolute right-4 top-4" variant="ghost" size="icon" aria-label={t("Cancel")}><X className="size-4" /></Button></DialogClose>
            <DialogHeader><DialogTitle>{t("Add access")}</DialogTitle><DialogDescription>{t("Choose who can access this game and what they can do.")}</DialogDescription></DialogHeader>
            <form className="grid gap-4" onSubmit={grant}>
              <div><Label>{t("Role")}</Label><Select value={grantRole} onValueChange={(value) => { const next = value as AccessRole; setGrantRole(next); if (next === "editor") { setSubject("user"); setSubjectValue(""); } }}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent><SelectItem value="viewer">{t("Viewer")}</SelectItem><SelectItem value="editor">{t("Editor")}</SelectItem></SelectContent></Select></div>
              <div><Label>{t("Audience")}</Label><Select value={subject} onValueChange={(value) => { setSubject(value as AccessSubject); setSubjectValue(""); }}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent><SelectItem value="user">{t("Email")}</SelectItem>{grantRole === "viewer" && <><SelectItem value="club">{t("Club")}</SelectItem><SelectItem value="team">{t("Team")}</SelectItem><SelectItem value="everyone">{t("Everyone")}</SelectItem></>}</SelectContent></Select></div>
              <div><Label>{t("Recipient")}</Label>{subject === "user" ? <Input type="email" placeholder="person@example.com" value={subjectValue} onChange={event => setSubjectValue(event.target.value)} /> : subject === "club" ? <Select value={subjectValue} onValueChange={setSubjectValue}><SelectTrigger><SelectValue placeholder={t("Choose club")} /></SelectTrigger><SelectContent>{clubs.map(club => <SelectItem key={club.id} value={club.id}>{club.name}</SelectItem>)}</SelectContent></Select> : subject === "team" ? <Select value={subjectValue} onValueChange={setSubjectValue}><SelectTrigger><SelectValue placeholder={t("Choose team")} /></SelectTrigger><SelectContent>{teams.map(team => <SelectItem key={team.id} value={String(team.id)}>{team.name}</SelectItem>)}</SelectContent></Select> : <Input value={t("All signed-in users")} disabled />}</div>
              <DialogFooter><DialogClose asChild><Button variant="outline" type="button">{t("Cancel")}</Button></DialogClose><Button disabled={busy} type="submit">{t("Add access")}</Button></DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
        <div className="space-y-2">{permissions.map(permission => <div className="flex items-center justify-between rounded-md border p-2" key={permission.id}><div><Badge>{t(titleCase(permission.role))}</Badge> <span className="ml-2 text-sm">{subjectLabel(permission)}</span></div><Button variant="ghost" size="icon" aria-label={t("Remove access")} onClick={() => setPendingRemoval({ label: String(subjectLabel(permission)), run: () => removeGamePermission(permission.id) })}><Trash2 className="size-4" /></Button></div>)}</div>
      </>}
      {error && <p className="text-sm text-destructive">{error}</p>}
      <ConfirmDialog open={Boolean(pendingRemoval)} title={t("Remove access?")} description={t("Remove {name}?", { name: pendingRemoval?.label ?? t("this entry") })} confirmLabel={t("Remove")} onOpenChange={open => { if (!open) setPendingRemoval(null); }} onConfirm={() => { const action = pendingRemoval?.run; setPendingRemoval(null); if (action) void run(action); }} />
    </CardContent>
  </Card>;
}
