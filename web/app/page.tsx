"use client";
import { titleCase } from "@/lib/text";

import { joinName } from "@/lib/player-name";
import { playerLabel } from "@/lib/scoring";
import {
  ChangeEvent,
  FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { navItems, type SectionKey, SectionNav } from "@/components/section-nav";
import { AppHeader } from "@/components/app-header";
import { DashboardHome } from "@/components/dashboard-home";
import { accountLabel, initials } from "@/lib/account";
import { useI18n } from "@/lib/i18n";
import { LANGUAGES } from "@/lib/i18n-core";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { User } from "@supabase/supabase-js";
import {
  type DeletableEntity,
  type Deletion,
  emptySnapshot,
  type Game,
  mergeSnapshots,
  type Player,
  type Snapshot,
  type StatEvent,
  type Team,
} from "../lib/types";
import { isConfigured, supabase } from "../lib/supabase";
import { loadSnapshot, saveSnapshot } from "../lib/cloud-data";
import { deviceId } from "../lib/device";
import { nextId } from "../lib/local-id";
import { exportGameFileName, exportGameJson, importGameJson } from "../lib/game-portability";
import { comparePlayers, getPlayerSort, playerSelectionLabel, type PlayerSort } from "../lib/player-sort";

const statColumns = [
  ["PTS", "PTS"],
  ["2PM", "2PM"],
  ["2PA", "2PA"],
  ["2P%", "2P%"],
  ["3PM", "3PM"],
  ["3PA", "3PA"],
  ["3P%", "3P%"],
  ["FTM", "FTM"],
  ["FTA", "FTA"],
  ["FT%", "FT%"],
  ["REB", "REB"],
  ["AST", "AST"],
  ["STL", "STL"],
  ["BLK", "BLK"],
  ["TOV", "TO"],
  ["FOUL", "PF"],
] as const;
const statButtons = [
  ["REB", "Rebound"],
  ["AST", "Assist"],
  ["STL", "Steal"],
  ["BLK", "Block"],
  ["TOV", "Turnover"],
  ["FOUL", "Foul"],
] as const;
const statActionButtons = [
  ["PTS_2", "2 Points"],
  ["PTS_3", "3 Points"],
  ["FT", "Free Throw"],
  ...statButtons,
] as const;
const qualities = ["HIGHEST", "UHD", "FHD", "HD", "SD"];
type FreeThrowFormat = "1+1" | "1" | "2" | "3";
type FreeThrowResult = "made" | "missed" | null;
type CaptureMode = "record" | "score" | "full";

/** Records what was deleted, when, and by which device, so other devices replay the same removal. */
function tombstones(entity: DeletableEntity, ids: number[]): Deletion[] {
  const deleted_at = Date.now();
  const device_id = deviceId();
  return ids.map((local_id) => ({ entity, local_id, deleted_at, device_id }));
}
function formatClock(ms: number) {
  return `${String(Math.floor(ms / 60000)).padStart(2, "0")}:${
    String(Math.floor(ms / 1000) % 60).padStart(2, "0")
  }`;
}
function points(events: StatEvent[]) {
  // Includes manual +1/-1 adjustments so the points column adds up to the scoreboard.
  return events.filter((e) => e.type.startsWith("PTS_") || e.type === "FT_MADE" || e.type === "ADJ")
    .reduce((sum, e) => sum + e.value, 0);
}
function statValue(events: StatEvent[], type: string): number | string {
  const eventTypes: Record<string, string[]> = {
    "2PM": ["PTS_2"],
    "2PA": ["PTS_2", "MISS_2"],
    "3PM": ["PTS_3"],
    "3PA": ["PTS_3", "MISS_3"],
    "FTM": ["FT_MADE"],
    "FTA": ["FT_MADE", "FT_MISS"],
  };
  if (type.endsWith("%")) {
    const prefix = type.slice(0, -1);
    const madeTypes = eventTypes[`${prefix}M`] ?? [];
    const attemptTypes = eventTypes[`${prefix}A`] ?? [];
    const made = events.filter((event) => madeTypes.includes(event.type))
      .reduce((sum, event) => sum + event.value, 0);
    const attempts = events.filter((event) => attemptTypes.includes(event.type))
      .reduce((sum, event) => sum + event.value, 0);
    return attempts ? `${((made / attempts) * 100).toFixed(1)}%` : "—";
  }
  return (eventTypes[type] ?? [type]).reduce(
    (sum, eventType) => sum + events.filter((event) => event.type === eventType).length,
    0,
  );
}
function errorMessage(error: unknown, fallback: string) {
  return error instanceof Error
    ? error.message
    : typeof error === "object" && error !== null && "message" in error &&
        typeof error.message === "string"
    ? error.message
    : fallback;
}
function download(name: string, content: BlobPart, type: string) {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}
function eventLabel(type: string) {
  return ({
    STARTER: "Starter",
    PTS_2: "2-point field goal made",
    PTS_3: "3-point field goal made",
    MISS_2: "2-point field goal missed",
    MISS_3: "3-point field goal missed",
    FT_MADE: "Free throw made",
    FT_MISS: "Free throw missed",
    REB: "Rebound",
    AST: "Assist",
    STL: "Steal",
    BLK: "Block",
    TOV: "Turnover",
    FOUL: "Foul",
    FOULED: "Foul drawn",
    SUB_OUT: "Substitution out",
    SUB_IN: "Substitution in",
  } as Record<string, string>)[type] ?? type;
}

type TabKey = SectionKey;
const isTabKey = (value: string | null): value is TabKey =>
  navItems.some((item) => item.key === value);

function authRedirectUrl() {
  if (typeof window === "undefined") return "https://www.hoopreplay.com";
  return window.location.hostname === "localhost" ||
      window.location.hostname === "127.0.0.1"
    ? window.location.origin
    : "https://www.hoopreplay.com";
}

export default function Dashboard() {
  const [data, setData] = useState<Snapshot>(emptySnapshot);
  const [selectedGameId, setSelectedGameId] = useState<number | null>(null);
  const [status, setStatus] = useState(
    isConfigured ? "Connecting…" : "Setup required",
  );
  const [saving, setSaving] = useState(false);
  // False until the first snapshot for this sign-in has arrived, so the dashboard shows skeletons.
  const [loaded, setLoaded] = useState(false);
  const [user, setUser] = useState<User | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [showAuth, setShowAuth] = useState(false);
  const [authMode, setAuthMode] = useState<"login" | "signup">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [passwordVisible, setPasswordVisible] = useState(false);
  const [authMessage, setAuthMessage] = useState("");
  const [teamName, setTeamName] = useState("");
  const [playerFirst, setPlayerFirst] = useState("");
  const [playerLast, setPlayerLast] = useState("");
  const [playerNumber, setPlayerNumber] = useState("");
  const [playerTeamId, setPlayerTeamId] = useState<number | "">("");
  const [showGameForm, setShowGameForm] = useState(false);
  const [tab, setTab] = useState<TabKey>("dashboard");
  const [playerSort, setPlayerSort] = useState<PlayerSort>("number");
  const { t, language, setLanguage } = useI18n();

  // The sidebar on the resource pages links back here with ?tab=…, so honour that on arrival.
  // Those pages have no sign-in form of their own either, so ?auth=… opens this one for them.
  useEffect(() => {
    setPlayerSort(getPlayerSort());
    const params = new URLSearchParams(window.location.search);
    const requested = params.get("tab");
    if (isTabKey(requested)) setTab(requested);
    const auth = params.get("auth");
    if (auth === "login" || auth === "signup") {
      setAuthMode(auth);
      setShowAuth(true);
    }
    // Our Google callback (/api/login/google) returns here with the session, or an error, in the hash.
    const hash = new URLSearchParams(window.location.hash.slice(1));
    if (hash.has("token") || hash.has("login_error")) {
      window.history.replaceState(null, "", window.location.pathname + window.location.search);
      const loginError = hash.get("login_error");
      if (loginError) {
        setAuthMessage(`Sign in failed: ${loginError}`);
        setShowAuth(true);
      } else {
        void supabase?.auth.setSession({
          access_token: hash.get("token") ?? "",
          refresh_token: hash.get("refresh") ?? "",
        });
      }
    }
  }, []);
  const [confirmDialog, setConfirmDialog] = useState<
    {
      title: string;
      message: string;
      confirmLabel: string;
      danger: boolean;
      cancelable: boolean;
    } | null
  >(null);
  const confirmResolve = useRef<((confirmed: boolean) => void) | null>(null);
  const importInput = useRef<HTMLInputElement | null>(null);
  // Bumped on every local edit so an in-flight sync can tell it is about to overwrite newer data.
  const localRevision = useRef(0);

  const load = useCallback(async () => {
    if (!supabase || !user) return;
    setStatus("Syncing…");
    // Edits made while this request is in flight must survive it, so remember where we started.
    const startedAt = localRevision.current;
    try {
      const snapshot = await loadSnapshot(user);
      const edited = localRevision.current !== startedAt;
      setData((current) =>
        edited ? mergeSnapshots(current, snapshot) : snapshot
      );
      setSelectedGameId((current) =>
        current ?? snapshot.games.at(-1)?.id ?? null
      );
      setStatus("Synced");
    } catch (error) {
      setStatus(errorMessage(error, "Sync failed"));
    } finally {
      setLoaded(true);
    }
  }, [user]);
  useEffect(() => {
    if (!supabase) return;
    const authTimeout = window.setTimeout(() => {
      setAuthReady(true);
      setStatus((current) =>
        current === "Connecting…" ? "Local only — sign in to sync" : current
      );
    }, 5_000);
    supabase.auth.getUser().then(({ data }) => {
      setUser(data.user);
      if (!data.user) setStatus("Local only — sign in to sync");
    }).finally(() => {
      clearTimeout(authTimeout);
      setAuthReady(true);
    });
    const { data: listener } = supabase.auth.onAuthStateChange(
      (_e, session) => {
        setUser(session?.user ?? null);
        setAuthReady(true);
        if (!session) {
          setData(emptySnapshot());
          setSelectedGameId(null);
          setLoaded(false);
          setStatus("Local only — sign in to sync");
        }
      },
    );
    return () => {
      clearTimeout(authTimeout);
      listener.subscription.unsubscribe();
    };
  }, []);
  useEffect(() => {
    if (!user) return;
    const initial = window.setTimeout(load, 0);
    return () => clearTimeout(initial);
  }, [load, user]);

  const save = async (next = data) => {
    setData(next);
    if (!supabase || !user) {
      if (!user) setShowAuth(true);
      return;
    }
    setSaving(true);
    setStatus("Saving…");
    const payload = { ...next, updatedAt: Date.now() };
    try {
      const deletions = await saveSnapshot(user, payload);
      // Only replace what this save wrote; a newer edit brings its own save along.
      setData((current) => (current === next ? { ...payload, deletions } : current));
      setStatus("Synced");
    } catch (error) {
      setStatus(errorMessage(error, "Save failed"));
    } finally {
      setSaving(false);
    }
  };
  const importGameFile = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    try {
      const result = importGameJson(data, JSON.parse(await file.text()));
      await save(result.snapshot);
      setSelectedGameId(result.gameId);
      setStatus(
        t("Imported {events} plays, {teams} new teams, {players} new players", { events: result.events, teams: result.createdTeams, players: result.createdPlayers }),
      );
    } catch (error) {
      setStatus(errorMessage(error, "Import failed"));
    }
  };
  const authenticate = async (event: FormEvent) => {
    event.preventDefault();
    if (!supabase) return;
    setAuthMessage("");
    const result = authMode === "login"
      ? await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      })
      : await supabase.auth.signUp({
        email: email.trim(),
        password,
        options: { emailRedirectTo: authRedirectUrl() },
      });
    if (result.error) return setAuthMessage(result.error.message);
    if (!result.data.session) {
      return setAuthMessage(
        t("Account created. Confirm your email, then sign in."),
      );
    }
    setShowAuth(false);
    setPasswordVisible(false);
    setPassword("");
  };
  const authenticateWithProvider = (provider: "google" | "apple") => {
    if (!supabase) return;
    setAuthMessage("");
    // Both run through our own API (no Supabase provider). A full navigation, not a Next page:
    // the route answers with a redirect to Google / Apple and returns to / with the session hash.
    // eslint-disable-next-line @next/next/no-location-assign-relative-destination
    window.location.href =
      `${window.location.origin}/api/login/${provider}/start?redirect_to=${encodeURIComponent(window.location.pathname)}`;
  };
  const resetPassword = async () => {
    if (!supabase || !email.trim()) {
      setAuthMessage(t("Enter your email address first."));
      return;
    }
    setAuthMessage("");
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
      redirectTo: authRedirectUrl(),
    });
    setAuthMessage(error?.message ?? t("Password reset link sent. Check your email."));
  };
  const teamById = useMemo(
    () => new Map(data.teams.map((team) => [team.id, team])),
    [data.teams],
  );
  const mutate = (recipe: (draft: Snapshot) => Snapshot) => {
    const next = recipe(data);
    localRevision.current += 1;
    setData(next);
    if (user) void save(next);
    return next;
  };
  const askConfirmation = (
    title: string,
    message: string,
    confirmLabel = t("Delete"),
    danger = true,
    cancelable = true,
  ) =>
    new Promise<boolean>((resolve) => {
      confirmResolve.current = resolve;
      setConfirmDialog({ title, message, confirmLabel, danger, cancelable });
    });
  const closeConfirmation = (confirmed: boolean) => {
    confirmResolve.current?.(confirmed);
    confirmResolve.current = null;
    setConfirmDialog(null);
  };

  function addTeam(event: FormEvent) {
    event.preventDefault();
    if (!teamName.trim()) return;
    mutate((d) => ({
      ...d,
      teams: [...d.teams, {
        id: nextId(d.teams),
        name: teamName.trim(),
        created_at: Date.now(),
      }],
    }));
    setTeamName("");
  }
  function addPlayer(event: FormEvent) {
    event.preventDefault();
    const name = joinName(playerFirst, playerLast);
    if (playerTeamId === "" || (!name && !playerNumber.trim())) {
      return;
    }
    mutate((d) => ({
      ...d,
      players: [...d.players, {
        id: nextId(d.players),
        team_id: playerTeamId,
        name,
        number: playerNumber.trim(),
      }],
    }));
    setPlayerFirst("");
    setPlayerLast("");
    setPlayerNumber("");
  }
  async function deleteTeam(team: Team) {
    if (
      data.games.some((g) => g.home_id === team.id || g.away_id === team.id)
    ) {
      await askConfirmation(
        t("Unable to Delete Team"),
        t("This team is used by a game. Delete the related game first."),
        t("OK"),
        false,
        false,
      );
      return;
    }
    if (
      !await askConfirmation(
        t("Delete Team?"),
        t("Delete {name} and all of its players?", { name: team.name }),
      )
    ) return;
    mutate((d) => ({
      ...d,
      teams: d.teams.filter((t) => t.id !== team.id),
      players: d.players.filter((p) => p.team_id !== team.id),
      deletions: [
        ...d.deletions,
        ...tombstones("teams", [team.id]),
        ...tombstones(
          "players",
          d.players.filter((p) => p.team_id === team.id).map((p) => p.id),
        ),
      ],
    }));
  }
  async function deletePlayer(player: Player) {
    if (
      !await askConfirmation(
        t("Delete Player?"),
        t("Delete {name}? Existing events will be retained as team events.", { name: player.name || player.number }),
      )
    ) return;
    mutate((d) => ({
      ...d,
      players: d.players.filter((p) => p.id !== player.id),
      events: d.events.map((e) =>
        e.player_id === player.id ? { ...e, player_id: null } : e
      ),
      deletions: [...d.deletions, ...tombstones("players", [player.id])],
    }));
  }
  async function deleteGame(target: Game) {
    if (
      !await askConfirmation(
        t("Delete Game?"),
        t("Delete {title} and all of its events and video clips?", { title: target.title }),
      )
    ) return;
    const next = mutate((d) => ({
      ...d,
      games: d.games.filter((g) => g.id !== target.id),
      events: d.events.filter((e) => e.game_id !== target.id),
      segments: d.segments.filter((s) => s.game_id !== target.id),
      deletions: [
        ...d.deletions,
        ...tombstones("games", [target.id]),
        ...tombstones(
          "events",
          d.events.filter((e) => e.game_id === target.id).map((e) => e.id),
        ),
        ...tombstones(
          "segments",
          d.segments.filter((s) => s.game_id === target.id).map((s) => s.id),
        ),
      ],
    }));
    setSelectedGameId(next.games.at(-1)?.id ?? null);
  }
  async function deletePlay(game: Game, event: StatEvent) {
    if (!await askConfirmation(t("Delete Play?"), t("Delete {play} from Q{period}?", { play: t(eventLabel(event.type)), period: event.period }))) return;
    mutate((d) => {
      const scored = event.type.startsWith("PTS_") || event.type === "FT_MADE";
      return { ...d,
        events: d.events.filter((row) => row.id !== event.id),
        games: d.games.map((row) => row.id !== game.id ? row : { ...row,
          home_score: Math.max(0, row.home_score - (scored && event.team_id === game.home_id ? event.value : 0)),
          away_score: Math.max(0, row.away_score - (scored && event.team_id === game.away_id ? event.value : 0)),
        }),
        deletions: [...d.deletions, ...tombstones("events", [event.id])],
      };
    });
  }

  const accountName = accountLabel(user);
  const activeGameNotices = useMemo(() =>
    data.games
      .filter((item) => item.status === "RECORDING" || item.status === "PAUSED")
      .map((item) => ({
        id: String(item.id),
        title: item.title || t("{away} vs {home}", { away: teamById.get(item.away_id)?.name ?? t("Away"), home: teamById.get(item.home_id)?.name ?? t("Home") }),
        subtitle: item.status === "RECORDING" ? "Recording now" : "Live · paused",
        href: `/games/${item.uuid_id ?? item.id}`,
      })), [data.games, teamById, t]);
  const setupNotice = !isConfigured
    ? (
      <section className="setup">
        <strong>{t("Connect Supabase to sync.")}</strong>
        <span>
          {t("Add the project URL, publishable key, and shared sync space to")}{" "}
          <code>.env.local</code>. {t("All editing features still work in this browser session.")}
        </span>
      </section>
    )
    : null;

  return (
    <main className="shell">
      <AppHeader
        user={user}
        authReady={authReady}
        status={status}
        saving={saving}
        notices={activeGameNotices}
        onSignIn={() => {
          setAuthMode("login");
          setShowAuth(true);
        }}
        onSignUp={() => {
          setAuthMode("signup");
          setShowAuth(true);
        }}
        onAccountSettings={() => setTab("settings")}
      />
      <div className="appBody">
        <SectionNav current={tab} onSelect={setTab} />
        <div className="tabPanel">
          {tab === "dashboard" && (
            <>
              {setupNotice}
              <DashboardHome
                data={data}
                accountName={accountName}
                loading={!authReady || (user !== null && !loaded)}
                canCreateGame={data.teams.length >= 2}
                onNewGame={() => setShowGameForm(true)}
                onImport={() => setTab("import")}
              />
            </>
          )}
          {tab === "teams" && (
            <section className="manager panel">
              <div className="drawerHeading">
                <div>
                  <div className="sectionTitle">
                    <span>{t("Teams")}</span>
                    <b>{data.teams.length}</b>
                  </div>
                  <p>
                    {t("{teams} teams · {players} players", { teams: data.teams.length, players: data.players.length })}
                  </p>
                </div>
              </div>
              <form onSubmit={addTeam}>
                <label>{t("New team")}</label>
                <div className="inline">
                  <input
                    value={teamName}
                    onChange={(e) => setTeamName(e.target.value)}
                    placeholder={t("Team name")}
                  />
                  <button className="primary">{t("Add")}</button>
                </div>
              </form>
              <div className="rosters">
                {data.teams.map((team) => (
                  <div className="roster" key={team.id}>
                    <h3>
                      <span>
                        {team.name}
                        <small>
                          {t("{count} players", { count: data.players.filter((p) => p.team_id === team.id).length })}
                        </small>
                      </span>
                      <button
                        aria-label={t("Delete {name}", { name: team.name })}
                        onClick={() => deleteTeam(team)}
                      >
                        ⋯
                      </button>
                    </h3>
                  </div>
                ))}
                {data.teams.length === 0 && (
                  <div className="empty">
                    {t("No teams yet. Add two teams to create your first game.")}
                  </div>
                )}
              </div>
            </section>
          )}
          {tab === "players" && (
            <section className="manager panel">
              <div className="drawerHeading">
                <div>
                  <div className="sectionTitle">
                    <span>{t("Players")}</span>
                    <b>{data.players.length}</b>
                  </div>
                  <p>
                    {t("{players} players across {teams} teams", { players: data.players.length, teams: data.teams.length })}
                  </p>
                </div>
              </div>
              <form onSubmit={addPlayer}>
                <label>{t("New player")}</label>
                <select
                  value={playerTeamId}
                  onChange={(e) =>
                    setPlayerTeamId(
                      e.target.value ? Number(e.target.value) : "",
                    )}
                >
                  <option value="">{t("Select team")}</option>
                  {data.teams.map((team) => (
                    <option key={team.id} value={team.id}>{team.name}</option>
                  ))}
                </select>
                <div className="inline">
                  <input
                    className="number"
                    value={playerNumber}
                    onChange={(e) => setPlayerNumber(e.target.value)}
                    placeholder="#"
                  />
                  <input
                    value={playerFirst}
                    onChange={(e) => setPlayerFirst(e.target.value)}
                    placeholder={t("First name")}
                  />
                  <input
                    value={playerLast}
                    onChange={(e) => setPlayerLast(e.target.value)}
                    placeholder={t("Last name")}
                  />
                </div>
                <button className="primary full">{t("Add player")}</button>
              </form>
              <div className="rosters">
                {data.teams.map((team) => (
                  <div className="roster" key={team.id}>
                    <h3>
                      <span>
                        {team.name}
                        <small>
                          {t("{count} players", { count: data.players.filter((p) => p.team_id === team.id).length })}
                        </small>
                      </span>
                    </h3>
                    <div className="tags">
                      {data.players.filter((p) => p.team_id === team.id).sort(
                        comparePlayers,
                      ).map((player) => (
                        <span key={player.id}>
                          #{player.number || "—"} {player.name}
                          <button
                            aria-label={t("Archive {name}", { name: player.name })}
                            onClick={() => deletePlayer(player)}
                          >
                            {t("Archive")}
                          </button>
                        </span>
                      ))}
                    </div>
                  </div>
                ))}
                {data.teams.length === 0 && (
                  <div className="empty">
                    {t("No teams yet. Add a team before adding players.")}
                  </div>
                )}
              </div>
            </section>
          )}
          {tab === "import" && (
            <section className="tabSection">
              <div className="sectionTitle">
                <span>{t("Import")}</span>
              </div>
              <div className="panel importCard">
                <p>
                  {t("Bring in a game exported as JSON from the Android app or from this web app. Missing teams and players are created automatically, and the imported game opens right away.")}
                </p>
                <button
                  className="primary"
                  onClick={() => importInput.current?.click()}
                >
                  {t("Choose JSON file")}
                </button>
                <input
                  ref={importInput}
                  type="file"
                  accept="application/json,.json"
                  hidden
                  onChange={importGameFile}
                />
              </div>
              <div className="sectionTitle">
                <span>{t("Previous games")}</span>
                <b>{data.games.length}</b>
              </div>
              <div className="panel importList">
                {data.games.length === 0 && (
                  <div className="empty">
                    {t("Nothing imported or recorded yet.")}
                  </div>
                )}
                {[...data.games].sort((a, b) => b.scheduled_at - a.scheduled_at)
                  .slice(0, 20).map((item) => (
                    <div className="importRow" key={item.id}>
                      <div>
                        <strong>{item.title}</strong>
                        <small>
                          {t("{home} vs {away}", { home: teamById.get(item.home_id)?.name ?? "", away: teamById.get(item.away_id)?.name ?? "" })} ·{" "}
                          {new Date(item.scheduled_at).toLocaleDateString()}
                        </small>
                      </div>
                      <div className="importRowActions">
                        <button
                          onClick={() => {
                            setSelectedGameId(item.id);
                            setTab("games");
                          }}
                        >
                          {t("Open")}
                        </button>
                        <button
                          onClick={() =>
                            download(
                              exportGameFileName(data, item),
                              JSON.stringify(
                                exportGameJson(data, item),
                                null,
                                2,
                              ),
                              "application/json",
                            )}
                        >
                          {t("Export JSON")}
                        </button>
                      </div>
                    </div>
                  ))}
              </div>
            </section>
          )}
          {tab === "settings" && (
            <section className="tabSection">
              <div className="sectionTitle">
                <span>{t("Settings")}</span>
              </div>
              {setupNotice}
              <div className="panel settingsCard">
                <h3>{t("Player selection order")}</h3>
                <p className="empty">{t("Choose how players are ordered in selection dialogs.")}</p>
                {(["first", "last", "number"] as PlayerSort[]).map((option) => (
                  <label className="settingsRow" key={option}>
                    <span>{option === "first" ? t("First name") : option === "last" ? t("Last name") : t("Jersey number")}</span>
                    <input type="radio" name="player-sort" checked={playerSort === option} onChange={() => { setPlayerSort(option); window.localStorage.setItem("player_sort", option); }} />
                  </label>
                ))}
              </div>
              <div className="panel settingsCard">
                <h3>{t("Account")}</h3>
                <div className="settingsRow">
                  <span>{t("Interface Language")}</span>
                  <Select value={language} onValueChange={(value) => setLanguage(value as typeof language)}>
                    <SelectTrigger className="w-44" aria-label={t("Interface Language")}><SelectValue /></SelectTrigger>
                    <SelectContent>{LANGUAGES.map((option) => <SelectItem key={option.code} value={option.code}>{option.name}</SelectItem>)}</SelectContent>
                  </Select>
                </div>
                {user
                  ? (
                    <>
                      <div className="settingsRow">
                        <span>{t("Name")}</span>
                        <strong>{accountName}</strong>
                      </div>
                      <div className="settingsRow">
                        <span>{t("Email")}</span>
                        <strong>{user.email}</strong>
                      </div>
                      <button
                        className="danger"
                        onClick={() => supabase?.auth.signOut()}
                      >
                        {t("Sign out")}
                      </button>
                    </>
                  )
                  : (
                    <>
                      <p className="empty">
                        {t("Sign in to sync games across mobile and Web.")}
                      </p>
                      <button
                        className="primary"
                        onClick={() => {
                          setAuthMode("login");
                          setShowAuth(true);
                        }}
                      >
                        {t("Sign in")}
                      </button>
                    </>
                  )}
              </div>
              <div className="panel settingsCard">
                <h3>{t("Storage")}</h3>
                <div className="settingsRow">
                  <span>{t("Teams")}</span>
                  <strong>{data.teams.length}</strong>
                </div>
                <div className="settingsRow">
                  <span>{t("Players")}</span>
                  <strong>{data.players.length}</strong>
                </div>
                <div className="settingsRow">
                  <span>{t("Games")}</span>
                  <strong>{data.games.length}</strong>
                </div>
                <div className="settingsRow">
                  <span>{t("Recorded plays")}</span>
                  <strong>{data.events.length}</strong>
                </div>
              </div>
            </section>
          )}
        </div>
      </div>
      {showGameForm && (
        <GameForm
          teams={data.teams}
          onClose={() => setShowGameForm(false)}
          onCreate={(newGame) => {
            const next = mutate((d) => ({
              ...d,
              games: [...d.games, {
                ...newGame,
                id: nextId(d.games),
                uuid_id: crypto.randomUUID(),
                home_score: 0,
                away_score: 0,
                status: "READY",
                current_period: 1,
                clock_remaining_ms: newGame.period_duration_ms,
                created_at: Date.now(),
              }],
            }));
            setSelectedGameId(next.games.at(-1)!.id);
            setShowGameForm(false);
          }}
        />
      )}
      {showAuth && (
        <div
          className="modalBackdrop"
          onMouseDown={() => {
            setShowAuth(false);
            setPasswordVisible(false);
          }}
        >
          <form
            className="authModal panel"
            onSubmit={authenticate}
            onMouseDown={(e) => e.stopPropagation()}
          >
            <div className="authHeading">
              <div>
                <h2>{authMode === "login" ? t("Sign in") : t("Create account")}</h2>
                <p>{t("Sync scores and statistics across mobile and Web.")}</p>
              </div>
              <button
                type="button"
                onClick={() => {
                  setShowAuth(false);
                  setPasswordVisible(false);
                }}
              >
                ×
              </button>
            </div>
            <div className="authTabs">
              <button
                type="button"
                className={authMode === "login" ? "active" : ""}
                onClick={() => setAuthMode("login")}
              >
                {t("Sign in")}
              </button>
              <button
                type="button"
                className={authMode === "signup" ? "active" : ""}
                onClick={() => setAuthMode("signup")}
              >
                {t("Register")}
              </button>
            </div>
            <button
              type="button"
              className="googleAuthButton"
              onClick={() => authenticateWithProvider("google")}
            >
              <span className="googleMark" aria-hidden="true">G</span>
              {t("Continue with Google")}
            </button>
            <button
              type="button"
              className="appleAuthButton"
              onClick={() => authenticateWithProvider("apple")}
            >
              <svg className="appleMark" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701" />
              </svg>
              {t("Continue with Apple")}
            </button>
            <div className="authDivider"><span>{t("or use email")}</span></div>
            <label>
              {t("Email")}<input
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </label>
            <label>
              {t("Password")}
              <span className="passwordField">
                <input
                  type={passwordVisible ? "text" : "password"}
                  minLength={6}
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                />
                <button
                  type="button"
                  aria-label={passwordVisible ? t("Hide password") : t("Show password")}
                  aria-pressed={passwordVisible}
                  onClick={() => setPasswordVisible((visible) => !visible)}
                >
                  {passwordVisible
                    ? (
                      <svg viewBox="0 0 24 24" aria-hidden="true">
                        <path d="M3 3l18 18M10.6 10.7a2 2 0 002.7 2.7M9.9 4.2A10.8 10.8 0 0112 4c5.5 0 9 5.2 9 5.2a15.8 15.8 0 01-2.5 3M6.6 6.6A16.7 16.7 0 003 9.2s3.5 5.2 9 5.2a9.7 9.7 0 003.4-.6" />
                      </svg>
                    )
                    : (
                      <svg viewBox="0 0 24 24" aria-hidden="true">
                        <path d="M3 12s3.5-5.2 9-5.2 9 5.2 9 5.2-3.5 5.2-9 5.2S3 12 3 12z" />
                        <circle cx="12" cy="12" r="2.5" />
                      </svg>
                    )}
                </button>
              </span>
            </label>
            {authMessage && <div className="authError">{authMessage}</div>}
            {authMode === "login" && (
              <button type="button" className="textAction" onClick={resetPassword}>
                {t("Forgot password?")}
              </button>
            )}
            <button className="primary full">{t("Continue")}</button>
          </form>
        </div>
      )}
      {confirmDialog && (
        <div className="modalBackdrop confirmBackdrop">
          <section
            className="confirmDialog panel"
            role="alertdialog"
            aria-modal="true"
            aria-labelledby="confirm-title"
            aria-describedby="confirm-message"
          >
            <div
              className={`confirmIcon ${
                confirmDialog.danger ? "danger" : "notice"
              }`}
            >
              {confirmDialog.danger ? "!" : "i"}
            </div>
            <h2 id="confirm-title">{confirmDialog.title}</h2>
            <p id="confirm-message">{confirmDialog.message}</p>
            <div className="confirmActions">
              {confirmDialog.cancelable && (
                <button onClick={() => closeConfirmation(false)}>{t("Cancel")}</button>
              )}
              <button
                className={confirmDialog.danger ? "danger" : "primary"}
                onClick={() => closeConfirmation(true)}
              >
                {confirmDialog.confirmLabel}
              </button>
            </div>
          </section>
        </div>
      )}
    </main>
  );
}

