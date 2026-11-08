"use client";

// Player and team highlight videos for one game: the ones phones uploaded and the ones cut in
// the cloud from uploaded footage (spec: docs/superpowers/specs/2026-10-04-video-highlights-design.md).
import { useEffect, useState } from "react";
import { Download, Film, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { PlayerGrid, ScoreDialog } from "@/components/score-dialogs";
import { supabase } from "@/lib/supabase";
import { playerLabel } from "@/lib/scoring";
import { useI18n } from "@/lib/i18n";
import type { Player, StatEvent } from "@/lib/types";

type Highlight = { id: string; target_key: string; target_label: string; source: "phone" | "cloud"; duration_ms: number; clip_count: number; created_at: string; video_url: string; download_url: string };
type Team = { id: number; label: string };

async function api(path: string, init?: RequestInit) {
  const token = (await supabase!.auth.getSession()).data.session?.access_token ?? "";
  const res = await fetch(path, { ...init, headers: { ...init?.headers, "Content-Type": "application/json", Authorization: `Bearer ${token}` } });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(json.error ?? res.statusText), { missing: json.missing as number[] | undefined });
  return json;
}

function length(ms: number) {
  const s = Math.round(ms / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

export function HighlightsCard({ gameUuid, away, home, players, events }: { gameUuid: string; away: Team; home: Team; players: Player[]; events: StatEvent[] }) {
  const { t } = useI18n();
  const [highlights, setHighlights] = useState<Highlight[] | null>(null);
  const [picking, setPicking] = useState(false);
  const [cutting, setCutting] = useState<string | null>(null);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  const [error, setError] = useState("");

  const [version, setVersion] = useState(0);
  useEffect(() => {
    let cancelled = false;
    api(`/api/highlights?game_uuid=${encodeURIComponent(gameUuid)}`)
      .then(rows => { if (!cancelled) setHighlights(rows); })
      .catch(e => { if (!cancelled) { setError(e instanceof Error ? e.message : t("Could not load highlights.")); setHighlights([]); } });
    return () => { cancelled = true; };
  }, [gameUuid, version, t]);

  const cut = async (targetKey: string, label: string) => {
    setPicking(false);
    setCutting(label);
    setError("");
    try {
      // The server cuts a few clips per request (cloud CPU is slow) and answers 202 until all are done.
      for (;;) {
        const result = await api("/api/highlights", { method: "POST", body: JSON.stringify({ game_uuid: gameUuid, target_key: targetKey, target_label: label }) });
        if (result.status !== "cutting") break;
        setProgress({ done: result.done, total: result.total });
      }
      setVersion(v => v + 1);
    } catch (e) {
      const missing = (e as { missing?: number[] }).missing;
      setError(missing?.length
        ? t("Recordings {list} are not uploaded yet. Upload them from the phone that recorded this game, then try again.", { list: missing.join(", ") })
        : e instanceof Error ? e.message : t("Could not cut the highlight."));
    } finally {
      setCutting(null);
      setProgress(null);
    }
  };

  const withPlays = (teamId: number) => players.filter(p => p.team_id === teamId && events.some(e => e.player_id === p.id && !e.reverted));

  return <Card id="highlights" className="scroll-mt-24 print:hidden">
    <CardHeader className="flex-row items-center gap-3">
      <CardTitle>{t("Highlights")}</CardTitle>
      <Button size="sm" variant="outline" className="ml-auto whitespace-nowrap" disabled={cutting !== null} onClick={() => setPicking(true)}>
        {cutting ? <Loader2 className="size-4 animate-spin" /> : <Film className="size-4" />}{cutting ? t("Creating Highlight…") : t("Create Highlight")}
      </Button>
    </CardHeader>
    <CardContent className="flex flex-col gap-4">
      {error && <p className="text-sm text-destructive">{error}</p>}
      {cutting && <p className="text-sm text-muted-foreground">{progress ? t("Cutting the highlight for {target}: {done} of {total} clips…", { target: cutting, done: progress.done, total: progress.total }) : t("Cutting the highlight for {target} from the uploaded recordings. This can take a few minutes.", { target: cutting })}</p>}
      {highlights === null
        ? <p className="flex items-center gap-2 text-sm text-muted-foreground"><Loader2 className="size-4 animate-spin" />{t("Loading highlights…")}</p>
        : highlights.length === 0
          ? <p className="text-sm text-muted-foreground">{t("No highlights yet. Create one here, or from the phone that recorded the game.")}</p>
          : <div className="grid gap-4 md:grid-cols-2">{highlights.map(h => <div key={h.id} className="flex flex-col gap-2">
            <video controls playsInline preload="metadata" src={h.video_url} className="aspect-video w-full rounded-md bg-black" />
            <div className="flex items-center gap-2 text-sm">
              <span className="min-w-0 flex-1 truncate"><b>{h.target_label}</b> <span className="text-muted-foreground">· {t("{count} clips", { count: h.clip_count })} · {length(h.duration_ms)} · {h.source === "phone" ? t("From Phone") : t("From Cloud")}</span></span>
              <Button asChild size="sm" variant="outline" className="whitespace-nowrap"><a href={h.download_url}><Download className="size-4" />{t("Download")}</a></Button>
            </div>
          </div>)}</div>}
    </CardContent>
    {picking && <ScoreDialog title={t("Create Highlight")} description={t("Pick a team for its scoring plays, or a player for their plays.")} onDismiss={() => setPicking(false)}>
      <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto">
        <div className="grid grid-cols-2 gap-2">
          {[away, home].map(team => <Button key={team.id} className="h-12 whitespace-nowrap" onClick={() => cut(`team:${team.id}`, team.label)}>{t("{team} Scoring", { team: team.label })}</Button>)}
        </div>
        {[away, home].map(team => { const roster = withPlays(team.id); return roster.length > 0 && <div key={team.id} className="flex flex-col gap-2">
          <p className="text-sm font-medium text-muted-foreground">{team.label}</p>
          <PlayerGrid players={roster} onPlayer={p => cut(`player:${p.id}`, playerLabel(p))} />
        </div>; })}
      </div>
    </ScoreDialog>}
  </Card>;
}
