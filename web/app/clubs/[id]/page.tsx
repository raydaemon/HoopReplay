"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { ArrowLeft, Trash2 } from "lucide-react";
import { RestError, RestLoading, RestShell } from "../../rest-shell";
import { useSnapshot, errorMessage } from "@/lib/use-snapshot";
import { addClubMember, loadClubMembers, loadClubs, removeClubMember, type Club, type ClubMember } from "@/lib/game-access";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useI18n } from "@/lib/i18n";

export default function ClubDetailsPage() {
  const { user, authReady, saving, status } = useSnapshot();
  const { t } = useI18n();
  const params = useParams<{ id: string }>();
  const [club, setClub] = useState<Club | null>(null);
  const [members, setMembers] = useState<ClubMember[]>([]);
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [pending, setPending] = useState<ClubMember | null>(null);
  const [loaded, setLoaded] = useState(false);
  const reload = useCallback(async () => {
    if (!user) return;
    try { const [clubs, rows] = await Promise.all([loadClubs(user.id), loadClubMembers(params.id)]); setClub(clubs.find(item => item.id === params.id) ?? null); setMembers(rows); setError(""); }
    catch (reason) { setError(errorMessage(reason, t("Unable to load club"))); }
    finally { setLoaded(true); }
  }, [params.id, user, t]);
  const loading = !authReady || (user !== null && !loaded);
  useEffect(() => { const initial = window.setTimeout(reload, 0); return () => clearTimeout(initial); }, [reload]);
  const run = async (action: () => Promise<void>) => { setBusy(true); try { await action(); await reload(); setError(""); } catch (reason) { setError(errorMessage(reason, t("Club update failed"))); } finally { setBusy(false); } };
  const submit = (event: FormEvent) => { event.preventDefault(); if (!email.trim()) return; void run(async () => { await addClubMember(params.id, email); setEmail(""); }); };
  return <RestShell current="clubs" title={t("Club details")} status={status} saving={saving || busy} user={user} authReady={authReady}>
    <Button asChild variant="ghost" className="w-fit"><Link href="/clubs"><ArrowLeft className="size-4" />{t("Back to clubs")}</Link></Button>
    {error && <RestError>{error}</RestError>}
    {!club ? (loading ? <RestLoading /> : <RestError>{t("Club not found.")}</RestError>) : <><Card><CardHeader><CardTitle>{club.name}</CardTitle></CardHeader><CardContent><form className="flex flex-col gap-3 sm:flex-row sm:items-end" onSubmit={submit}><div className="flex-1 space-y-1.5"><Label htmlFor="club-member-email">{t("Add club member")}</Label><Input id="club-member-email" type="email" value={email} onChange={event => setEmail(event.target.value)} placeholder="member@example.com" /></div><Button type="submit" disabled={busy}>{t("Add member")}</Button></form></CardContent></Card><Card><CardHeader><CardTitle>{t("Members ({count})", { count: members.length })}</CardTitle></CardHeader><CardContent className="space-y-2">{members.length ? members.map(member => <div className="flex items-center justify-between rounded-md border p-2 text-sm" key={member.member_email}><span>{member.member_email}</span><Button variant="ghost" size="icon" aria-label={t("Remove club member")} onClick={() => setPending(member)}><Trash2 className="size-4" /></Button></div>) : <p className="text-sm text-muted-foreground">{t("No members yet.")}</p>}</CardContent></Card></>}
    <ConfirmDialog open={Boolean(pending)} title={t("Remove club member?")} description={t("Remove {email} from the club?", { email: pending?.member_email ?? t("this member") })} confirmLabel={t("Remove")} onOpenChange={open => { if (!open) setPending(null); }} onConfirm={() => { const member = pending; setPending(null); if (member) void run(() => removeClubMember(member.club_id, member.member_email)); }} />
  </RestShell>;
}
