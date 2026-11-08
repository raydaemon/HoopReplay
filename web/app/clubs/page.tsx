"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { Eye, Plus } from "lucide-react";
import { RestError, RestShell } from "../rest-shell";
import { useSnapshot, errorMessage } from "@/lib/use-snapshot";
import { createClub, loadClubs, type Club } from "@/lib/game-access";
import { DataTable } from "@/components/data-table";
import type { ColumnDef } from "@/components/table-features";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useI18n } from "@/lib/i18n";

export default function ClubsPage() {
  const { user, authReady, saving, status } = useSnapshot();
  const { t } = useI18n();
  const router = useRouter();
  const [clubs, setClubs] = useState<Club[]>([]);
  const [name, setName] = useState("");
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [loaded, setLoaded] = useState(false);
  const reload = useCallback(async () => {
    if (!user) return setClubs([]);
    try { setClubs(await loadClubs(user.id)); setError(""); }
    catch (reason) { setError(errorMessage(reason, t("Unable to load clubs"))); }
    finally { setLoaded(true); }
  }, [user, t]);
  const loading = !authReady || (user !== null && !loaded);
  useEffect(() => { const initial = window.setTimeout(reload, 0); return () => clearTimeout(initial); }, [reload]);
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!user || !name.trim()) return;
    setBusy(true);
    try { await createClub(name, user.id); setName(""); setOpen(false); await reload(); }
    catch (reason) { setError(errorMessage(reason, t("Unable to create club"))); }
    finally { setBusy(false); }
  };
  const columns: ColumnDef<Club>[] = [
    { accessorKey: "name", header: t("Name") },
    { id: "actions", header: "", enableSorting: false, enableGlobalFilter: false, meta: { cellClassName: "text-right", headClassName: "text-right" }, cell: ({ row }) => <Button variant="outline" size="icon" className="size-[27px] min-h-0 min-w-0 p-0" aria-label={t("View club")} title={t("View club")} onClick={() => router.push(`/clubs/${row.original.id}`)}><Eye className="size-3" /></Button> },
  ];
  return <RestShell current="clubs" title={t("Clubs")} status={status} saving={saving || busy} user={user} authReady={authReady}>
    {error && <RestError>{error}</RestError>}
    <Dialog open={open} onOpenChange={setOpen}><DialogContent><form onSubmit={submit}><DialogHeader><DialogTitle>{t("Create club")}</DialogTitle><DialogDescription>{t("Create a club, then add members from its detail page.")}</DialogDescription></DialogHeader><div className="space-y-1.5"><Label htmlFor="club-name">{t("Name")}</Label><Input id="club-name" value={name} onChange={event => setName(event.target.value)} placeholder={t("Club name")} /></div><DialogFooter className="mt-4"><Button type="button" variant="outline" onClick={() => setOpen(false)}>{t("Cancel")}</Button><Button type="submit" disabled={busy || !user}>{t("Create club")}</Button></DialogFooter></form></DialogContent></Dialog>
    <Card><CardHeader><CardTitle>{t("All clubs")}</CardTitle>{!loading && <span className="text-xs font-bold text-muted-foreground">{clubs.length}</span>}</CardHeader><CardContent className="px-0"><DataTable storageKey="clubs" columns={columns} data={clubs} searchPlaceholder={t("Search clubs…")} empty={t("No clubs yet.")} loading={loading} onRefresh={reload} toolbar={<Button size="xs" className="ml-auto" onClick={() => setOpen(true)}><Plus className="size-4" />{t("Create club")}</Button>} /></CardContent></Card>
  </RestShell>;
}
