"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { useSnapshot } from "@/lib/use-snapshot";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { RestError, RestLoading, RestShell } from "../../rest-shell";
import { useI18n } from "@/lib/i18n";

export default function PlayerDetailsPage() {
  const { data, authReady, loading, saving, status, user } = useSnapshot();
  const { t } = useI18n();
  const params = useParams<{ id: string }>();
  const player = data.players.find((item) => item.id === params.id);
  const team = player && data.teams.find((item) => item.id === player.team_id);
  return <RestShell current="players" title={t("Player details")} status={status} saving={saving} user={user} authReady={authReady}>
    <Button asChild variant="ghost" className="w-fit"><Link href="/players"><ArrowLeft className="size-4" />{t("Back to players")}</Link></Button>
    {!player ? (loading ? <RestLoading /> : <RestError>{t("Player not found.")}</RestError>) : <Card><CardHeader><CardTitle>{player.name || `#${player.number}`}</CardTitle></CardHeader><CardContent className="space-y-2 text-sm"><p>{t("Jersey number: {number}", { number: player.number || "—" })}</p><p>{t("Team: {name}", { name: team?.name ?? t("Unknown") })}</p></CardContent></Card>}
  </RestShell>;
}