function GameForm({
  teams,
  onClose,
  onCreate,
}: {
  teams: Team[];
  onClose: () => void;
  onCreate: (
    game: Omit<
      Game,
      | "id"
      | "home_score"
      | "away_score"
      | "status"
      | "current_period"
      | "clock_remaining_ms"
      | "created_at"
    >,
  ) => void;
}) {
  const { t } = useI18n();
  const [home, setHome] = useState(teams[0]?.id ?? 0);
  const [away, setAway] = useState(teams[1]?.id ?? 0);
  const [title, setTitle] = useState("");
  const [periods, setPeriods] = useState(4);
  const [minutes, setMinutes] = useState(8);
  const [quality, setQuality] = useState("HIGHEST");
  const [scheduled, setScheduled] = useState(
    new Date().toISOString().slice(0, 16),
  );
  const applyPreset = (preset: "youth" | "college") => {
    setPeriods(preset === "college" ? 2 : 4);
    setMinutes(preset === "college" ? 20 : 8);
  };
  return (
    <div className="modalBackdrop">
      <form
        className="formModal panel"
        onSubmit={(e) => {
          e.preventDefault();
          if (home === away) return;
          onCreate({
            title: title.trim() ||
              `${teams.find((t) => t.id === home)?.name} vs ${
                teams.find((t) => t.id === away)?.name
              }`,
            home_id: home,
            away_id: away,
            scheduled_at: new Date(scheduled).getTime(),
            video_quality: quality,
            period_count: periods,
            period_duration_ms: minutes * 60_000,
          });
        }}
      >
        <div className="authHeading">
          <div>
            <h2>{t("Create game")}</h2>
            <p>{t("Configure matchup, clock, and browser recording quality.")}</p>
          </div>
          <button type="button" onClick={onClose}>×</button>
        </div>
        <label>{t("Game name")}<input value={title} onChange={(e) => setTitle(e.target.value)} placeholder={t("Generated automatically if left blank")} /></label>
        <div className="presetRow" aria-label={t("Game rules")}>
          <button type="button" onClick={() => applyPreset("youth")}>{t("Youth / High School · 4 × 8 min")}</button>
          <button type="button" onClick={() => applyPreset("college")}>{t("College · 2 × 20 min")}</button>
        </div>
        <div className="formGrid">
          <label>
            {t("Home")}<select
              value={home}
              onChange={(e) => setHome(Number(e.target.value))}
            >
              {teams.map((t) => (
                <option key={t.id} value={t.id}>{t.name}</option>
              ))}
            </select>
          </label>
          <label>
            {t("Away")}<select
              value={away}
              onChange={(e) => setAway(Number(e.target.value))}
            >
              {teams.map((t) => (
                <option key={t.id} value={t.id}>{t.name}</option>
              ))}
            </select>
          </label>
          <label>
            {t("Date & time")}<input
              type="datetime-local"
              value={scheduled}
              onChange={(e) => setScheduled(e.target.value)}
            />
          </label>
          <label>
            {t("Quality")}<select
              value={quality}
              onChange={(e) => setQuality(e.target.value)}
            >
              {qualities.map((q) => <option key={q} value={q}>{q === "FHD" ? t("1080p · Recommended · about 6 GB/game") : q === "HD" ? t("720p · about 3 GB/game") : q}</option>)}
            </select>
          </label>
          <label>
            {t("Periods")}<input
              type="number"
              min="1"
              max="20"
              value={periods}
              onChange={(e) => setPeriods(Number(e.target.value))}
            />
          </label>
          <label>
            {t("Minutes / period")}<input
              type="number"
              min="1"
              max="60"
              value={minutes}
              onChange={(e) => setMinutes(Number(e.target.value))}
            />
          </label>
        </div>
        {home === away && (
          <div className="authError">{t("Choose two different teams.")}</div>
        )}
        <div className="formActions"><button type="button" onClick={onClose}>{t("Cancel")}</button><button className="primary" disabled={home === away}>{t("Create game")}</button></div>
      </form>
    </div>
  );
}

