# HoopReplay

## Communication

- Always respond to the user in Chinese (简体中文), including progress updates, explanations, code-review findings, and final answers. This applies even when the user writes in English; code, file paths, identifiers, and commands stay unchanged.

## Dialogs

- All popup windows must keep an equal distance from every edge of the screen (uniform padding on all four sides, system bars included).
- Make popups wide enough that button labels never wrap: a button caption always stays on one line.
- Every popup window shows a Cancel (or ×) control in its top-right corner; last-step dialogs still save on pick and have no Save button, but keep the top-right Cancel.

## UI Text Casing

- Never display any word in all capitals on Web, Android, or iOS; capitalize only the first letter of each word (Title Case). No `text-transform: uppercase` / Tailwind `uppercase`, no hard-coded all-caps labels ("TEAM TOTAL", "TIME", "HOME"), and enum values such as game status must be converted to Title Case ("Completed") before display.
- Standard stat abbreviations (PTS, REB, AST, FT%) may stay as abbreviations.

## UI Stack (Web)

- UI components: shadcn/ui
- Tables: Every Web table must use TanStack Table for column definitions and data handling, including sorting, filtering, and pagination whenever applicable, and must be rendered with shadcn/ui Table components.
- Table columns: Every Web table must let the user show/hide columns and reorder them. Use TanStack Table's `columnVisibility` and `columnOrder` state; implement drag-and-drop column reordering with dnd-kit (`@dnd-kit/core` + `@dnd-kit/sortable`) on the header cells, and expose visibility through a shadcn/ui dropdown/checkbox menu. Persist both per table so they survive reloads.
- Delete/destructive confirmations: React dialogs (shadcn/ui `AlertDialog`), never `window.alert`/`window.confirm`

## Player Lists

- Every player list (selection grids, rosters, statistics tables, exports) shows numbered players first sorted by jersey number ascending, then players without a number sorted by first name ascending.

## Player Selection

- Player-selection buttons must all have the same height: players with a name use full-width buttons laid out 6 per row; players with only a jersey number use half-width buttons laid out 12 per row, aligned to the same 6 columns.

## Player Names

- Every place that creates or edits a player (recorder add-player rows, roster editors, team and player pages, on Android, iOS, and Web) shows separate `First Name` and `Last Name` fields next to the jersey number; never a single combined "Name" or "Player name" field.
- Storage keeps one `name` column: split on the first space when displaying, join first + last with a space when saving.

## Lineup Events

- A `STARTER` event can only happen at the start of a period: stamp it with the full period clock, never the current game clock, wherever it is written (lineup dialog, period advance, Android, iOS, Web).
- Never infer a starter from a stat. Recording a stat must not create a `STARTER`, and statistics must derive who was on the floor only from `STARTER` / `SUB_IN` / `SUB_OUT` events.

## Play-by-Play Display

- The play list is a middle-aligned timeline: the away team on the left, the home team on the right, and the game clock in the middle column.
- Team headers read "Team name (Away)" / "Team name (Home)"; the side label goes after the team name, never before it.
- Each play is one compact line: the action text plus the player, with a `+N` badge on scoring plays.
- Plays are grouped by period; each group header shows the play count and the score the period ended on, and the group can be collapsed.
- Scoring plays are highlighted with a light background and an accent bar on the scoring team's side, and the running score sits under the clock.
- The list offers All / Scoring / Fouls / Away / Home filters above the timeline.
- Exported play-by-play PDFs use the same layout, and statistics PDFs print on US Letter with both teams on one page whenever they fit.

## Build, Install, and Run

- After each fix, build, install to the connected device, and test it yourself without waiting to be asked.
- After testing, leave the app parked on the screen the change affects so the user can inspect it, and send a screenshot of that screen.

## Web Test Authentication

- For authenticated Web UI tests, use the account listed in [`data/users.csv`](data/users.csv).
- Read its `email` and `password` fields and log in through the visible UI; do not invent credentials, hardcode another account, or edit the CSV.
- Authenticate before testing flows that create or edit teams, players, games, or synchronized data.

## Cloud CLI Profiles

- Supabase: the HoopReplay project is `ugpkignlnssfllfbznlq` (ConnectedAI org). Every Supabase CLI call must use the `connectedai` profile: `supabase --profile ~/.supabase/profiles/connectedai.yaml <command>` (or `scripts/supabase.sh run connectedai <command>`). Never use the bare `supabase` command or another profile; the default profile belongs to a different account and does not see this project.
- Vercel: the `hoopreplay` project (`prj_v6Au1jupOLHewIEYnbQKBKGDK7Zm`) lives in the `connected-ai` team under the user `myconnectedai`. Every Vercel CLI call must use the `connectedai` profile stored in `~/.vercel/connectedai`: `vercel --global-config ~/.vercel/connectedai --scope connected-ai <command>` (or `scripts/vercel.sh run connectedai <command>`). Never use the bare `vercel` command or another profile; `scripts/web-deploy.sh` already does this and is the only way to deploy production.

## Browser Profile

- For Chrome browser operations involving Google, Apple, Google Play Console, App Store Connect, Google Cloud Console, or Supabase, use the Conn Chrome profile signed in as `myconnectedai@gmail.com`.
- Before account operations, verify that the active browser profile is Conn and that the visible account is `myconnectedai@gmail.com`; do not use another Chrome profile.
- Paid operations, subscriptions, billing add-ons, and any action that may incur a charge must be completed manually by the user; automation may prepare the page but must never click the final purchase or enable button.

See [AGENTS.md](AGENTS.md) for UI guidelines, Android device selection rules, and the rest of the project conventions.

## Git Commits

- Never add a `Co-Authored-By` trailer (or any AI attribution line) to commit messages or PR descriptions.
- Never commit generated files (build outputs, caches such as `web/.next/`, `*.tsbuildinfo`, `node_modules/`, Gradle `build/`, Xcode `DerivedData/`). When a build or tool creates a new artifact, add it to `.gitignore` in the same change, and check `git status` before every commit.
