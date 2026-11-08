# HoopReplay Web Design Notes

Stable rules confirmed by screenshot review (see AGENTS.md / CLAUDE.md for the full UI conventions).

## Dashboard
- First screen at 1366×768 shows: welcome line, six KPI cards, Quick Actions, Workspace Overview, and the top of the three list cards. Nothing above the lists may grow taller than this.
- Quick Actions is one row of five stacked (icon above text) buttons down to 700px; below that it is two columns with New Game spanning both. Button titles never wrap (`white-space: nowrap`), so a new action must fit in one line at 13px within a 1366-wide layout.

## Tables
- All tables go through `components/data-table.tsx` (TanStack + shadcn Table + dnd-kit). Pass a unique `storageKey`; it keys both the persisted column layout and the dnd-kit `DndContext` id, which must be stable to avoid SSR hydration mismatches.
- Enum values (status, access role) are displayed as `t(titleCase(value))`; the Title Case key is what the i18n catalogs hold, and dynamic keys are listed in `i18n/dynamic-keys.txt`.

## Verification
- Check 390, 820, 1366×768 and 1440×900 with `document.documentElement.scrollWidth === innerWidth` and a real screenshot before calling a layout change done.
