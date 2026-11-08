# HoopReplay UI Guidelines

## Communication

- Always respond to the user in Chinese (简体中文), including progress updates, explanations, code-review findings, and final answers. This applies even when the user writes in English; code, file paths, identifiers, and commands stay unchanged.

## Android Device Selection

- Android device scripts must use an explicitly supplied device serial when one is provided.
- When no serial is supplied and exactly one authorized Android device is connected, select it automatically.
- When multiple authorized devices are connected, read `data/devices.txt` in order and select the first listed device that is currently connected.
- Do not hardcode a device serial in scripts.
- If no authorized device is connected, or multiple devices are connected and none match `data/devices.txt`, stop with an actionable error that lists the connected devices and explains how to pass a serial explicitly.

## iOS Device Testing

- All iOS development verification, installation, launch, screenshots, and UI testing must use the connected physical iPhone 13 Pro Max by default. Do not use an iOS Simulator unless the user explicitly authorizes it for that task.
- For iOS hardware testing, prefer the connected device whose model is iPhone 13 Pro Max when it is available.
- Do not hardcode a device identifier in scripts or tests. Discover devices with `xcrun devicectl list devices` and use the currently connected device identifier returned by that command.
- Before installing, launching, or running UI tests, verify that the selected device state is `connected`, Developer Mode is enabled, and a development signing team/profile is available.
- If the iPhone 13 Pro Max is not connected, stop with an actionable error listing the connected iOS devices and explain that the device must be connected and trusted.
- Prefer `xcodebuild` with an explicit `-destination` for build/test operations and preserve screenshots or XCTest attachments as evidence.

## Web Component Libraries