function GameWorkspace(
  { game, data, setData, save, remove, onDeletePlay }: {
    game: Game;
    data: Snapshot;
    setData: (data: Snapshot) => void;
    save: (data: Snapshot) => Promise<void>;
    remove: () => void;
    onDeletePlay: (event: StatEvent) => Promise<void>;
  },
) {
  const { t } = useI18n();
  const [view, setView] = useState<"stats" | "plays">("stats");
  const [teamSide, setTeamSide] = useState<"home" | "away">("home");
  const [live, setLive] = useState(false);
  const home = data.teams.find((t) => t.id === game.home_id);
  const away = data.teams.find((t) => t.id === game.away_id);
  const events = data.events.filter((e) =>
    e.game_id === game.id && !e.reverted
  );
  const activeId = teamSide === "home" ? game.home_id : game.away_id;
  const players = data.players.filter((p) => p.team_id === activeId).sort(
    comparePlayers,
  );
  // Plays recorded with "Assign later" still belong to the team; list them so the rows add up to the total.
  const unassignedEvents = events.filter((e) => e.team_id === activeId && e.player_id === null && e.type !== "VIDEO");
  const playerById = new Map(data.players.map((p) => [p.id, p]));
  const playRows = [...events].sort((a, b) =>
    a.period - b.period || b.game_clock_ms - a.game_clock_ms || a.id - b.id
  ).reduce<Array<{
    event: StatEvent;
    scored: boolean;
    homeScore: number;
    awayScore: number;
  }>>((rows, event) => {
    const previous = rows.at(-1);
    const scored = event.type.startsWith("PTS_") || event.type === "FT_MADE";
    const homeScore = (previous?.homeScore ?? 0) +
      (scored && event.team_id === game.home_id ? event.value : 0);
    const awayScore = (previous?.awayScore ?? 0) +
      (scored && event.team_id === game.away_id ? event.value : 0);
    return [...rows, { event, scored, homeScore, awayScore }];
  }, []);
  const exportCsv = () =>
    download(
      `HoopReplay_${game.id}_events.csv`,
      [
        "event_id,team_id,player_id,event_type,value,period,game_clock_ms,video_time_ms,reverted",
        ...data.events.filter((e) => e.game_id === game.id).map((e) =>
          `${e.id},${e.team_id},${
            e.player_id ?? ""
          },${e.type},${e.value},${e.period},${e.game_clock_ms},${e.final_video_time_ms},${e.reverted}`
        ),
      ].join("\n"),
      "text/csv",
    );
  const exportJson = () =>
    download(
      exportGameFileName(data, game),
      JSON.stringify(exportGameJson(data, game), null, 2),
      "application/json",
    );
  return (
    <>
      <section className="scoreboard panel">
        <div className="team">
          <span>{t("Home")}</span>
          <h2>{home?.name}</h2>
          <strong>{game.home_score}</strong>
        </div>
        <div className="clock">
          <span>{t("Period {current}/{total}", { current: game.current_period, total: game.period_count })}</span>
          <b>{formatClock(game.clock_remaining_ms)}</b>
          <em>{t(titleCase(game.status))}</em>
        </div>
        <div className="team">
          <span>{t("Away")}</span>
          <h2>{away?.name}</h2>
          <strong>{game.away_score}</strong>
        </div>
      </section>
      <div className="gameActions">
        <button className="primary" onClick={() => setLive(true)}>
          {game.status === "READY" ? t("Start game") : t("Open live controls")}
        </button>
        <button onClick={exportCsv}>{t("Export CSV")}</button>
        <button onClick={exportJson}>{t("Export JSON")}</button>
        <button onClick={() => window.print()}>{t("Print / PDF")}</button>
        <button className="danger" onClick={remove}>{t("Delete game")}</button>
      </div>
      <section className="stats panel">
        <div className="viewTabs">
          <button
            className={view === "stats" ? "active" : ""}
            onClick={() => setView("stats")}
          >
            {t("Statistics")}
          </button>
          <button
            className={view === "plays" ? "active" : ""}
            onClick={() => setView("plays")}
          >
            {t("Play-by-Play")} <b>{events.length}</b>
          </button>
        </div>
        {view === "stats"
          ? (
            <>
              <div className="tabs">
                <button
                  className={teamSide === "home" ? "active" : ""}
                  onClick={() => setTeamSide("home")}
                >
                  {home?.name} {t("(H)")}
                </button>
                <button
                  className={teamSide === "away" ? "active" : ""}
                  onClick={() => setTeamSide("away")}
                >
                  {away?.name} {t("(A)")}
                </button>
              </div>
              <div className="tableWrap">
                <table>
                  <thead>
                    <tr>
                      <th>{t("Player")}</th>
                      {statColumns.map(([, l]) => <th key={l}>{l}</th>)}
                    </tr>
                  </thead>
                  <tbody>
                    {players.map((player) => {
                      const pe = events.filter((e) =>
                        e.player_id === player.id
                      );
                      return (
                        <tr key={player.id}>
                          <td>
                            #{player.number || "—"} <b>{player.name}</b>
                          </td>
                          {statColumns.map(([type]) => (
                            <td key={type}>
                              {type === "PTS" ? points(pe) : statValue(pe, type)}
                            </td>
                          ))}
                        </tr>
                      );
                    })}
                    {unassignedEvents.length > 0 && (
                      <tr>
                        <td>{t("Unassigned")}</td>
                        {statColumns.map(([type]) => (
                          <td key={type}>
                            {type === "PTS" ? points(unassignedEvents) : statValue(unassignedEvents, type)}
                          </td>
                        ))}
                      </tr>
                    )}
                    <tr className="total">
                      <td>{t("Team Total")}</td>
                      {statColumns.map(([type]) => (
                        <td key={type}>
                          {type === "PTS"
                            ? points(
                              events.filter((e) => e.team_id === activeId),
                            )
                            : statValue(events.filter((e) => e.team_id === activeId), type)}
                        </td>
                      ))}
                    </tr>
                  </tbody>
                </table>
              </div>
            </>
          )
          : (
            <div className="playTimeline">
              <header className="playTimelineHeader">
                <div>
                  <span className="teamBadge away">{initials(away?.name)}</span>
                  <strong>{away?.name} <small>{t("(Away)")}</small></strong>
                </div>
                <span>{t("Time")}</span>
                <div>
                  <span className="teamBadge home">{initials(home?.name)}</span>
                  <strong>{home?.name} <small>{t("(Home)")}</small></strong>
                </div>
              </header>
              <div className="playList">
                {playRows.map(({ event: e, scored, homeScore, awayScore }) => {
                  const isHome = e.team_id === game.home_id;
                  const player = e.player_id ? playerById.get(e.player_id) : null;
                  const actorLabel = player ? playerLabel(player) : t("Unassigned");
                  return (
                    <article
                      className={`play ${isHome ? "home" : "away"} ${scored ? "scoring" : ""}`}
                      key={e.id}
                    >
                      <div className="playEvent">
                        <span className="playAction">{t(eventLabel(e.type))}</span>
                        <strong className="playPlayer">{actorLabel}</strong>
                        {scored && <span className="playPoints">+{e.value}</span>}
                      </div>
                      <time>
                        <b>Q{e.period}</b>
                        <span>{formatClock(e.game_clock_ms)}</span>
                        {scored && <em>{awayScore} – {homeScore}</em>}
                      </time>
                      <button className="playDelete" onClick={() => void onDeletePlay(e)} aria-label={t("Delete play")} title={t("Delete play")}>×</button>
                    </article>
                  );
                })}
              </div>
            </div>
          )}
      </section>
      {live && (
        <LiveGame
          game={game}
          data={data}
          onChange={setData}
          onSave={save}
          onClose={() => setLive(false)}
        />
      )}
    </>
  );
}

