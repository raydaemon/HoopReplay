"use client";

import { useCallback, useMemo, useState } from "react";
import { DndContext, PointerSensor, closestCenter, useSensor, useSensors, type DragEndEvent } from "@dnd-kit/core";
import { SortableContext, arrayMove, horizontalListSortingStrategy, useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { Columns3 } from "lucide-react";
import { useI18n } from "@/lib/i18n";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { TableHead } from "@/components/ui/table";

export type ColumnVisibilityState = Record<string, boolean>;

/** What a table needs from the layout: the TanStack state plus the callbacks that persist it. */
export type ColumnLayout = {
  columnOrder: string[];
  columnVisibility: ColumnVisibilityState;
  onColumnOrderChange: (updater: string[] | ((old: string[]) => string[])) => void;
  onColumnVisibilityChange: (updater: ColumnVisibilityState | ((old: ColumnVisibilityState) => ColumnVisibilityState)) => void;
  reset: () => void;
};

type Stored = { order?: string[]; visibility?: ColumnVisibilityState };

const storageName = (key: string) => `hoopreplay:columns:${key}`;

function readStored(key: string): Stored {
  if (typeof window === "undefined") return {};
  try {
    const raw = window.localStorage.getItem(storageName(key));
    if (!raw) return {};
    const parsed = JSON.parse(raw) as unknown;
    // Older builds stored the order alone as a bare array.
    if (Array.isArray(parsed)) return { order: parsed as string[] };
    return (parsed ?? {}) as Stored;
  } catch { return {}; }
}

function writeStored(key: string, value: Stored) {
  try { window.localStorage.setItem(storageName(key), JSON.stringify(value)); } catch { /* storage unavailable */ }
}

/**
 * Keeps the saved order in sync with the current columns: drops unknown ids and slots new ones in
 * at their default position (right after the nearest default predecessor the user still has).
 */
const reconcileOrder = (saved: string[] | undefined, ids: string[]) => {
  if (!saved) return ids;
  const next = saved.filter((id) => ids.includes(id));
  ids.forEach((id, index) => {
    if (next.includes(id)) return;
    const before = ids.slice(0, index).reverse().find((candidate) => next.includes(candidate));
    next.splice(before ? next.indexOf(before) + 1 : 0, 0, id);
  });
  return next;
};

/**
 * Column order and visibility for one table, persisted under `storageKey` so the layout survives
 * reloads. Share the returned object between tables that must stay in step (for example the two
 * team box scores on a game page).
 */
export function useColumnLayout(storageKey: string, columnIds: string[]): ColumnLayout {
  const idsKey = columnIds.join(" ");
  const ids = useMemo(() => idsKey ? idsKey.split(" ") : [], [idsKey]);
  const [columnOrder, setColumnOrder] = useState<string[]>(() => reconcileOrder(readStored(storageKey).order, ids));
  const [columnVisibility, setColumnVisibility] = useState<ColumnVisibilityState>(() => readStored(storageKey).visibility ?? {});

  const persist = useCallback((next: Stored) => {
    writeStored(storageKey, { ...readStored(storageKey), ...next });
  }, [storageKey]);

  const onColumnOrderChange = useCallback<ColumnLayout["onColumnOrderChange"]>((updater) => {
    setColumnOrder((old) => {
      const next = typeof updater === "function" ? updater(old) : updater;
      persist({ order: next });
      return next;
    });
  }, [persist]);

  const onColumnVisibilityChange = useCallback<ColumnLayout["onColumnVisibilityChange"]>((updater) => {
    setColumnVisibility((old) => {
      const next = typeof updater === "function" ? updater(old) : updater;
      persist({ visibility: next });
      return next;
    });
  }, [persist]);

  const reset = useCallback(() => {
    setColumnOrder(ids);
    setColumnVisibility({});
    try { window.localStorage.removeItem(storageName(storageKey)); } catch { /* storage unavailable */ }
  }, [ids, storageKey]);

  return useMemo(() => ({
    columnOrder: reconcileOrder(columnOrder, ids),
    columnVisibility,
    onColumnOrderChange,
    onColumnVisibilityChange,
    reset,
  }), [columnOrder, columnVisibility, ids, onColumnOrderChange, onColumnVisibilityChange, reset]);
}

/** The subset of a TanStack column the chooser needs, so it works with both table APIs. */
export type ChoosableColumn = {
  id: string;
  label: string;
  visible: boolean;
  canHide: boolean;
  toggle: () => void;
};

/**
 * The "Columns" menu: a shadcn/ui dropdown listing every column in its current order, with
 * checkboxes to show or hide it and a reset that restores the default layout.
 */
export function ColumnChooser({ columns, onReset, className }: { columns: ChoosableColumn[]; onReset: () => void; className?: string }) {
  const { t } = useI18n();
  const hidden = columns.filter((column) => !column.visible).length;
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button type="button" variant="outline" size="xs" className={`gap-1 ${className ?? ""}`} aria-label={t("Choose columns")}>
          <Columns3 className="size-3.5" />
          {t("Columns")}{hidden > 0 && <span className="text-muted-foreground">{t("({count} hidden)", { count: hidden })}</span>}
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="max-h-80 overflow-y-auto">
        <DropdownMenuLabel>{t("Show columns")}</DropdownMenuLabel>
        <DropdownMenuSeparator />
        {columns.map((column) => (
          <DropdownMenuCheckboxItem
            key={column.id}
            checked={column.visible}
            disabled={!column.canHide}
            onCheckedChange={() => column.toggle()}
            onSelect={(event) => event.preventDefault()}
          >
            {t(column.label)}
          </DropdownMenuCheckboxItem>
        ))}
        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={onReset}>{t("Reset layout")}</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

/** Wraps the header row so its cells can be dragged into a new order. `id` must be stable per table: dnd-kit
 *  otherwise numbers its aria-describedby ids per render, and the server and client numbers never match. */
export function ColumnDragContext({ id, columnIds, onColumnOrderChange, children }: { id: string; columnIds: string[]; onColumnOrderChange: ColumnLayout["onColumnOrderChange"]; children: React.ReactNode }) {
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }));
  const handleDragEnd = ({ active, over }: DragEndEvent) => {
    if (!over || active.id === over.id) return;
    onColumnOrderChange((current) => arrayMove(current, current.indexOf(String(active.id)), current.indexOf(String(over.id))));
  };
  return (
    <DndContext id={id} sensors={sensors} collisionDetection={closestCenter} onDragEnd={handleDragEnd}>
      <SortableContext items={columnIds} strategy={horizontalListSortingStrategy}>
        {children}
      </SortableContext>
    </DndContext>
  );
}

// dnd-kit intentionally exposes callback refs and attribute maps that React's purity lint rule
// cannot model yet; they are safe to attach during render as required by the library.
/** A shadcn/ui `TableHead` that doubles as a dnd-kit drag handle for column reordering. */
export function SortableTableHead({ columnId, className, children }: { columnId: string; className?: string; children: React.ReactNode }) {
  /* eslint-disable react-hooks/refs */
  const sortable = useSortable({ id: columnId });
  const style = { transform: CSS.Transform.toString(sortable.transform), transition: sortable.transition };
  return (
    <TableHead ref={sortable.setNodeRef} style={style} className={className}>
      <div className="inline-flex cursor-grab items-center gap-1 active:cursor-grabbing" {...sortable.attributes} {...sortable.listeners}>
        {children}
      </div>
    </TableHead>
  );
  /* eslint-enable react-hooks/refs */
}
