"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Clock3, Pause, Play, RotateCcw, Square } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ScoringTeamPanel } from "@/components/scoring-team-panel";
import { ClockEditorDialog, type FreeThrowFlow, FreeThrowDialog, LineupDialog, PlayerChoiceDialog, ReboundDialog, RosterDialog, type RosterActions, periodLabel, startFreeThrow } from "@/components/score-dialogs";
import type { Game, Player, Snapshot, StatEvent } from "@/lib/types";
import { tombstones } from "@/lib/use-snapshot";
import { applyPlays, isScoringType, lineupOf, periodStarters, playerLabel, type PlayRequest } from "@/lib/scoring";
import { useI18n } from "@/lib/i18n";

type PlayerAction = { teamId: number; type: string; value: number; points: number; needsAssist: boolean; needsRebound: boolean };
type FoulFlow = { teamId: number; player: Player | null; playerSkipped: boolean };

const statNames: Record<string, string> = { REB: "Rebound", AST: "Assist", STL: "Steal", BLK: "Block", TOV: "Turnover" };

function formatClock(ms: number) {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(totalSeconds / 60)).padStart(2, "0")}:${String(totalSeconds % 60).padStart(2, "0")}`;
}

/**
 * The scoring card of the game page: the two team panels plus every entry flow behind their
 * buttons, mirroring the Android recorder — who scored, then the assist; a miss, then the rebound;
 * free-throw trips; foul committed / fouled; lineup and substitution as one toggle list.
 */
export function ScoreMode({ game: savedGame, data, events, mutate, paused = false }: {
  game: Game; data: Snapshot; events: StatEvent[]; mutate: (recipe: (draft: Snapshot) => Snapshot) => Snapshot;
  /** True while the page has another entry popup open (the play editor), which also freezes the clock. */
  paused?: boolean;
}) {
  const { t } = useI18n();
  // Older Android uploads can contain the complete event log while the game summary row still
  // has its initial score/clock. Prefer the event log for the live controls so a stale summary
  // cannot make a completed game look like 0:0 or Period 1 at the opening clock.
  const eventSnapshot = useMemo(() => {
    const active = events.filter((event) => !event.reverted && event.type !== "STARTER" && event.type !== "VIDEO");
    let homeScore = 0;
    let awayScore = 0;
    for (const event of active) {
      if (!isScoringType(event.type)) continue;
      if (event.team_id === savedGame.home_id) homeScore += event.value;
      if (event.team_id === savedGame.away_id) awayScore += event.value;
    }
    const latest = [...active].sort((a, b) => a.period - b.period || b.game_clock_ms - a.game_clock_ms || a.id - b.id).at(-1);
    return { homeScore, awayScore, latest };
  }, [events, savedGame.away_id, savedGame.home_id]);
  const effectiveSavedGame = useMemo<Game>(() => {
    const latest = eventSnapshot.latest;
    const period = latest && latest.period > savedGame.current_period ? latest.period : savedGame.current_period;
    const ms = latest && latest.period === period ? Math.min(savedGame.clock_remaining_ms, latest.game_clock_ms) : savedGame.clock_remaining_ms;
    const useSavedSummary = savedGame.status === "READY";
    return {
      ...savedGame,
      home_score: useSavedSummary ? savedGame.home_score : eventSnapshot.homeScore,
      away_score: useSavedSummary ? savedGame.away_score : eventSnapshot.awayScore,
      current_period: period,
      clock_remaining_ms: ms,
    };
  }, [eventSnapshot, savedGame]);
  // The game clock lives here while the page is open; the game row is only written when the clock
  // pauses, stops, is edited, or a play is recorded, plus a periodic checkpoint while running.
  const restoredClock = useMemo(() => {
    const lastPlay = [...events]
      .filter((event) => event.game_id === effectiveSavedGame.id && event.period === effectiveSavedGame.current_period && !event.reverted && event.type !== "STARTER" && event.type !== "VIDEO")
      .sort((a, b) => b.id - a.id)[0];
    return lastPlay ? Math.min(effectiveSavedGame.clock_remaining_ms, lastPlay.game_clock_ms) : effectiveSavedGame.clock_remaining_ms;
  }, [events, effectiveSavedGame]);
  const [localClock, setClock] = useState({ period: effectiveSavedGame.current_period, ms: restoredClock });
  const [recorder, setRecorder] = useState<"idle" | "running" | "paused">("idle");
  const [clockEditorOpen, setClockEditorOpen] = useState(false);
  // While nothing runs here the saved row is the clock, so another device's edits show up as they sync.
  const clock = useMemo(() => recorder === "idle" ? { period: effectiveSavedGame.current_period, ms: effectiveSavedGame.clock_remaining_ms } : localClock, [recorder, effectiveSavedGame, localClock]);
  const game = useMemo<Game>(() => ({ ...effectiveSavedGame, current_period: clock.period, clock_remaining_ms: clock.ms }), [effectiveSavedGame, clock]);
  const [pendingAction, setPendingAction] = useState<PlayerAction | null>(null);
  // The shooter is null when the user chose to assign the player later.
  const [madeShot, setMadeShot] = useState<{ action: PlayerAction; shooter: Player | null } | null>(null);
  const [missedShot, setMissedShot] = useState<{ action: PlayerAction; shooter: Player | null } | null>(null);
  const [freeThrow, setFreeThrow] = useState<FreeThrowFlow | null>(null);
  // A missed last free throw leaves the ball live, so the trip is only finished once the rebound
  // is assigned; the attempts are held here until then so they are written in play order.
  const [freeThrowRebound, setFreeThrowRebound] = useState<{ flow: FreeThrowFlow; results: boolean[] } | null>(null);
  const [foul, setFoul] = useState<FoulFlow | null>(null);
  const [substitutionTeam, setSubstitutionTeam] = useState<number | null>(null);
  const [starterTeam, setStarterTeam] = useState<number | null>(null);
  const [rosterTeam, setRosterTeam] = useState<number | null>(null);
  const [undoNotice, setUndoNotice] = useState("");
  // While any entry popup is open the clock freezes, exactly like the Android recorder.
  const dialogOpen = paused || pendingAction !== null || madeShot !== null || missedShot !== null || freeThrow !== null || freeThrowRebound !== null || foul !== null || substitutionTeam !== null || starterTeam !== null || rosterTeam !== null || clockEditorOpen;

  const withClock = (draft: Snapshot, period: number, ms: number): Snapshot => ({
    ...draft, games: draft.games.map((row) => row.id === savedGame.id ? { ...row, current_period: period, clock_remaining_ms: ms } : row),
  });
  const persistClock = (period: number, ms: number) => mutate((draft) => withClock(draft, period, ms));
  useEffect(() => {
    if (recorder === "idle" && effectiveSavedGame.clock_remaining_ms > restoredClock) persistClock(effectiveSavedGame.current_period, restoredClock);
  }, [recorder, effectiveSavedGame.clock_remaining_ms, effectiveSavedGame.current_period, restoredClock]);
  const latest = useRef({ clock, persistClock });
  useEffect(() => { latest.current = { clock, persistClock }; });

  // Score mode is often used while re-watching a recorded game, where the action plays back slower
  // than live, so the clock runs at half speed: 500 ms of game time per real second.
  useEffect(() => {
    if (recorder !== "running" || dialogOpen) return;
    const timer = window.setInterval(() => setClock((current) => {
      const ms = Math.max(0, current.ms - 500);
      if (ms === 0 && current.ms > 0) window.setTimeout(() => { setRecorder("idle"); persistClock(current.period, 0); }, 0);
      return { ...current, ms };
    }), 1000);
    return () => window.clearInterval(timer);
  }, [recorder, dialogOpen]);
  // A running clock is checkpointed to the game row every 30 s, and once more when the page goes away.
  useEffect(() => {
    if (recorder !== "running") return;
    const timer = window.setInterval(() => latest.current.persistClock(latest.current.clock.period, latest.current.clock.ms), 30_000);
    return () => window.clearInterval(timer);
  }, [recorder]);
  useEffect(() => () => { latest.current.persistClock(latest.current.clock.period, latest.current.clock.ms); }, []);

  const startOrPause = () => {
    if (recorder === "running") { setRecorder("paused"); persistClock(clock.period, clock.ms); }
    else { setClock(clock); setRecorder("running"); }
  };
  const stop = () => { setRecorder("idle"); persistClock(clock.period, clock.ms); };

  const teamName = (id: number) => data.teams.find((team) => team.id === id)?.name ?? t("Unknown");
  const teamPlayers = (teamId: number) => data.players.filter((player) => player.team_id === teamId);
  const lineups = useMemo(() => ({
    [game.home_id]: lineupOf(events, data.players.filter((player) => player.team_id === game.home_id), game.home_id, clock),
    [game.away_id]: lineupOf(events, data.players.filter((player) => player.team_id === game.away_id), game.away_id, clock),
  }), [events, data.players, game.home_id, game.away_id, clock]);

  const commit = (plays: PlayRequest[]) => { mutate((draft) => withClock(applyPlays(draft, game, plays), clock.period, clock.ms)); setUndoNotice(""); };
  /**
   * Period/Time save, mirroring the Android ClockEditorDialog: within the same period the plays at
   * ti <= t2 shift by (t2 - t1) capped at t2, but only when the user asked for it; moving forward
   * carries the on-court players into the new period with STARTER records; moving back only sets the
   * clock, so the user can jump to a moment and add the substitution that was missed there.
   */
  const applyClockEdit = (newPeriod: number, newMs: number, shiftPlays: boolean) => {
    mutate((draft) => {
      let next = draft;
      if (shiftPlays && newPeriod === clock.period && newMs !== clock.ms) {
        const delta = newMs - clock.ms;
        next = { ...next, events: next.events.map((event) => event.game_id === savedGame.id && event.period === clock.period && !event.reverted && event.game_clock_ms <= newMs
          ? { ...event, game_clock_ms: Math.min(Math.max(event.game_clock_ms + delta, 0), newMs) } : event) };
      }
      if (newPeriod > clock.period) {
        const existing = new Set(next.events.filter((event) => event.game_id === savedGame.id && !event.reverted && event.period === newPeriod && event.type === "STARTER").map((event) => event.player_id));
        const carried: PlayRequest[] = [savedGame.home_id, savedGame.away_id].flatMap((teamId) => [...(lineups[teamId] ?? [])].filter((id) => !existing.has(id))
          .map((id) => ({ teamId, player: data.players.find((player) => player.id === id) ?? null, type: "STARTER", value: 1 })));
        next = applyPlays(next, { ...game, current_period: newPeriod, clock_remaining_ms: newMs }, carried);
      }
      return withClock(next, newPeriod, newMs);
    });
    setClock({ period: newPeriod, ms: newMs });
    setClockEditorOpen(false);
  };
  const roster: RosterActions = {
    allPlayers: data.players,
    playerHasEvents: (playerId) => data.events.some((event) => event.player_id === playerId),
    addPlayer: (player) => mutate((draft) => ({ ...draft, players: [...draft.players, player] })),
    removePlayer: (playerId) => mutate((draft) => ({
      ...draft,
      players: draft.players.filter((row) => row.id !== playerId),
      events: draft.events.map((event) => event.player_id === playerId ? { ...event, player_id: null } : event),
      deletions: [...draft.deletions, ...tombstones("players", [playerId])],
    })),
  };
  const shotEvent = (action: PlayerAction, shooter: Player | null): PlayRequest => ({ teamId: action.teamId, player: shooter, type: action.type, value: action.value, points: action.points });
  const freeThrowEvents = (flow: FreeThrowFlow, results: boolean[]): PlayRequest[] =>
    results.map((made) => ({ teamId: flow.teamId, player: flow.player, type: made ? "FT_MADE" : "FT_MISS", value: 1, points: made ? 1 : 0 }));

  function undo() {
    const last = [...events].sort((a, b) => b.id - a.id)[0];
    if (!last) return setUndoNotice(t("Nothing to undo."));
    mutate((draft) => ({
      ...draft,
      events: draft.events.map((row) => row.id === last.id ? { ...row, reverted: 1 } : row),
      games: draft.games.map((row) => row.id === game.id && isScoringType(last.type) ? {
        ...row,
        home_score: Math.max(0, row.home_score - (last.team_id === row.home_id ? last.value : 0)),
        away_score: Math.max(0, row.away_score - (last.team_id === row.away_id ? last.value : 0)),
      } : row),
    }));
    setUndoNotice("");
  }

  const panels = [{ id: game.away_id, side: "Away" as const, score: game.away_score }, { id: game.home_id, side: "Home" as const, score: game.home_score }];
  return <Card className="border-orange-200">
    <CardHeader className="flex flex-wrap items-center gap-x-4 gap-y-2">
      <CardTitle>{t("Scoring mode")}</CardTitle>
      <div className="flex min-w-0 flex-wrap items-baseline gap-x-3 leading-tight">
        <span className="text-2xl font-bold tabular-nums">{clock.period > game.period_count ? periodLabel(clock.period, game.period_count, t) : t("Period {period}/{count}", { period: clock.period, count: game.period_count })} · {formatClock(clock.ms)}</span>
        <span className={`text-sm font-medium ${recorder === "running" ? "text-emerald-600" : "text-orange-600"}`}>{recorder === "running" ? t("Running") : recorder === "paused" ? t("Paused") : t("Ready")}</span>
      </div>
      <div className="ml-auto flex flex-wrap items-center gap-2">
        <Button className="whitespace-nowrap" onClick={startOrPause}>{recorder === "running" ? <><Pause className="size-4" />{t("Pause")}</> : recorder === "paused" ? <><Play className="size-4" />{t("Resume")}</> : <><Play className="size-4" />{t("Start")}</>}</Button>
        <Button variant="outline" className="whitespace-nowrap" disabled={recorder === "idle"} onClick={stop}><Square className="size-4" />{t("Stop")}</Button>
        <Button variant="outline" className="whitespace-nowrap" onClick={() => setClockEditorOpen(true)}><Clock3 className="size-4" />{t("Period/Time")}</Button>
      </div>
    </CardHeader>
    <CardContent className="flex flex-col gap-3">
      {clockEditorOpen && <ClockEditorDialog initialMs={clock.ms} maxMs={game.period_duration_ms} initialPeriod={clock.period} periodCount={game.period_count} defaultShift={recorder !== "idle" && savedGame.status !== "COMPLETED"} onDismiss={() => setClockEditorOpen(false)} onConfirm={applyClockEdit} />}
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        {panels.map((team) => <ScoringTeamPanel key={team.id} teamName={teamName(team.id)} side={team.side} score={team.score} lineupCount={lineups[team.id]?.size ?? 0}
          onLineup={() => setStarterTeam(team.id)}
          onSubstitution={() => setSubstitutionTeam(team.id)}
          onPlayers={() => setRosterTeam(team.id)}
          onAdjust={(delta) => { if (delta > 0 || team.score > 0) commit([{ teamId: team.id, player: null, type: "ADJ", value: delta, points: delta }]); }}
          onPoints={(points) => setPendingAction({ teamId: team.id, type: `PTS_${points}`, value: points, points, needsAssist: true, needsRebound: false })}
          onMiss={(points) => setPendingAction({ teamId: team.id, type: `MISS_${points}`, value: points, points: 0, needsAssist: false, needsRebound: true })}
          onFreeThrow={() => setFreeThrow(startFreeThrow(team.id))}
          onFoul={() => setFoul({ teamId: team.id, player: null, playerSkipped: false })}
          onStat={(type) => setPendingAction({ teamId: team.id, type, value: 1, points: 0, needsAssist: false, needsRebound: false })} />)}
      </div>
      <div className="flex flex-wrap items-center gap-2"><Button variant="secondary" onClick={undo}><RotateCcw className="size-4" />{t("Undo")}</Button>{undoNotice && <span className="text-sm text-muted-foreground">{undoNotice}</span>}</div>

      {starterTeam !== null && <LineupDialog key={`starters-${starterTeam}`} teamId={starterTeam} players={teamPlayers(starterTeam)} initial={new Set(periodStarters(events, starterTeam, game.current_period).length ? periodStarters(events, starterTeam, game.current_period) : lineups[starterTeam] ?? [])} roster={roster}
        onDismiss={() => setStarterTeam(null)}
        onConfirm={(selected) => {
          const byId = (id: number) => data.players.find((player) => player.id === id) ?? null;
          // The dialog edits this period's starters, not the floor at the current clock: a newly
          // picked player gets a STARTER at the top of the period, and a deselected starter simply
          // never started, so their STARTER is reverted instead of writing a Sub out at the current
          // clock (which would credit them minutes they never played). The floor carried in from
          // the previous period drops away on its own once the period has starters of its own.
          const already = periodStarters(events, starterTeam, game.current_period);
          const removed = new Set(already.filter((id) => !selected.has(id)));
          const plays: PlayRequest[] = [...selected].filter((id) => !already.includes(id)).map((id) => ({ teamId: starterTeam, player: byId(id), type: "STARTER", value: 1 }));
          if (plays.length || removed.size) {
            mutate((draft) => {
              const next = removed.size ? { ...draft, events: draft.events.map((event) => event.game_id === savedGame.id && event.team_id === starterTeam && event.period === game.current_period && event.type === "STARTER" && event.player_id !== null && removed.has(event.player_id) ? { ...event, reverted: 1 } : event) } : draft;
              return withClock(applyPlays(next, game, plays), clock.period, clock.ms);
            });
            setUndoNotice("");
          }
          setStarterTeam(null);
        }} />}

      {substitutionTeam !== null && <LineupDialog key={`sub-${substitutionTeam}`} teamId={substitutionTeam} players={teamPlayers(substitutionTeam)} initial={lineups[substitutionTeam] ?? new Set()} roster={roster}
        title="Substitution" hint="Tap players to change who is on the court" selectedLabel="On court" unselectedLabel="Bench" confirmLabel="Save"
        onDismiss={() => setSubstitutionTeam(null)}
        onConfirm={(selected) => {
          const current = lineups[substitutionTeam] ?? new Set<number>();
          const byId = (id: number) => data.players.find((player) => player.id === id) ?? null;
          const outs = [...current].filter((id) => !selected.has(id));
          const ins = [...selected].filter((id) => !current.has(id));
          // Written as out/in pairs so each pair stays adjacent for later time edits.
          const plays: PlayRequest[] = [];
          for (let index = 0; index < Math.max(outs.length, ins.length); index += 1) {
            if (outs[index] !== undefined) plays.push({ teamId: substitutionTeam, player: byId(outs[index]), type: "SUB_OUT", value: 1 });
            if (ins[index] !== undefined) plays.push({ teamId: substitutionTeam, player: byId(ins[index]), type: "SUB_IN", value: 1 });
          }
          if (plays.length) commit(plays);
          setSubstitutionTeam(null);
        }} />}

      {rosterTeam !== null && <RosterDialog key={`roster-${rosterTeam}`} teamId={rosterTeam} teamName={teamName(rosterTeam)} players={teamPlayers(rosterTeam)} roster={roster}
        onDismiss={() => setRosterTeam(null)}
        onSave={(players, removedIds) => {
          const removed = new Set(removedIds);
          mutate((draft) => ({
            ...draft,
            players: [
              ...draft.players.filter((row) => !removed.has(row.id)).map((row) => players.find((edited) => edited.id === row.id) ?? row),
              ...players.filter((edited) => !draft.players.some((row) => row.id === edited.id)),
            ],
            events: draft.events.map((event) => event.player_id !== null && removed.has(event.player_id) ? { ...event, player_id: null } : event),
            deletions: removedIds.length ? [...draft.deletions, ...tombstones("players", removedIds)] : draft.deletions,
          }));
          setRosterTeam(null);
        }} />}

      {pendingAction && <PlayerChoiceDialog key="pending" teamId={pendingAction.teamId} players={teamPlayers(pendingAction.teamId)} roster={roster} showNone noneLabel="Assign later"
        title={pendingAction.needsRebound ? t("Who took this shot?") : pendingAction.points > 0 ? t("Who scored?") : t("Who recorded this stat?")}
        context={pendingAction.needsRebound ? t("Missed {points}-point shot", { points: pendingAction.value }) : pendingAction.points > 0 ? t("Made {points}-point shot", { points: pendingAction.points }) : t(statNames[pendingAction.type] ?? pendingAction.type)}
        highlighted={lineups[pendingAction.teamId]}
        onPlayer={(player) => {
          const action = pendingAction;
          setPendingAction(null);
          if (action.needsRebound) setMissedShot({ action, shooter: player });
          else if (action.needsAssist) setMadeShot({ action, shooter: player });
          else commit([{ teamId: action.teamId, player, type: action.type, value: action.value, points: action.points }]);
        }}
        // Deferring the player keeps the rest of the flow: the rebound or assist is still asked.
        onNone={() => {
          const action = pendingAction;
          setPendingAction(null);
          if (action.needsRebound) setMissedShot({ action, shooter: null });
          else if (action.needsAssist) setMadeShot({ action, shooter: null });
          else commit([{ teamId: action.teamId, player: null, type: action.type, value: action.value, points: action.points }]);
        }}
        onDismiss={() => setPendingAction(null)} />}

      {madeShot && <PlayerChoiceDialog key="assist" teamId={madeShot.action.teamId} players={teamPlayers(madeShot.action.teamId).filter((player) => player.id !== madeShot.shooter?.id)} roster={roster} showNone
        title={t("Who made the assist?")} context={t("Scorer: {scorer} · {points} points", { scorer: madeShot.shooter ? playerLabel(madeShot.shooter) : t("assign later"), points: madeShot.action.points })}
        highlighted={lineups[madeShot.action.teamId]}
        onPlayer={(player) => { commit([{ teamId: madeShot.action.teamId, player, type: "AST", value: 1 }, shotEvent(madeShot.action, madeShot.shooter)]); setMadeShot(null); }}
        onNone={() => { commit([shotEvent(madeShot.action, madeShot.shooter)]); setMadeShot(null); }}
        onDismiss={() => setMadeShot(null)}
        onBack={() => { setPendingAction(madeShot.action); setMadeShot(null); }} />}

      {missedShot && <ReboundDialog key="rebound" homeTeamId={game.home_id} awayTeamId={game.away_id} homeName={teamName(game.home_id)} awayName={teamName(game.away_id)} shootingTeamId={missedShot.action.teamId} players={data.players} roster={roster}
        onPlayer={(player) => { commit([shotEvent(missedShot.action, missedShot.shooter), { teamId: player.team_id, player, type: "REB", value: 1 }]); setMissedShot(null); }}
        onNone={() => { commit([shotEvent(missedShot.action, missedShot.shooter)]); setMissedShot(null); }}
        onDismiss={() => setMissedShot(null)} />}

      {freeThrow && (freeThrow.player === null && !freeThrow.playerSkipped
        ? <PlayerChoiceDialog key="ft-shooter" teamId={freeThrow.teamId} players={teamPlayers(freeThrow.teamId)} roster={roster} showNone noneLabel="Assign later"
          title={t("Select shooter")} context={t("Select the player taking the free throws")} highlighted={lineups[freeThrow.teamId]}
          onPlayer={(player) => setFreeThrow({ ...freeThrow, player })}
          onNone={() => setFreeThrow({ ...freeThrow, playerSkipped: true })}
          onDismiss={() => setFreeThrow(null)} />
        : <FreeThrowDialog key="ft-attempts" flow={freeThrow} onUpdate={setFreeThrow}
          onSave={(results) => {
            if (results[results.length - 1] === false) setFreeThrowRebound({ flow: freeThrow, results });
            else commit(freeThrowEvents(freeThrow, results));
            setFreeThrow(null);
          }}
          onDismiss={() => setFreeThrow(null)}
          onBack={() => setFreeThrow({ ...freeThrow, player: null, playerSkipped: false, results: [] })} />)}

      {freeThrowRebound && <ReboundDialog key="ft-rebound" homeTeamId={game.home_id} awayTeamId={game.away_id} homeName={teamName(game.home_id)} awayName={teamName(game.away_id)} shootingTeamId={freeThrowRebound.flow.teamId} players={data.players} roster={roster}
        onPlayer={(player) => { commit([...freeThrowEvents(freeThrowRebound.flow, freeThrowRebound.results), { teamId: player.team_id, player, type: "REB", value: 1 }]); setFreeThrowRebound(null); }}
        onNone={() => { commit(freeThrowEvents(freeThrowRebound.flow, freeThrowRebound.results)); setFreeThrowRebound(null); }}
        onDismiss={() => setFreeThrowRebound(null)} />}

      {foul && (foul.player === null && !foul.playerSkipped
        ? <PlayerChoiceDialog key="foul-by" teamId={foul.teamId} players={teamPlayers(foul.teamId)} roster={roster} showNone noneLabel="Assign later"
          title={t("Who committed the foul?")} context={t("Select the player who committed the foul")} highlighted={lineups[foul.teamId]}
          onPlayer={(player) => setFoul({ ...foul, player })}
          onNone={() => setFoul({ ...foul, playerSkipped: true })}
          onDismiss={() => setFoul(null)} />
        // Picking the fouled player records the foul straight away; there is no separate confirmation step.
        : (() => {
          const opponentId = foul.teamId === game.home_id ? game.away_id : game.home_id;
          const save = () => { commit([{ teamId: foul.teamId, player: foul.player, type: "FOUL", value: 1 }]); setFoul(null); };
          return <PlayerChoiceDialog key="fouled" teamId={opponentId} players={teamPlayers(opponentId)} roster={roster} showNone noneLabel="Assign later"
            title={t("Who was fouled?")} context={t("Select the opposing player who was fouled")} highlighted={lineups[opponentId]}
            onPlayer={save} onNone={save} onDismiss={() => setFoul(null)}
            onBack={() => setFoul({ ...foul, player: null, playerSkipped: false })} />;
        })())}
    </CardContent>
  </Card>;
}