function LiveStatsDialog(
  { draft, game, onClose }: {
    draft: Snapshot;
    game: Game;
    onClose: () => void;
  },
) {
  const { t } = useI18n();
  const events = draft.events.filter((event) =>
    event.game_id === game.id && !event.reverted
  );
  const teams = [game.home_id, game.away_id];
  return (
    <div className="liveStatsBackdrop">
      <section
        className="liveStatsDialog"
        role="dialog"
        aria-modal="true"
        aria-label={t("Live statistics")}
      >
        <header>
          <div>
            <span>{t("Real-Time Stats")}</span>
            <h2>{game.home_score} – {game.away_score}</h2>
          </div>
          <button aria-label={t("Close live statistics")} onClick={onClose}>
            ×
          </button>
        </header>
        <div className="liveStatsTeams">
          {teams.map((teamId, index) => {
            const team = draft.teams.find((item) => item.id === teamId);
            const players = draft.players.filter((player) =>
              player.team_id === teamId
            ).sort(comparePlayers);
            const teamEvents = events.filter((event) =>
              event.team_id === teamId
            );
            const unassignedEvents = teamEvents.filter((event) => event.player_id === null && event.type !== "VIDEO");
            return (
              <section key={teamId}>
                <h3>{index === 0 ? t("Home") : t("Away")} · {team?.name}</h3>
                <div className="tableWrap">
                  <table>
                    <thead>
                      <tr>
                        <th>{t("Player")}</th>
                        {statColumns.map(([, label]) => (
                          <th key={label}>{label}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {players.map((player) => {
                        const playerEvents = events.filter((event) =>
                          event.player_id === player.id
                        );
                        return (
                          <tr key={player.id}>
                            <td>
                              #{player.number || "—"} <b>{player.name}</b>
                            </td>
                            {statColumns.map(([type, label]) => (
                              <td data-label={label} key={type}>
                                {type === "PTS" ? points(playerEvents) : statValue(playerEvents, type)}
                              </td>
                            ))}
                          </tr>
                        );
                      })}
                      {unassignedEvents.length > 0 && (
                        <tr>
                          <td>{t("Unassigned")}</td>
                          {statColumns.map(([type, label]) => (
                            <td data-label={label} key={type}>
                              {type === "PTS" ? points(unassignedEvents) : statValue(unassignedEvents, type)}
                            </td>
                          ))}
                        </tr>
                      )}
                      <tr className="total">
                        <td>{t("Team Total")}</td>
                        {statColumns.map(([type, label]) => (
                          <td data-label={label} key={type}>
                            {type === "PTS" ? points(teamEvents) : statValue(teamEvents, type)}
                          </td>
                        ))}
                      </tr>
                    </tbody>
                  </table>
                </div>
              </section>
            );
          })}
        </div>
      </section>
    </div>
  );
}

function LiveGame(
  { game: initial, data, onChange, onSave, onClose }: {
    game: Game;
    data: Snapshot;
    onChange: (data: Snapshot) => void;
    onSave: (data: Snapshot) => Promise<void>;
    onClose: () => void;
  },
) {
  const { t } = useI18n();
  const [draft, setDraft] = useState(data);
  const draftRef = useRef(data);
  const game = draft.games.find((g) => g.id === initial.id)!;
  const [running, setRunning] = useState(false);
  const [recording, setRecording] = useState(false);
  const video = useRef<HTMLVideoElement>(null);
  const recorder = useRef<MediaRecorder | null>(null);
  const chunks = useRef<Blob[]>([]);
  const recordedDuration = useRef(0);
  const videoElapsed = useRef(0);
  const actionClock = useRef(0);
  const [showStats, setShowStats] = useState(false);
  const [mode, setMode] = useState<CaptureMode>("score");
  const [picker, setPicker] = useState<
    {
      title: string;
      options: { id: string; label: string; group?: string }[];
      selected: string[];
      multiple: boolean;
      max: number;
      optional: boolean;
    } | null
  >(null);
  const [freeThrowEntry, setFreeThrowEntry] = useState<{
    teamId: number;
    shooter: Player;
    format: FreeThrowFormat;
    results: FreeThrowResult[];
  } | null>(null);
  const [substitutionEntry, setSubstitutionEntry] = useState<{
    teamId: number;
    initialIds: number[];
    selectedIds: number[];
  } | null>(null);
  const pickerResolve = useRef<((ids: string[]) => void) | null>(null);
  const teams = [{ id: game.home_id, side: "home" as const }, {
    id: game.away_id,
    side: "away" as const,
  }];
  const updateDraft = (recipe: (current: Snapshot) => Snapshot) =>
    setDraft((current) => {
      const next = recipe(current);
      draftRef.current = next;
      return next;
    });
  const nextActionTime = () => {
    actionClock.current = Math.max(Date.now(), actionClock.current + 1);
    return actionClock.current;
  };
  const pick = (
    title: string,
    options: { id: string; label: string; group?: string }[],
    multiple = false,
    max = 1,
    optional = false,
  ) =>
    new Promise<string[]>((resolve) => {
      pickerResolve.current = resolve;
      setPicker({ title, options, selected: [], multiple, max, optional });
    });
  const teamLabel = (teamId: number) =>
    teamId === game.home_id
      ? t("HOME · {name}", { name: draft.teams.find((team) => team.id === teamId)?.name ?? t("Home Team") })
      : t("AWAY · {name}", { name: draft.teams.find((team) => team.id === teamId)?.name ?? t("Away Team") });
  const gamePlayers = () =>
    draft.players.filter((player) =>
      player.team_id === game.home_id || player.team_id === game.away_id
    );
  const pickPlayers = async (
    title: string,
    players: Player[],
    multiple = false,
    max = 1,
    optional = false,
  ) => {
    const eligible = players.filter((player) =>
      player.team_id === game.home_id || player.team_id === game.away_id
    ).sort(comparePlayers);
    const ids = await pick(
      title,
      eligible.map((player) => ({
        id: String(player.id),
        label: playerSelectionLabel(player, eligible),
        group: teamLabel(player.team_id),
      })),
      multiple,
      max,
      optional,
    );
    return ids.map((id) => eligible.find((player) => player.id === Number(id)))
      .filter((player): player is Player => Boolean(player));
  };
  const closePicker = (ids: string[] = []) => {
    pickerResolve.current?.(ids);
    pickerResolve.current = null;
    setPicker(null);
  };
  const togglePickerOption = (id: string) =>
    setPicker((current) => {
      if (!current) return current;
      if (!current.multiple) return { ...current, selected: [id] };
      const selected = current.selected.includes(id)
        ? current.selected.filter((value) => value !== id)
        : current.selected.length < current.max
        ? [...current.selected, id]
        : current.selected;
      return { ...current, selected };
    });
  useEffect(() => {
    if (!running || game.clock_remaining_ms <= 0) return;
    const timer = setInterval(
      () =>
        updateDraft((d) => ({
          ...d,
          games: d.games.map((g) =>
            g.id === game.id
              ? {
                ...g,
                status: "RECORDING",
                clock_remaining_ms: Math.max(0, g.clock_remaining_ms - 1000),
              }
              : g
          ),
        })),
      1000,
    );
    return () => clearInterval(timer);
  }, [running, game.id, game.clock_remaining_ms]);
  useEffect(() => {
    onChange(draft);
  }, [draft, onChange]);
  const addEvent = (
    teamId: number,
    player: Player | null,
    type: string,
    value: number,
    score = 0,
    actionTime = nextActionTime(),
    relatedPlayerId: number | null = null,
  ) =>
    updateDraft((d) => {
      const segmentTime = recording ? Math.round(recordedDuration.current) : 0;
      const event: StatEvent = {
        id: nextId(d.events),
        game_id: game.id,
        team_id: teamId,
        player_id: player?.id ?? null,
        related_player_id: relatedPlayerId,
        type,
        value,
        period: game.current_period,
        game_clock_ms: game.clock_remaining_ms,
        segment: recording
          ? d.segments.filter((s) => s.game_id === game.id).length + 1
          : 0,
        segment_time_ms: segmentTime,
        final_video_time_ms: Math.round(videoElapsed.current + segmentTime),
        reverted: 0,
        created_at: actionTime,
      };
      return {
        ...d,
        events: [...d.events, event],
        games: d.games.map((g) =>
          g.id === game.id
            ? {
              ...g,
              home_score: g.home_score + (teamId === g.home_id ? score : 0),
              away_score: g.away_score + (teamId === g.away_id ? score : 0),
            }
            : g
        ),
      };
    });
  async function score(teamId: number, amount: number) {
    if (mode !== "full") {
      addEvent(teamId, null, `PTS_${amount}`, amount, amount);
      return;
    }
    const actionTime = nextActionTime();
    const roster = draft.players.filter((p) => p.team_id === teamId);
    const [scorer] = await pickPlayers(t("Who made this {amount}-point shot?", { amount }), roster);
    if (!scorer) return;
    if (amount > 1) {
      const [assist] = await pickPlayers(
        t("Who made the assist? (Optional)"),
        roster.filter((p) => p.id !== scorer.id),
        false,
        1,
        true,
      );
      if (assist) addEvent(teamId, assist, "AST", 1, 0, actionTime);
    }
    addEvent(teamId, scorer, `PTS_${amount}`, amount, amount, actionTime);
  }
  async function miss(teamId: number, amount: number) {
    const actionTime = nextActionTime();
    const [shooter] = await pickPlayers(
      t("Who took this shot?"),
      draft.players.filter((p) => p.team_id === teamId),
    );
    if (!shooter) return;
    const [rebounder] = await pickPlayers(
      t("Who got the rebound? (Optional)"),
      gamePlayers(),
      false,
      1,
      true,
    );
    addEvent(teamId, shooter, `MISS_${amount}`, amount, 0, actionTime);
    if (rebounder) addEvent(rebounder.team_id, rebounder, "REB", 1, 0, actionTime);
  }
  async function freeThrow(teamId: number) {
    const [shooter] = await pickPlayers(
      t("Who is shooting the free throw?"),
      draft.players.filter((p) => p.team_id === teamId),
    );
    if (shooter) {
      setFreeThrowEntry({ teamId, shooter, format: "2", results: [null, null] });
    }
  }
  function selectFreeThrowFormat(format: FreeThrowFormat) {
    setFreeThrowEntry((current) =>
      current
        ? {
          ...current,
          format,
          results: Array<FreeThrowResult>(format === "1+1" ? 2 : Number(format))
            .fill(null),
        }
        : current
    );
  }
  function selectFreeThrowResult(
    attempt: number,
    result: Exclude<FreeThrowResult, null>,
  ) {
    setFreeThrowEntry((current) => {
      if (!current) return current;
      const results = [...current.results];
      results[attempt] = result;
      if (current.format === "1+1" && attempt === 0 && result === "missed") {
        results[1] = null;
      }
      return { ...current, results };
    });
  }
  async function saveFreeThrows() {
    if (!freeThrowEntry) return;
    const entry = freeThrowEntry;
    const awarded = entry.format === "1+1" &&
        entry.results[0] === "missed"
      ? 1
      : entry.results.length;
    const results = entry.results.slice(0, awarded);
    if (results.some((result) => result === null)) return;
    const actionTime = nextActionTime();
    results.forEach((result) =>
      addEvent(
        entry.teamId,
        entry.shooter,
        result === "made" ? "FT_MADE" : "FT_MISS",
        1,
        result === "made" ? 1 : 0,
        actionTime,
      )
    );
    setFreeThrowEntry(null);
    if (results.at(-1) === "missed") {
      const [rebounder] = await pickPlayers(t("Who got the rebound?"), gamePlayers());
      if (rebounder) addEvent(rebounder.team_id, rebounder, "REB", 1, 0, actionTime);
    }
  }
  async function stat(teamId: number, type: string, title: string) {
    const [player] = await pickPlayers(
      t("Who recorded this {stat}?", { stat: t(title).toLowerCase() }),
      draft.players.filter((p) => p.team_id === teamId),
    );
    if (player) addEvent(teamId, player, type, 1);
  }
  async function starters(teamId: number) {
    const roster = draft.players.filter((p) => p.team_id === teamId);
    const selected = await pickPlayers(t("Select Starting Players"), roster, true, 5);
    selected.forEach((player) => addEvent(teamId, player, "STARTER", 1));
  }
  function substitute(teamId: number) {
    const lineup = new Set<number>();
    draft.events.filter((event) =>
      event.game_id === game.id && event.team_id === teamId && !event.reverted
    ).sort((a, b) => a.id - b.id).forEach((event) => {
      if (!event.player_id) return;
      if (event.type === "STARTER" || event.type === "SUB_IN") {
        lineup.add(event.player_id);
      } else if (event.type === "SUB_OUT") {
        lineup.delete(event.player_id);
      } else if (event.type === "SUBSTITUTION") {
        lineup.delete(event.player_id);
        if (event.related_player_id) lineup.add(event.related_player_id);
      }
    });
    const initialIds = [...lineup];
    setSubstitutionEntry({ teamId, initialIds, selectedIds: initialIds });
  }
  function saveSubstitution() {
    if (!substitutionEntry) return;
    const outgoingIds = substitutionEntry.initialIds.filter((id) =>
      !substitutionEntry.selectedIds.includes(id)
    );
    const incomingIds = substitutionEntry.selectedIds.filter((id) =>
      !substitutionEntry.initialIds.includes(id)
    );
    if (outgoingIds.length !== 1 || incomingIds.length !== 1) return;
    const outgoing = draft.players.find((player) => player.id === outgoingIds[0]);
    const incoming = draft.players.find((player) => player.id === incomingIds[0]);
    if (!outgoing || !incoming) return;
    const actionTime = nextActionTime();
    addEvent(substitutionEntry.teamId, outgoing, "SUBSTITUTION", 1, 0, actionTime, incoming.id);
    setSubstitutionEntry(null);
  }
  function undo() {
    const current = draftRef.current;
    const last = [...current.events].reverse().find((e) =>
      e.game_id === game.id && !e.reverted
    );
    if (!last) return;
    const grouped = current.events.filter((e) =>
      e.game_id === game.id && !e.reverted && e.created_at === last.created_at
    );
    const groupedIds = new Set(grouped.map((e) => e.id));
    const homePoints = grouped.filter((e) => e.team_id === game.home_id && (e.type.startsWith("PTS_") || e.type === "FT_MADE")).reduce((sum, e) => sum + e.value, 0);
    const awayPoints = grouped.filter((e) => e.team_id === game.away_id && (e.type.startsWith("PTS_") || e.type === "FT_MADE")).reduce((sum, e) => sum + e.value, 0);
    const next = {
      ...current,
      events: current.events.map((e) =>
        groupedIds.has(e.id) ? { ...e, reverted: 1 } : e
      ),
      games: current.games.map((g) =>
        g.id === game.id
          ? {
            ...g,
            home_score: Math.max(
              0,
              g.home_score - homePoints,
            ),
            away_score: Math.max(
              0,
              g.away_score - awayPoints,
            ),
          }
          : g
      ),
    };
    draftRef.current = next;
    setDraft(next);
  }
  async function toggleRecording() {
    if (recording) {
      const media = recorder.current;
      if (media) {
        const stopped = new Promise<void>((resolve) =>
          media.addEventListener("stop", () => resolve(), { once: true })
        );
        media.stop();
        media.stream.getTracks().forEach((t) => t.stop());
        await stopped;
      }
      setRecording(false);
      return;
    }
    try {
      const dimensions: Record<string, MediaTrackConstraints | boolean> = {
        UHD: { width: { ideal: 3840 }, height: { ideal: 2160 } },
        FHD: { width: { ideal: 1920 }, height: { ideal: 1080 } },
        HD: { width: { ideal: 1280 }, height: { ideal: 720 } },
        SD: { width: { ideal: 640 }, height: { ideal: 480 } },
        HIGHEST: true,
      };
      const stream = await navigator.mediaDevices.getUserMedia({
        video: dimensions[game.video_quality] ?? true,
        audio: true,
      });
      if (video.current) video.current.srcObject = stream;
      chunks.current = [];
      recordedDuration.current = 0;
      const media = new MediaRecorder(stream);
      recorder.current = media;
      media.ondataavailable = (e) => {
        chunks.current.push(e.data);
        recordedDuration.current = Math.max(
          recordedDuration.current,
          e.timecode,
        );
      };
      media.onstop = () => {
        const duration = recordedDuration.current;
        videoElapsed.current += duration;
        const current = draftRef.current;
        const sequence = current.segments.filter((s) =>
          s.game_id === game.id
        ).length + 1;
        const filename = `HoopReplay_${game.id}_${sequence}.webm`;
        download(
          filename,
          new Blob(chunks.current, { type: media.mimeType }),
          media.mimeType,
        );
        const next = {
          ...current,
          segments: [...current.segments, {
            id: nextId(current.segments),
            game_id: game.id,
            sequence,
            uri: `download:${filename}`,
            duration_ms: Math.round(duration),
            created_at: game.created_at + sequence,
          }],
        };
        draftRef.current = next;
        setDraft(next);
      };
      media.start(1000);
      setRecording(true);
    } catch {
      alert(t("Camera or microphone access was denied. Grant permission and try again."));
    }
  }
  async function finish(status: string) {
    setRunning(false);
    if (recording) await toggleRecording();
    const current = draftRef.current;
    const next = {
      ...current,
      games: current.games.map((g) => g.id === game.id ? { ...g, status } : g),
    };
    draftRef.current = next;
    setDraft(next);
    onChange(next);
    await onSave(next);
    onClose();
  }
  return (
    <div className="liveOverlay">
      <video ref={video} autoPlay muted playsInline />
      <div className="liveTop">
        <div className="liveScoreTeam home">
          <span>{t("Home")}</span>
          <strong>
            {draft.teams.find((team) => team.id === game.home_id)?.name}
          </strong>
          <b className="liveScore" aria-label={t("Home score")}>{game.home_score}</b>
        </div>
        <div className="liveClock">
          <span className={`recordingState ${recording ? "isRecording" : ""}`}>{recording ? t("● Rec") : t("Not Recording")}</span>
          <strong>Q{game.current_period}</strong>
          <b>{formatClock(game.clock_remaining_ms)}</b>
        </div>
        <div className="liveScoreTeam away">
          <span>{t("Away")}</span>
          <strong>
            {draft.teams.find((team) => team.id === game.away_id)?.name}
          </strong>
          <b className="liveScore" aria-label={t("Away score")}>{game.away_score}</b>
        </div>
      </div>
      <div className="modePicker" aria-label={t("Capture mode")}>
        <button className={mode === "record" ? "active" : ""} onClick={() => setMode("record")}>{t("Record Only")}</button>
        <button className={mode === "score" ? "active" : ""} onClick={() => setMode("score")}>{t("Score + Record")}</button>
        <button className={mode === "full" ? "active" : ""} onClick={() => setMode(mode === "full" ? "score" : "full")}>{mode === "full" ? t("Score Mode") : t("Stat Mode")}</button>
      </div>
      {mode !== "record" && (
      <div className="liveTeams">
        {teams.map((team) => (
          <section key={team.id}>
            <h3>{t(titleCase(team.side))}</h3>
            {mode === "full" && <div className="lineupKeys">
              <button onClick={() => starters(team.id)}>{t("Set Lineup")}</button>
              <button onClick={() => substitute(team.id)}>{t("Substitute")}</button>
            </div>}
            <div className="scoreKeys">
              {mode !== "full" && <>
                <button onClick={() => score(team.id, 1)}>+1</button>
                <button onClick={() => score(team.id, 2)}>+2</button>
                <button onClick={() => score(team.id, 3)}>+3</button>
              </>}
              {mode === "full" && <>
                <button onClick={() => miss(team.id, 2)}>{t("Miss 2")}</button>
                <button onClick={() => miss(team.id, 3)}>{t("Miss 3")}</button>
              </>}
            </div>
            {mode === "full" && <>
            <div className="statKeys">
              {statActionButtons.map(([type, title]) => (
                <button
                  key={type}
                  className={type === "PTS_2" || type === "PTS_3" ? "made" : type === "FT" ? "freeThrow" : ""}
                  onClick={() => type === "FT"
                    ? freeThrow(team.id)
                    : type === "PTS_2" || type === "PTS_3"
                    ? score(team.id, type === "PTS_2" ? 2 : 3)
                    : stat(team.id, type, title)}
                >
                  {t(title)}
                </button>
              ))}
            </div>
            </>}
          </section>
        ))}
      </div>
      )}
      {draft.events.some((e) => e.game_id === game.id && !e.reverted) && (() => {
        const last = [...draft.events].reverse().find((e) => e.game_id === game.id && !e.reverted)!;
        const player = last.player_id ? draft.players.find((p) => p.id === last.player_id) : null;
        return <div className="lastAction"><span>{player ? `#${player.number || "—"} ${player.name} · ` : ""}{t(eventLabel(last.type))}</span><button onClick={undo}>{t("Undo")}</button></div>;
      })()}
      <div className="liveControls">
        <button className="primary" onClick={() => setRunning(!running)}>
          {running ? t("Pause clock") : t("Start clock")}
        </button>
        <button className={recording ? "danger" : ""} onClick={toggleRecording}>
          {recording ? t("Stop & download video") : t("Record video")}
        </button>
        <button onClick={() => setShowStats(true)}>{t("Live stats")}</button>
        <button
          disabled={game.current_period >= game.period_count}
          onClick={() =>
            updateDraft((d) => ({
              ...d,
              games: d.games.map((g) =>
                g.id === game.id
                  ? {
                    ...g,
                    current_period: g.current_period + 1,
                    clock_remaining_ms: g.period_duration_ms,
                  }
                  : g
              ),
            }))}
        >
          {t("Next period")}
        </button>
        <button onClick={() => finish("PAUSED")}>{t("Save & exit")}</button>
        <button className="danger" onClick={() => finish("COMPLETED")}>
          {t("End")}
        </button>
      </div>
      {showStats && (
        <LiveStatsDialog
          draft={draft}
          game={game}
          onClose={() => setShowStats(false)}
        />
      )}
      {substitutionEntry && (() => {
        const roster = draft.players.filter((player) =>
          player.team_id === substitutionEntry.teamId
        ).sort(comparePlayers);
        const team = draft.teams.find((item) =>
          item.id === substitutionEntry.teamId
        );
        const outgoingIds = substitutionEntry.initialIds.filter((id) =>
          !substitutionEntry.selectedIds.includes(id)
        );
        const incomingIds = substitutionEntry.selectedIds.filter((id) =>
          !substitutionEntry.initialIds.includes(id)
        );
        const ready = outgoingIds.length === 1 && incomingIds.length === 1;
        return (
          <div className="playerPickerBackdrop">
            <section
              className="playerPicker substitutionDialog"
              role="dialog"
              aria-modal="true"
              aria-label={t("Record substitution")}
            >
              <header>
                <div>
                  <span>{t("Substitution · {team}", { team: team?.name ?? "" })}</span>
                  <h2>{t("Select Players on Court")}</h2>
                </div>
                <button
                  aria-label={t("Cancel substitution")}
                  onClick={() => setSubstitutionEntry(null)}
                >×</button>
              </header>
              <div className="substitutionRoster">
                <p>{t("Selected players are on the court. Deselect the outgoing player, then select the incoming player.")}</p>
                <div className="playerTags" aria-label={t("Team lineup")}>
                  {roster.map((player) => {
                    const selected = substitutionEntry.selectedIds.includes(player.id);
                    return <button
                      key={player.id}
                      className={selected ? "selected" : ""}
                      aria-pressed={selected}
                      onClick={() => setSubstitutionEntry((current) =>
                        current
                          ? {
                            ...current,
                            selectedIds: current.selectedIds.includes(player.id)
                              ? current.selectedIds.filter((id) => id !== player.id)
                              : [...current.selectedIds, player.id],
                          }
                          : current)}
                    >{playerSelectionLabel(player, roster)}</button>;
                  })}
                </div>
              </div>
              <footer>
                <span>{ready
                  ? t("1 player out · 1 player in")
                  : t("{count} players on court", { count: substitutionEntry.selectedIds.length })}</span>
                <div>
                  <button onClick={() => setSubstitutionEntry(null)}>{t("Cancel")}</button>
                  <button
                    className="primary"
                    disabled={!ready}
                    onClick={saveSubstitution}
                  >{t("Record Substitution")}</button>
                </div>
              </footer>
            </section>
          </div>
        );
      })()}
      {freeThrowEntry && (
        <div className="playerPickerBackdrop">
          <section
            className="playerPicker freeThrowDialog"
            role="dialog"
            aria-modal="true"
            aria-label={t("Record free throws")}
          >
            <header>
              <div>
                <span>{t("Free Throw")}</span>
                <h2>
                  #{freeThrowEntry.shooter.number || "—"} {freeThrowEntry.shooter.name}
                </h2>
              </div>
              <button
                aria-label={t("Cancel free throws")}
                onClick={() => setFreeThrowEntry(null)}
              >
                ×
              </button>
            </header>
            <div className="freeThrowEditor">
              <section>
                <h3>{t("Number of Free Throws")}</h3>
                <div className="freeThrowFormats">
                  {(["1+1", "1", "2", "3"] as FreeThrowFormat[]).map((format) => (
                    <button
                      key={format}
                      className={freeThrowEntry.format === format ? "selected" : ""}
                      aria-pressed={freeThrowEntry.format === format}
                      onClick={() => selectFreeThrowFormat(format)}
                    >
                      {format}
                    </button>
                  ))}
                </div>
              </section>
              <section>
                <h3>{t("Free Throw Results")}</h3>
                <div className="freeThrowAttempts">
                  {freeThrowEntry.results.map((result, index) => {
                    const notAwarded = freeThrowEntry.format === "1+1" &&
                      index === 1 && freeThrowEntry.results[0] !== "made";
                    return (
                      <div
                        className={`freeThrowAttempt ${notAwarded ? "notAwarded" : ""}`}
                        aria-label={t("Free throw {number}", { number: index + 1 })}
                        key={index}
                      >
                        <strong>{t("Free Throw {number}", { number: index + 1 })}</strong>
                        {notAwarded
                          ? (
                            <span>
                              {freeThrowEntry.results[0] === "missed"
                                ? t("Not awarded")
                                : t("Awarded after the first is made")}
                            </span>
                          )
                          : (
                            <div>
                              <button
                                className={result === "missed" ? "selected missed" : ""}
                                onClick={() => selectFreeThrowResult(index, "missed")}
                              >
                                <b>×</b> {t("Missed")}
                              </button>
                              <button
                                className={result === "made" ? "selected made" : ""}
                                onClick={() => selectFreeThrowResult(index, "made")}
                              >
                                <b>✓</b> {t("+1 Point")}
                              </button>
                            </div>
                          )}
                      </div>
                    );
                  })}
                </div>
              </section>
            </div>
            <footer>
              <span>
                {t("{count} results selected", { count: freeThrowEntry.results.filter(Boolean).length })}
              </span>
              <div>
                <button onClick={() => setFreeThrowEntry(null)}>{t("Cancel")}</button>
                <button
                  className="primary"
                  disabled={freeThrowEntry.results.slice(
                    0,
                    freeThrowEntry.format === "1+1" &&
                        freeThrowEntry.results[0] === "missed"
                      ? 1
                      : freeThrowEntry.results.length,
                  ).some((result) => result === null)}
                  onClick={saveFreeThrows}
                >
                  {t("Record Free Throws")}
                </button>
              </div>
            </footer>
          </section>
        </div>
      )}
      {picker && (
        <div className="playerPickerBackdrop">
          <section
            className="playerPicker"
            role="dialog"
            aria-modal="true"
            aria-label={picker.title}
          >
            <header>
              <div>
                <span>{t("Select Players")}</span>
                <h2>{picker.title}</h2>
              </div>
              <button
                aria-label={t("Cancel selection")}
                onClick={() => closePicker()}
              >
                ×
              </button>
            </header>
            <div className="playerGroups">
              {[
                ...new Set(
                  picker.options.map((option) => option.group ?? t("Options")),
                ),
              ].map((group) => (
                <section className="playerGroup" key={group}>
                  <h3>{group}</h3>
                  <div className="playerTags">
                    {picker.options.filter((option) =>
                      (option.group ?? t("Options")) === group
                    ).map((option) => (
                      <button
                        key={option.id}
                        className={picker.selected.includes(option.id)
                          ? "selected"
                          : ""}
                        aria-pressed={picker.selected.includes(option.id)}
                        onClick={() => togglePickerOption(option.id)}
                      >
                        {option.label}
                      </button>
                    ))}
                  </div>
                </section>
              ))}
            </div>
            <footer>
              <span>
                {picker.multiple
                  ? t("{selected} / {max} selected", { selected: picker.selected.length, max: picker.max })
                  : picker.selected.length
                  ? t("1 player selected")
                  : picker.optional
                  ? t("Optional")
                  : t("Select 1 player")}
              </span>
              <div>
                <button onClick={() => closePicker()}>{t("Cancel")}</button>
                {picker.optional && (
                  <button
                    className="skip"
                    onClick={() => closePicker()}
                  >
                    {t("Skip")}
                  </button>
                )}
                <button
                  className="primary"
                  disabled={picker.selected.length === 0}
                  onClick={() => closePicker(picker.selected)}
                >
                  {t("Confirm")}
                </button>
              </div>
            </footer>
          </section>
        </div>
      )}
    </div>
  );
}