- Build all Web UI with [shadcn/ui](https://ui.shadcn.com) components. Do not hand-roll buttons, inputs, dialogs, dropdowns, or other primitives that shadcn/ui already provides.
- Build every Web table with [TanStack Table](https://tanstack.com/table): define columns and use TanStack for table data handling, including sorting, filtering, and pagination whenever applicable; render the table UI exclusively through shadcn/ui Table components.
- Every Web table must support column visibility and column order. Drive both through TanStack Table state (`columnVisibility` / `onColumnVisibilityChange` and `columnOrder` / `onColumnOrderChange`), never by filtering the column array by hand. Implement drag-and-drop reordering of header cells with [dnd-kit](https://dndkit.com) (`@dnd-kit/core`, `@dnd-kit/sortable`, `@dnd-kit/utilities`, already in `web/package.json`), keeping the drag handle inside the shadcn/ui `TableHead`. Offer a column-chooser built from shadcn/ui (for example `DropdownMenuCheckboxItem`) to toggle visibility; columns that carry the row's identity or actions may be pinned as non-hideable. Persist the visibility and order per table (for example in `localStorage` keyed by table id) so a user's layout survives reloads, and reuse the shared table wrapper rather than re-implementing this per page.
- Every delete operation must require an explicit confirmation before it executes, including deletes initiated from list pages, detail pages, overflow menus, bulk actions, and platform-native UI. On Web, use a React confirmation dialog built from shadcn/ui (for example `AlertDialog`); on Android and iOS, use the platform-native confirmation dialog. Never use the browser's built-in `window.alert`, `window.confirm`, or `window.prompt`, and never perform a delete immediately from a click or tap without confirmation.

Use a light visual theme by default across Web, iOS, and Android.

- Use a light gray or off-white full-screen background with white cards and panels.
- Use dark text with strong contrast. Reserve orange for primary actions, links, status highlights, and brand accents.
- Prefer simple platform-native controls, normal system font sizes, and restrained spacing. Avoid decorative gradients, oversized headings, excessive shadows, and novelty styling.
- Keep layouts responsive. Buttons must not wrap into tall shapes, overlap content, or leave large unused areas at supported screen sizes and accessibility text settings.
- Keep primary navigation and actions easy to scan: account controls, teams and players, sync, game search, game list, and game creation.
- Recording and camera overlays may remain dark when needed for legibility over video.
- Preserve consistent information hierarchy and terminology across all three platforms, while following each platform's native interaction conventions.

## Player Lists

- Every player list — selection grids, roster pages, statistics tables, exports, and any other place players are enumerated — must show numbered players first, sorted by jersey number ascending; players without a number follow, sorted by first name ascending. Use the shared web comparator for web lists and apply the same rule on Android and iOS.

## Player Selection

- Every page or dialog that allows the user to select a player must also provide an explicit “Add player” option.
- The add-player option must add the player to the relevant team and make the new player immediately selectable on the current page.
- When both teams are eligible (for example, a rebounder), separate the teams clearly and provide an add-player option for each team.
- All player-selection buttons must share the same height, no matter which page or dialog they appear on.
- Players with a name get a full-width button, exactly 6 per row; players with only a jersey number get a half-width button, exactly 12 per row, two to a cell so they align with the same 6 columns. Keep the fixed button sizes and even spacing even when the last row is not full.

## Player Names

- Every UI that creates or edits a player — the add-player row inside recorder dialogs, the roster editor, team and player management pages, and the Web and iOS equivalents — shows separate `First Name` and `Last Name` fields alongside the jersey number. Never present a single combined "Name" or "Player name" field for creating or editing a player.
- The database keeps one `name` column because sync and exports depend on it: display an existing player by splitting the stored name on the first space, and save by joining first and last with a space, as the Android `RosterNameEditor` already does.

## Lineup Events

- A `STARTER` event marks who was on the floor when a period began, so it can only happen at the start of that period. Every writer of `STARTER` records — the Set Starting Lineup dialog, the Period/Time editor carrying the on-court five into a later period, and any Android, iOS, or Web equivalent — stamps the event with the full period clock (the period duration), never the game clock at the moment the lineup was confirmed.
- Never infer a starter from a stat. Recording a stat must not write a `STARTER` for the player, and statistics (minutes, plus/minus, on-court lineups) must derive presence on the floor only from recorded `STARTER` / `SUB_IN` / `SUB_OUT` events.

## Dialogs and Popups

- Every popup window — Compose `Dialog`, full-screen overlay panel, or any modal surface — must keep an equal distance from all four edges of the screen.
- Give the dialog frame one uniform padding value on every side instead of different horizontal and vertical insets, and account for system bars and display cutouts.
- Content that does not fit scrolls inside that frame; the frame itself never grows past the equal margin or runs off-screen.
- Size popups wide enough that no button label wraps. A caption such as "Save", "Cancel" or "Next Period" must always render on a single line; widen the dialog rather than letting the text break.
- Every popup window must show a Cancel (or ×) control in its top-right corner, including last-step dialogs that save on pick (they keep the top-right Cancel but still have no Save button). Native platform confirmation alerts (delete confirmations) keep their standard button layout.

## Recording and Scoring Input

- In scoring mode and recording mode, the system keyboard must never be opened or invoked for any user input.
- Do not use focusable text fields, editable controls, or any other interaction that can trigger the system IME in these modes.
- Use an in-app custom keypad, numeric panel, scroll wheel picker, or other application-controlled input control instead.
- Verify every input path, including player selection, game-clock editing, and adding a player, to ensure tapping it does not show the system keyboard.

## Play-by-Play Display

- The play list is a middle-aligned timeline: the away team is on the left, the home team on the right, and the game clock runs down the middle column.
- Team headers read "Team name (Away)" and "Team name (Home)". The side label always follows the team name.
- Every play is a single compact line combining the action text and the player, with a `+N` badge on plays that score.
- Group plays by period. Each period header states how many plays it holds and the score the period ended on, and tapping it collapses or expands the group.
- Highlight scoring plays with a light background plus an accent bar on the scoring team's side, and show the running score beneath the clock.
- Offer All / Scoring / Fouls / Away / Home filters above the timeline.
- Exported play-by-play PDFs follow the same left/middle/right layout. Statistics PDFs print on US Letter in landscape and keep both teams on a single page whenever the rosters fit.

## Build, Install, and Run

- After each fix, build, install to the connected device, and test it automatically without waiting to be asked.
- After testing, leave the app parked on the screen the change affects so the user can inspect it, and share a screenshot of that screen.

## Testing Rules

- Tests must simulate real user operations through the app UI only, including taps, swipes, typing into permitted controls, and system navigation.
- Never directly modify the database, app files, shared preferences, network payloads, or other internal state to manufacture a test result.
- A behavior is considered verified only when the result is produced by the same UI flow available to a user.

## Web Test Authentication

- When Web UI testing requires authentication, use the test account from [`data/users.csv`](data/users.csv).
- Read the `email` and `password` fields from `data/users.csv`; do not invent credentials, hardcode a different account, or modify the CSV.
- Log in through the visible Web UI before testing authenticated flows such as creating teams, players, games, or syncing data.

## Cloud CLI Profiles

- Supabase: the HoopReplay project is `ugpkignlnssfllfbznlq` (ConnectedAI org). Every Supabase CLI call must use the `connectedai` profile: `supabase --profile ~/.supabase/profiles/connectedai.yaml <command>` (or `scripts/supabase.sh run connectedai <command>`). Never use the bare `supabase` command or another profile; the default profile belongs to a different account and does not see this project.
- Vercel: the `hoopreplay` project (`prj_v6Au1jupOLHewIEYnbQKBKGDK7Zm`) lives in the `connected-ai` team under the user `myconnectedai`. Every Vercel CLI call must use the `connectedai` profile stored in `~/.vercel/connectedai`: `vercel --global-config ~/.vercel/connectedai --scope connected-ai <command>` (or `scripts/vercel.sh run connectedai <command>`). Never use the bare `vercel` command or another profile; `scripts/web-deploy.sh` already does this and is the only way to deploy production.

## Browser Profile

- For Chrome browser operations involving Google, Apple, Google Play Console, App Store Connect, Google Cloud Console, or Supabase, use the Conn Chrome profile signed in as `myconnectedai@gmail.com`.
- Before account operations, verify that the active browser profile is Conn and that the visible account is `myconnectedai@gmail.com`; do not use another Chrome profile.
- Paid operations, subscriptions, billing add-ons, and any action that may incur a charge must be completed manually by the user; automation may prepare the page but must never click the final purchase or enable button.

## Git Commits

- Never add a `Co-Authored-By` trailer (or any AI attribution line) to commit messages or PR descriptions.
- Never commit generated files (build outputs, caches such as `web/.next/`, `*.tsbuildinfo`, `node_modules/`, Gradle `build/`, Xcode `DerivedData/`). When a build or tool creates a new artifact, add it to `.gitignore` in the same change, and check `git status` before every commit.
