"use client";

import { type ReactNode, useEffect, useState } from "react";
import { X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { Player, StatEvent } from "@/lib/types";
import { joinName, splitName } from "@/lib/player-name";
import { newPlayer, playerGridSlots, playerLabel, rosterOrder } from "@/lib/scoring";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { useI18n } from "@/lib/i18n";

/**
 * Shared popup frame for the scoring flows: the same gap to all four screen edges, the title on
 * the left, every action (Previous / Cancel / Confirm) on the right, and content that scrolls
 * inside the frame. Without explicit actions a top-right × stands in for Cancel.
 */
export function ScoreDialog({ title, description, actions, onDismiss, compact = false, children }: {
  title: string; description?: ReactNode; actions?: ReactNode; onDismiss: () => void; compact?: boolean; children: ReactNode;
}) {
  const { t } = useI18n();
  return <Dialog open onOpenChange={(open) => { if (!open) onDismiss(); }}>
    <DialogContent className={compact
      ? "flex max-h-[calc(100vh-2.5rem)] w-[calc(100%-2.5rem)] max-w-3xl flex-col gap-3 overflow-hidden p-5"
      : "inset-5 left-5 top-5 flex h-auto w-auto max-w-none translate-x-0 translate-y-0 flex-col gap-3 overflow-hidden p-5"}>
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <DialogTitle className="text-lg font-semibold leading-tight">{title}</DialogTitle>
          <DialogDescription className="text-sm text-muted-foreground">{description ?? ""}</DialogDescription>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {actions ?? <Button variant="ghost" size="icon" aria-label={t("Cancel")} onClick={onDismiss}><X className="size-4" /></Button>}
        </div>
      </div>
      {children}
    </DialogContent>
  </Dialog>;
}

/** One player button: jersey badge plus the name; number-only players show just the badge. */
function PlayerButton({ player, highlighted = false, onClick }: { player: Player; highlighted?: boolean; onClick: () => void }) {
  const named = Boolean(player.name.trim());
  return <Button variant="outline" onClick={onClick} aria-label={playerLabel(player)} className={`h-12 w-full min-w-0 justify-start gap-2 px-2 ${named ? "" : "justify-center"} ${highlighted ? "border-2 border-orange-500 bg-orange-100 hover:bg-orange-200" : ""}`}>
    <span className="flex size-8 shrink-0 items-center justify-center rounded-full bg-orange-600 text-sm font-bold text-white">{player.number.trim() || "--"}</span>
    {named && <span className="min-w-0 flex-1 truncate text-left text-sm">{player.name}</span>}
  </Button>;
}

/** 6 named players per row; number-only players pair up so 12 fit on the same columns. */
export function PlayerGrid({ players, leading, trailing, highlighted, onPlayer }: {
  players: Player[]; leading?: ReactNode; trailing?: ReactNode; highlighted?: Set<string>; onPlayer: (player: Player) => void;
}) {
  return <div className="grid grid-cols-6 gap-2">
    {leading}
    {playerGridSlots(rosterOrder(players)).map((slot) => slot.length === 1 && slot[0].name.trim()
      ? <PlayerButton key={slot[0].id} player={slot[0]} highlighted={highlighted?.has(slot[0].id)} onClick={() => onPlayer(slot[0])} />
      : <div key={slot[0].id} className="grid grid-cols-2 gap-2">{slot.map((player) => <PlayerButton key={player.id} player={player} highlighted={highlighted?.has(player.id)} onClick={() => onPlayer(player)} />)}</div>)}
    {trailing}
  </div>;
}

const gridCell = "h-12 w-full min-w-0 px-2";

/**
 * Jersey-number pad: nothing but the 0-99 grid, ten numbers per line. Numbers already on the
 * roster are highlighted; tapping a free number creates that player, tapping a highlighted one
 * removes the player again unless they already have recorded stats.
 */
function NumberPad({ roster, notice, onNumber }: { roster: Player[]; notice: string; onNumber: (number: number, existing: Player | undefined) => void }) {
  const byNumber = new Map<number, Player>();
  for (const player of roster) {
    const number = Number.parseInt(player.number.trim(), 10);
    if (Number.isInteger(number) && !byNumber.has(number)) byNumber.set(number, player);
  }
  return <div className="flex min-h-0 flex-1 flex-col gap-1">
    {notice && <p className="text-sm text-destructive">{notice}</p>}
    <div className="grid min-h-0 flex-1 grid-cols-10 grid-rows-10 gap-1">
      {Array.from({ length: 100 }, (_, number) => {
        const existing = byNumber.get(number);
        return <button key={number} type="button" onClick={() => onNumber(number, existing)} className={`min-h-9 rounded-md text-base font-semibold transition-colors ${existing ? "bg-orange-600 text-white hover:bg-orange-700" : "bg-muted text-foreground hover:bg-muted/70"}`}>{number}</button>;
      })}
    </div>
  </div>;
}

/** Number / First Name / Last Name / Add: the "Other Player" row at the bottom of the pickers. */
function NewPlayerRow({ label, onAdd }: { label: string; onAdd: (name: string, number: string) => void }) {
  const { t } = useI18n();
  const [number, setNumber] = useState("");
  const [first, setFirst] = useState("");
  const [last, setLast] = useState("");
  const canAdd = Boolean(number.trim() || first.trim() || last.trim());
  const add = () => {
    if (!canAdd) return;
    onAdd(joinName(first, last), number.trim());
    setNumber(""); setFirst(""); setLast("");
  };
  return <div className="flex flex-wrap items-center gap-2 border-t pt-3">
    <span className="text-sm font-semibold text-muted-foreground">{label}</span>
    <Input value={number} onChange={(event) => setNumber(event.target.value.replace(/\D/g, "").slice(0, 3))} placeholder={t("Number")} inputMode="numeric" className="w-24" />
    <Input value={first} onChange={(event) => setFirst(event.target.value.slice(0, 24))} placeholder={t("First Name")} className="w-40 flex-1" onKeyDown={(event) => { if (event.key === "Enter") add(); }} />
    <Input value={last} onChange={(event) => setLast(event.target.value.slice(0, 24))} placeholder={t("Last Name")} className="w-40 flex-1" onKeyDown={(event) => { if (event.key === "Enter") add(); }} />
    <Button variant="outline" disabled={!canAdd} onClick={add}>{t("Add")}</Button>
  </div>;
}

export type RosterActions = {
  /** Every player in the snapshot, so new ids stay unique across teams. */
  allPlayers: Player[];
  playerHasEvents: (playerId: string) => boolean;
  addPlayer: (player: Player) => void;
  removePlayer: (playerId: string) => void;
};

/**
 * "Who scored?" and friends. Picking a player is the last thing the user has to say, so the tap
 * records it; there is no Save. "Assign later" (or "No assist") comes first, "Choose number" last.
 */
export function PlayerChoiceDialog({ teamId, title, context, players, showNone, noneLabel = "No assist", highlighted, onPlayer, onNone, onDismiss, onBack, roster }: {
  teamId: string; title: string; context?: string; players: Player[]; showNone: boolean; noneLabel?: string; highlighted?: Set<string>;
  onPlayer: (player: Player) => void; onNone: () => void; onDismiss: () => void; onBack?: () => void; roster: RosterActions;
}) {
  const { t } = useI18n();
  const [pickingNumber, setPickingNumber] = useState(false);
  const [notice, setNotice] = useState("");
  // The number pad swaps in for this dialog entirely instead of opening on top of it; Cancel
  // returns to the player list.
  if (pickingNumber) return <ScoreDialog title={title} description={t("Tap a jersey number")} onDismiss={() => setPickingNumber(false)}>
    <NumberPad roster={players} notice={notice} onNumber={(number, existing) => {
      // A new number is the final player-selection step, so it records the play straight away.
      if (!existing) { setPickingNumber(false); onPlayer(newPlayer(roster.allPlayers, teamId, "", String(number))); }
      else if (roster.playerHasEvents(existing.id)) setNotice(t("#{number} already has recorded stats", { number }));
      else { setNotice(""); roster.removePlayer(existing.id); }
    }} />
  </ScoreDialog>;
  return <ScoreDialog title={title} description={context} onDismiss={onDismiss}
    actions={<>{onBack && <Button variant="outline" onClick={onBack}>{t("Previous")}</Button>}<Button variant="outline" onClick={onDismiss}>{t("Cancel")}</Button></>}>
    <div className="min-h-0 flex-1 overflow-y-auto">
      <PlayerGrid players={players} highlighted={highlighted} onPlayer={onPlayer}
        leading={showNone && <Button variant="outline" onClick={onNone} className={`${gridCell} text-muted-foreground`}>{t(noneLabel)}</Button>}
        trailing={<Button variant="outline" onClick={() => { setNotice(""); setPickingNumber(true); }} className={`${gridCell} text-orange-600`}>{t("Choose number")}</Button>} />
    </div>
    <NewPlayerRow label={t("Other Player")} onAdd={(name, number) => onPlayer(newPlayer(roster.allPlayers, teamId, name, number))} />
  </ScoreDialog>;
}

/**
 * Starting lineup and substitution share one toggle list: the on-court players arrive selected,
 * the user reshuffles freely (five at most), and Confirm/Save hands back the new selection.
 */
export function LineupDialog({ teamId, players, initial, onConfirm, onDismiss, roster, title = "Set Starting Lineup", hint = "Tap players to switch starters and substitutes", selectedLabel = "Starter", unselectedLabel = "Substitute", confirmLabel = "Confirm" }: {
  teamId: string; players: Player[]; initial: Set<string>; onConfirm: (selected: Set<string>) => void; onDismiss: () => void; roster: RosterActions;
  title?: string; hint?: string; selectedLabel?: string; unselectedLabel?: string; confirmLabel?: string;
}) {
  const { t } = useI18n();
  const [selected, setSelected] = useState(() => new Set(initial));
  // A sixth pick is allowed so the user can tap the new five first and drop the old ones after,
  // instead of a silent no-op tap; the count turns red and Confirm waits until five or fewer remain.
  const toggle = (id: string) => setSelected((current) => {
    const next = new Set(current);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    return next;
  });
  const tooMany = selected.size > 5;
  return <ScoreDialog title={t(title)} description={`${t(hint)} · ${t("{count}/5 selected", { count: selected.size })}${tooMany ? ` · ${t("Remove {count} to continue", { count: selected.size - 5 })}` : ""}`} onDismiss={onDismiss}
    actions={<><Button variant="outline" onClick={onDismiss}>{t("Cancel")}</Button><Button variant="outline" disabled={selected.size === 0} onClick={() => setSelected(new Set())}>{t("Clear")}</Button><Button disabled={selected.size === 0 || tooMany} onClick={() => onConfirm(selected)}>{t(confirmLabel)}</Button></>}>
    <div className="min-h-0 flex-1 overflow-y-auto">
      {tooMany && <p className="mb-2 text-sm font-medium text-destructive">{t("{count} players selected. Tap {extra} of them to move them off the floor.", { count: selected.size, extra: selected.size - 5 })}</p>}
      {players.length === 0
        ? <p className="py-10 text-center text-sm text-muted-foreground">{t("This team has no players yet")}</p>
        : <div className="grid grid-cols-6 gap-2">
          {rosterOrder(players).map((player) => {
            const on = selected.has(player.id);
            return <button key={player.id} type="button" onClick={() => toggle(player.id)} className={`flex h-14 min-w-0 flex-col justify-center rounded-md border px-3 text-left transition-colors ${on ? (tooMany ? "border-destructive bg-orange-100" : "border-orange-400 bg-orange-100") : "bg-muted/60 hover:bg-muted"}`}>
              <span className="truncate text-sm font-semibold">{playerLabel(player)}</span>
              <span className={`text-xs ${on ? "text-orange-800" : "text-muted-foreground"}`}>{on ? t(selectedLabel) : t(unselectedLabel)}</span>
            </button>;
          })}
        </div>}
    </div>
    <NewPlayerRow label={t("New Player")} onAdd={(name, number) => {
      const player = newPlayer(roster.allPlayers, teamId, name, number);
      roster.addPlayer(player);
      setSelected((current) => new Set([...current, player.id]));
    }} />
  </ScoreDialog>;
}

/** Rebound after a miss: one team at a time behind a tab, "No rebound" first, the number pad last. */
export function ReboundDialog({ homeTeamId, awayTeamId, homeName, awayName, shootingTeamId, players, onPlayer, onNone, onDismiss, roster }: {
  homeTeamId: string; awayTeamId: string; homeName: string; awayName: string; shootingTeamId: string; players: Player[];
  onPlayer: (player: Player) => void; onNone: () => void; onDismiss: () => void; roster: RosterActions;
}) {
  const { t } = useI18n();
  const [teamId, setTeamId] = useState(shootingTeamId);
  const [pickingNumber, setPickingNumber] = useState(false);
  const [notice, setNotice] = useState("");
  const teamPlayers = players.filter((player) => player.team_id === teamId);
  if (pickingNumber) return <ScoreDialog title={t("Rebound")} description={t("Tap a jersey number")} onDismiss={() => setPickingNumber(false)}>
    <NumberPad roster={teamPlayers} notice={notice} onNumber={(number, existing) => {
      if (!existing) { setPickingNumber(false); onPlayer(newPlayer(roster.allPlayers, teamId, "", String(number))); }
      else if (roster.playerHasEvents(existing.id)) setNotice(t("#{number} already has recorded stats", { number }));
      else { setNotice(""); roster.removePlayer(existing.id); }
    }} />
  </ScoreDialog>;
  return <ScoreDialog title={t("Rebound")} description={t("Who took the rebound?")} onDismiss={onDismiss}
    actions={<Button variant="outline" onClick={onDismiss}>{t("Cancel")}</Button>}>
    <div className="grid grid-cols-2 gap-2" role="tablist">
      {[[homeTeamId, homeName], [awayTeamId, awayName]].map(([id, name]) => <button key={id} type="button" role="tab" aria-selected={teamId === id} onClick={() => setTeamId(id)} className={`truncate rounded-md border-b-2 px-2 py-2 text-sm font-semibold ${teamId === id ? "border-orange-500 text-orange-700" : "border-transparent text-muted-foreground hover:text-foreground"}`}>{name} · {shootingTeamId === id ? t("Offensive rebound") : t("Defensive rebound")}</button>)}
    </div>
    <div className="min-h-0 flex-1 overflow-y-auto">
      <PlayerGrid players={teamPlayers} onPlayer={onPlayer}
        leading={<Button variant="outline" onClick={onNone} className={`${gridCell} text-muted-foreground`}>{t("No rebound")}</Button>}
        trailing={<Button variant="outline" onClick={() => { setNotice(""); setPickingNumber(true); }} className={`${gridCell} text-orange-600`}>{t("Choose number")}</Button>} />
    </div>
    <NewPlayerRow label={t("New Player")} onAdd={(name, number) => roster.addPlayer(newPlayer(roster.allPlayers, teamId, name, number))} />
  </ScoreDialog>;
}

export type FreeThrowFlow = { teamId: string; player: Player | null; playerSkipped: boolean; format: "" | "1+1"; total: number; results: (boolean | null)[] };

export const startFreeThrow = (teamId: string): FreeThrowFlow => ({ teamId, player: null, playerSkipped: false, format: "", total: 2, results: [] });

/**
 * Free-throw trip: pick the format, then record each attempt. The trip saves itself as soon as the
 * last attempt is recorded (a missed last shot hands off to the rebound question).
 */
export function FreeThrowDialog({ flow, onUpdate, onSave, onDismiss, onBack }: {
  flow: FreeThrowFlow; onUpdate: (flow: FreeThrowFlow) => void; onSave: (results: boolean[]) => void; onDismiss: () => void; onBack?: () => void;
}) {
  const { t } = useI18n();
  const oneAndOne = flow.format === "1+1";
  // 1+1: the second shot only exists once the first one is made.
  const shots = oneAndOne ? (flow.results[0] === true ? 2 : 1) : flow.total;
  const shooterChosen = flow.player !== null || flow.playerSkipped;
  const complete = shooterChosen && flow.results.length >= shots && Array.from({ length: shots }, (_, index) => flow.results[index]).every((result) => result !== null && result !== undefined);
  const recorded = flow.results.slice(0, shots).filter((result): result is boolean => result !== null);
  const record = (index: number, made: boolean) => {
    const next = [...flow.results];
    while (next.length <= index) next.push(null);
    next[index] = made;
    // A missed first shot in a 1+1 ends the trip; drop anything recorded for the bonus shot.
    onUpdate({ ...flow, results: oneAndOne && index === 0 && !made ? next.slice(0, 1) : next });
  };
  useEffect(() => { if (complete) onSave(recorded); }, [complete]); // eslint-disable-line react-hooks/exhaustive-deps
  const formats: { label: string; format: "" | "1+1"; count: number }[] = [
    { label: "1 FT", format: "", count: 1 }, { label: "2 FTs", format: "", count: 2 }, { label: "3 FTs", format: "", count: 3 }, { label: "1+1", format: "1+1", count: 2 },
  ];
  return <ScoreDialog compact title={flow.player ? playerLabel(flow.player) : flow.playerSkipped ? t("Shooter: assign later") : t("Select shooter")}
    description={shooterChosen ? (oneAndOne ? t("Shooting foul · 1+1 bonus") : t("Shooting foul · {count} free throws", { count: flow.total })) : undefined} onDismiss={onDismiss}
    actions={<>{onBack && <Button variant="outline" onClick={onBack}>{t("Previous")}</Button>}<Button variant="outline" onClick={onDismiss}>{t("Cancel")}</Button><Button disabled={!complete} onClick={() => onSave(recorded)}>{t("Next")}</Button></>}>
    <p className="text-sm text-muted-foreground">{t("Number of free throws")}</p>
    <div className="grid grid-cols-4 gap-2">
      {formats.map(({ label, format, count }) => {
        const active = flow.format === format && (format === "1+1" || flow.total === count);
        return <Button key={label} variant={active ? "default" : "secondary"} className={active ? "bg-orange-600 text-white hover:bg-orange-700" : ""} onClick={() => onUpdate({ ...flow, format, total: count, results: [] })}>{t(label)}</Button>;
      })}
    </div>
    <div className="grid grid-cols-3 gap-3">
      {Array.from({ length: shots }, (_, index) => {
        const result = flow.results[index] ?? null;
        return <div key={index} className="flex flex-col gap-1.5">
          <span className="text-sm font-semibold">{oneAndOne && index === 1 ? t("Bonus FT") : t("FT {n}", { n: index + 1 })}</span>
          <Button variant="secondary" className={result === false ? "bg-red-600 text-white hover:bg-red-700" : ""} onClick={() => record(index, false)}>{t("Miss")}</Button>
          <Button variant="secondary" className={result === true ? "bg-orange-600 text-white hover:bg-orange-700" : ""} onClick={() => record(index, true)}>{t("Made +1")}</Button>
        </div>;
      })}
    </div>
    {oneAndOne && flow.results[0] === false && <p className="text-sm text-muted-foreground">{t("Missed the first shot — the 1+1 is over")}</p>}
    <p className="text-sm">{t("Points from free throws")} <b>{flow.results.slice(0, shots).filter((result) => result === true).length}</b></p>
  </ScoreDialog>;
}

/**
 * The Players popup of a team panel. Numbers mode is the fast path during a game (tap a number to
 * add or remove a player); Names mode fixes up numbers and names. Every edit is staged here, so
 * Cancel leaves the roster exactly as it was opened and Done writes it once.
 */
export function RosterDialog({ teamId, teamName, players, onSave, onDismiss, roster }: {
  teamId: string; teamName: string; players: Player[]; onSave: (players: Player[], removedIds: string[]) => void; onDismiss: () => void; roster: RosterActions;
}) {
  const { t } = useI18n();
  const [draft, setDraft] = useState<Player[]>(() => rosterOrder(players));
  const [removed, setRemoved] = useState<string[]>([]);
  const [nameMode, setNameMode] = useState(false);
  const [notice, setNotice] = useState("");
  const [form, setForm] = useState({ number: "", first: "", last: "" });
  const allForIds = [...roster.allPlayers, ...draft];
  const remove = (player: Player) => {
    if (roster.playerHasEvents(player.id)) return setNotice(t("#{number} already has recorded stats", { number: player.number }));
    setNotice("");
    setDraft((current) => current.filter((row) => row.id !== player.id));
    if (players.some((row) => row.id === player.id)) setRemoved((current) => [...current, player.id]);
  };
  const update = (id: string, patch: Partial<Player>) => setDraft((current) => current.map((row) => row.id === id ? { ...row, ...patch } : row));
  const canAdd = Boolean(form.number.trim() || form.first.trim() || form.last.trim());
  return <ScoreDialog title={t("Players · {team}", { team: teamName })} description={nameMode ? t("Edit numbers and names, or add a new player") : t("Tap a number to add or remove a player")} onDismiss={onDismiss}
    actions={<>
      <div className="flex gap-1">{[[false, "Numbers"], [true, "Names"]].map(([mode, label]) => <Button key={String(label)} size="sm" variant={nameMode === mode ? "default" : "secondary"} className={nameMode === mode ? "bg-orange-600 text-white hover:bg-orange-700" : ""} onClick={() => setNameMode(Boolean(mode))}>{t(String(label))}</Button>)}</div>
      <Button variant="outline" onClick={onDismiss}>{t("Cancel")}</Button>
      <Button onClick={() => onSave(draft, removed)}>{t("Done")}</Button>
    </>}>
    {nameMode
      ? <div className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto">
        {notice && <p className="text-sm text-destructive">{notice}</p>}
        {draft.length === 0 && <p className="py-6 text-center text-sm text-muted-foreground">{t("This team has no players yet")}</p>}
        {draft.map((player) => {
          const name = splitName(player.name);
          return <div key={player.id} className="flex items-center gap-2">
            <Input value={player.number} onChange={(event) => update(player.id, { number: event.target.value.replace(/\D/g, "").slice(0, 3) })} placeholder={t("Number")} inputMode="numeric" className="w-24" />
            <Input value={name.first} onChange={(event) => update(player.id, { name: joinName(event.target.value, name.last) })} placeholder={t("First Name")} className="flex-1" />
            <Input value={name.last} onChange={(event) => update(player.id, { name: joinName(name.first, event.target.value) })} placeholder={t("Last Name")} className="flex-1" />
            <Button variant="outline" onClick={() => remove(player)}>{t("Remove")}</Button>
          </div>;
        })}
        <div className="flex items-center gap-2 border-t pt-3">
          <span className="text-sm font-semibold text-muted-foreground">{t("New Player")}</span>
          <Input value={form.number} onChange={(event) => setForm({ ...form, number: event.target.value.replace(/\D/g, "").slice(0, 3) })} placeholder={t("Number")} inputMode="numeric" className="w-24" />
          <Input value={form.first} onChange={(event) => setForm({ ...form, first: event.target.value.slice(0, 24) })} placeholder={t("First Name")} className="flex-1" />
          <Input value={form.last} onChange={(event) => setForm({ ...form, last: event.target.value.slice(0, 24) })} placeholder={t("Last Name")} className="flex-1" />
          <Button variant="outline" disabled={!canAdd} onClick={() => { setDraft((current) => [...current, newPlayer(allForIds, teamId, joinName(form.first, form.last), form.number)]); setForm({ number: "", first: "", last: "" }); }}>{t("Add")}</Button>
        </div>
      </div>
      : <NumberPad roster={draft} notice={notice} onNumber={(number, existing) => {
        if (existing) remove(existing);
        else { setNotice(""); setDraft((current) => [...current, newPlayer(allForIds, teamId, "", String(number))]); }
      }} />}
  </ScoreDialog>;
}

/** "Period 3" inside the scheduled periods, "OT 1" past them. */
type Translate = (key: string, vars?: Record<string, string | number>) => string;
export const periodLabel = (period: number, periodCount: number, t: Translate) => period > periodCount ? t("OT {n}", { n: period - periodCount }) : t("Period {n}", { n: period });

/**
 * The Period/Time editor of the recorder: period, minutes and seconds pickers. Picking another
 * period resets the time to a full period; picking the current period restores the live clock.
 * Save is only allowed while the time fits inside one period.
 */
export function ClockEditorDialog({ initialMs, maxMs, initialPeriod, periodCount, defaultShift, onDismiss, onConfirm }: {
  initialMs: number; maxMs: number; initialPeriod: number; periodCount: number; defaultShift: boolean; onDismiss: () => void; onConfirm: (period: number, ms: number, shiftPlays: boolean) => void;
}) {
  const { t } = useI18n();
  const [period, setPeriod] = useState(initialPeriod);
  // Shifting the plays at or after the new time is for a live clock that kept running while the real
  // one stood still. Jumping back into a finished game to add a missed substitution must leave every
  // recorded play where it is, so the box is off by default once the clock is stopped.
  const [shiftPlays, setShiftPlays] = useState(defaultShift);
  const [minutes, setMinutes] = useState(Math.floor(initialMs / 60_000));
  const [seconds, setSeconds] = useState(Math.floor((initialMs % 60_000) / 1000));
  const maxMinutes = Math.floor(maxMs / 60_000);
  const totalMs = minutes * 60_000 + seconds * 1000;
  const valid = totalMs <= maxMs;
  // One extra period is always offered so overtime can be started from the last scheduled period.
  const periods = Array.from({ length: Math.max(periodCount, initialPeriod + 1) }, (_, index) => index + 1);
  const choosePeriod = (next: number) => {
    setPeriod(next);
    const ms = next === initialPeriod ? initialMs : maxMs;
    setMinutes(Math.floor(ms / 60_000));
    setSeconds(Math.floor((ms % 60_000) / 1000));
  };
  return <ScoreDialog compact title={t("Adjust Period/Time")} description={valid ? (shiftPlays ? t("Plays recorded after the new time move with the clock") : t("Recorded plays stay where they are")) : t("Time cannot exceed {time}", { time: formatClockLimit(maxMs) })} onDismiss={onDismiss}
    actions={<><Button variant="outline" onClick={onDismiss}>{t("Cancel")}</Button><Button disabled={!valid} onClick={() => onConfirm(period, totalMs, shiftPlays)}>{t("Save")}</Button></>}>
    <div className="flex flex-wrap gap-3">
      <ClockPicker id="clock-period" label={t("Period")} value={period} options={periods} render={(option) => periodLabel(option, periodCount, t)} onChange={choosePeriod} />
      <ClockPicker id="clock-minutes" label={t("Minutes")} value={minutes} options={Array.from({ length: maxMinutes + 1 }, (_, index) => index)} render={String} onChange={setMinutes} />
      <ClockPicker id="clock-seconds" label={t("Seconds")} value={seconds} options={Array.from({ length: 60 }, (_, index) => index)} render={(option) => String(option).padStart(2, "0")} onChange={setSeconds} />
    </div>
    <label htmlFor="clock-shift" className="mt-3 flex cursor-pointer items-center gap-2 text-sm">
      <Checkbox id="clock-shift" checked={shiftPlays} onCheckedChange={(checked) => setShiftPlays(checked === true)} />
      {t("Shift recorded plays with the clock")}
    </label>
  </ScoreDialog>;
}

/** "12:00" for a duration in milliseconds, used in the "cannot exceed" notices. */
const formatClockLimit = (ms: number) => `${Math.floor(ms / 60_000)}:${String(Math.floor((ms % 60_000) / 1000)).padStart(2, "0")}`;

/** One labelled select of the period / minutes / seconds pickers. */
function ClockPicker({ id, label, value, options, render, onChange }: {
  id: string; label: string; value: number; options: number[]; render: (option: number) => string; onChange: (value: number) => void;
}) {
  return <div className="flex min-w-24 flex-1 flex-col gap-1.5">
    <label htmlFor={id} className="text-sm font-medium">{label}</label>
    <Select value={String(value)} onValueChange={(next) => onChange(Number(next))}>
      <SelectTrigger id={id}><SelectValue /></SelectTrigger>
      <SelectContent>{options.map((option) => <SelectItem key={option} value={String(option)}>{render(option)}</SelectItem>)}</SelectContent>
    </Select>
  </div>;
}

export type PlayEdit = { player: Player | null; period: number; ms: number };

/**
 * Edit play, mirroring the Android EditPlayPanel: the period and clock pickers first, then the
 * player grid with "Assign it later" leading and an add-player row below. Delete, Cancel and Save
 * sit in the header. A player added here is only written to the roster once the edit is saved.
 */
export function EditPlayDialog({ event, label, players, allPlayers, periodDurationMs, periodCount, onSave, onDelete, onDismiss }: {
  event: StatEvent; label: string; players: Player[]; allPlayers: Player[]; periodDurationMs: number; periodCount: number;
  onSave: (edit: PlayEdit) => void; onDelete: () => void; onDismiss: () => void;
}) {
  const { t } = useI18n();
  const [localRoster, setLocalRoster] = useState(players);
  const [playerId, setPlayerId] = useState<string | null>(event.player_id);
  const [period, setPeriod] = useState(event.period);
  const [minutes, setMinutes] = useState(Math.floor(event.game_clock_ms / 60_000));
  const [seconds, setSeconds] = useState(Math.floor((event.game_clock_ms % 60_000) / 1000));
  const [confirmDelete, setConfirmDelete] = useState(false);
  const maxMinutes = Math.max(1, Math.floor(periodDurationMs / 60_000));
  const totalMs = minutes * 60_000 + seconds * 1000;
  const valid = totalMs <= periodDurationMs;
  // Overtime periods already recorded stay selectable.
  const periods = Array.from({ length: Math.max(periodCount, event.period) }, (_, index) => index + 1);
  // Score adjustments belong to the team, not a player.
  const hasPlayer = event.type !== "ADJ";
  const selected = playerId === null ? undefined : new Set([playerId]);
  const save = () => onSave({ player: hasPlayer ? localRoster.find((player) => player.id === playerId) ?? null : null, period, ms: totalMs });
  return <ScoreDialog title={t("Edit play")} description={valid ? `${label} · ${periodLabel(event.period, periodCount, t)} ${formatClockLimit(event.game_clock_ms)}` : t("Time cannot exceed {time}", { time: formatClockLimit(periodDurationMs) })} onDismiss={onDismiss}
    actions={<>
      <Button variant="outline" className="text-destructive" onClick={() => setConfirmDelete(true)}>{t("Delete")}</Button>
      <Button variant="outline" onClick={onDismiss}>{t("Cancel")}</Button>
      <Button disabled={!valid} onClick={save}>{t("Save")}</Button>
    </>}>
    <div className="flex flex-wrap items-end gap-3">
      <div className="flex min-w-40 flex-1 flex-col"><span className="text-base font-semibold">{label}</span><span className="text-xs text-muted-foreground">{t("Game clock remaining")}</span></div>
      <ClockPicker id="play-period" label={t("Period")} value={period} options={periods} render={(option) => periodLabel(option, periodCount, t)} onChange={setPeriod} />
      <ClockPicker id="play-minutes" label={t("Minutes")} value={minutes} options={Array.from({ length: maxMinutes + 1 }, (_, index) => index)} render={String} onChange={setMinutes} />
      <ClockPicker id="play-seconds" label={t("Seconds")} value={seconds} options={Array.from({ length: 60 }, (_, index) => index)} render={(option) => String(option).padStart(2, "0")} onChange={setSeconds} />
    </div>
    {hasPlayer && <>
      <p className="text-sm font-semibold">{t("Player")}</p>
      <div className="min-h-0 flex-1 overflow-y-auto">
        <PlayerGrid players={localRoster} highlighted={selected} onPlayer={(player) => setPlayerId(player.id)}
          leading={<Button variant="outline" onClick={() => setPlayerId(null)} aria-pressed={playerId === null} className={`${gridCell} text-muted-foreground ${playerId === null ? "border-2 border-orange-500 bg-orange-100 hover:bg-orange-200" : ""}`}>{t("Assign it later")}</Button>} />
      </div>
      <NewPlayerRow label={t("New Player")} onAdd={(name, number) => {
        const player = newPlayer([...allPlayers, ...localRoster], event.team_id, name, number);
        setLocalRoster((current) => [...current, player]);
        setPlayerId(player.id);
      }} />
    </>}
    <ConfirmDialog open={confirmDelete} onOpenChange={setConfirmDelete} title={t("Delete play?")} description={t("This removes the play and updates the score if it was a made shot.")} confirmLabel={t("Delete")} onConfirm={() => { setConfirmDelete(false); onDelete(); }} />
  </ScoreDialog>;
}
