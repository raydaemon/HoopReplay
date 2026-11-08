"use client";

import { Button } from "@/components/ui/button";
import { useI18n } from "@/lib/i18n";

const statButtons = [
  { type: "REB", label: "Rebound" },
  { type: "AST", label: "Assist" },
  { type: "STL", label: "Steal" },
  { type: "BLK", label: "Block" },
] as const;

/** One team's column of the scoring card: lineup tools, the score with ±1, and every play button. */
export function ScoringTeamPanel({ teamName, side, score, lineupCount, onLineup, onSubstitution, onPlayers, onAdjust, onPoints, onMiss, onStat, onFreeThrow, onFoul }: {
  teamName: string; side: "Away" | "Home"; score: number; lineupCount: number;
  onLineup: () => void; onSubstitution: () => void; onPlayers: () => void;
  onAdjust: (delta: number) => void; onPoints: (points: number) => void; onMiss: (points: number) => void; onStat: (type: string) => void; onFreeThrow: () => void; onFoul: () => void;
}) {
  const { t } = useI18n();
  return <section aria-label={t("{team} ({side})", { team: teamName, side: t(side) })} className="flex flex-col gap-2 rounded-xl border bg-muted/40 p-3 sm:p-4">
    <h3 className="text-center text-sm font-semibold">{teamName} <span className="font-normal text-muted-foreground">({t(side)})</span></h3>
    <div className="flex items-center justify-center gap-1.5">
      <Button variant="outline" size="sm" onClick={onLineup} className={`h-7 px-2 text-xs ${lineupCount === 5 ? "" : "border-amber-500 text-amber-600 hover:text-amber-700"}`}>
        {lineupCount === 5 ? t("Lineup 5") : t("⚠ Lineup {count}/5", { count: lineupCount })}
      </Button>
      <Button variant="outline" size="sm" onClick={onSubstitution} className="h-7 px-2 text-xs">{t("Sub")}</Button>
      <Button variant="outline" size="sm" onClick={onPlayers} className="h-7 px-2 text-xs">{t("Players")}</Button>
    </div>
    <div className="flex items-center justify-center gap-4 py-1">
      <Button variant="outline" onClick={() => onAdjust(-1)} className="h-7 w-10 px-0 text-xs">-1</Button>
      <span className="min-w-16 text-center text-5xl font-bold tabular-nums text-orange-600">{score}</span>
      <Button variant="outline" onClick={() => onAdjust(1)} className="h-7 w-10 px-0 text-xs">+1</Button>
    </div>
    <div className="grid grid-cols-2 gap-2">{[2, 3].map((points) => <Button key={points} onClick={() => onPoints(points)} className="h-11 bg-emerald-600 text-white hover:bg-emerald-700">+{points}</Button>)}</div>
    <div className="grid grid-cols-2 gap-2">{[2, 3].map((points) => <Button key={points} onClick={() => onMiss(points)} className="h-11 bg-red-600 text-white hover:bg-red-700">{t("Miss {points}", { points })}</Button>)}</div>
    <Button onClick={onFreeThrow} className="h-11 bg-orange-600 text-white hover:bg-orange-700">{t("Free Throw")}</Button>
    <div className="grid grid-cols-2 gap-2">{statButtons.map(({ type, label }) => <Button key={type} variant="outline" onClick={() => onStat(type)} className="h-10">{t(label)}</Button>)}</div>
    <div className="grid grid-cols-2 gap-2">
      <Button variant="outline" onClick={() => onStat("TOV")} className="h-10">{t("Turnover")}</Button>
      <Button variant="outline" onClick={onFoul} className="h-10">{t("Foul")}</Button>
    </div>
  </section>;
}
