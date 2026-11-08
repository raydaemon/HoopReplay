"use client";

import { useMemo, useState } from "react";
import { flexRender, type RowData, type SortingState, useTable } from "@tanstack/react-table";

import { type ColumnDef, tableFeaturesSet } from "@/components/table-features";
import { ColumnChooser, ColumnDragContext, SortableTableHead, useColumnLayout } from "@/components/column-layout";
import { ArrowDown, ArrowUp, ChevronsUpDown, RefreshCw } from "lucide-react";
import { useI18n } from "@/lib/i18n";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Table,
  TableBody,
  TableCell,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

/**
 * The one table used by every resource page: TanStack Table owns sorting, filtering, paging and
 * the column order/visibility, and the shadcn/ui table primitives render the result. Column
 * headers drag into a new order and the Columns menu shows or hides them; both persist per
 * `storageKey`.
 */
export function DataTable<TData extends RowData>(
  { columns, data, searchPlaceholder = "Search…", empty = "Nothing here yet.", loading = false, pageSize = 25, toolbar, onRefresh, storageKey = "default", initialSearch = "" }: {
    columns: ColumnDef<TData>[];
    data: TData[];
    searchPlaceholder?: string;
    /** Pre-fills the search box, e.g. from the header's global search; change the `key` to apply a new one. */
    initialSearch?: string;
    empty?: string;
    /** Shows placeholder rows instead of the empty message while the data is still on its way. */
    loading?: boolean;
    pageSize?: number;
    toolbar?: React.ReactNode;
    onRefresh?: () => void;
    storageKey?: string;
  },
) {
  const { t } = useI18n();
  const [sorting, setSorting] = useState<SortingState>([]);
  const [globalFilter, setGlobalFilter] = useState(initialSearch);
  const columnIds = useMemo(() => columns.map((column) => column.id ?? ("accessorKey" in column ? String(column.accessorKey) : "")), [columns]);
  const layout = useColumnLayout(storageKey, columnIds);

  const table = useTable({
    features: tableFeaturesSet,
    data,
    columns,
    state: { sorting, globalFilter, columnOrder: layout.columnOrder, columnVisibility: layout.columnVisibility },
    onSortingChange: setSorting,
    onGlobalFilterChange: setGlobalFilter,
    onColumnOrderChange: layout.onColumnOrderChange,
    onColumnVisibilityChange: layout.onColumnVisibilityChange,
    globalFilterFn: "includesString",
    initialState: { pagination: { pageIndex: 0, pageSize } },
  });

  const rows = table.getRowModel().rows;
  const pageCount = table.getPageCount();
  const pageIndex = table.state.pagination?.pageIndex ?? 0;
  const visibleCount = table.getVisibleLeafColumns().length;
  const choosable = table.getAllLeafColumns().map((column) => ({
    id: column.id,
    label: typeof column.columnDef.header === "string" ? column.columnDef.header : column.id,
    visible: column.getIsVisible(),
    canHide: column.getCanHide(),
    toggle: () => column.toggleVisibility(),
  }));

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2 px-4">
        <Input
          value={globalFilter}
          onChange={(event) => setGlobalFilter(event.target.value)}
          placeholder={t(searchPlaceholder)}
          className="h-[27px] min-w-0 flex-1 max-w-64 py-0 text-xs"
          aria-label={t(searchPlaceholder)}
        />
        {toolbar}
        <ColumnChooser columns={choosable} onReset={layout.reset} className={toolbar || onRefresh ? "" : "ml-auto"} />
        {onRefresh && (
          <Button
            type="button"
            variant="ghost"
            size="icon-xs"
            onClick={onRefresh}
            aria-label={t("Refresh")}
            title={t("Refresh")}
          >
            <RefreshCw className="size-4" />
          </Button>
        )}
      </div>
      <ColumnDragContext id={storageKey} columnIds={layout.columnOrder} onColumnOrderChange={layout.onColumnOrderChange}>
      <Table>
        <TableHeader>
          {table.getHeaderGroups().map((group) => (
            <TableRow key={group.id} className="hover:bg-transparent">
              {group.headers.map((header) => {
                const sortable = header.column.getCanSort();
                const direction = header.column.getIsSorted();
                return (
                  <SortableTableHead key={header.id} columnId={header.column.id} className={header.column.columnDef.meta?.headClassName}>
                    {header.isPlaceholder ? null : sortable
                      ? (
                        <button
                          type="button"
                          onClick={header.column.getToggleSortingHandler()}
                          className="inline-flex min-h-0 cursor-pointer items-center gap-1 border-0 p-0 tracking-[0.1em] hover:text-foreground"
                        >
                          {typeof header.column.columnDef.header === "string" ? t(header.column.columnDef.header) : flexRender(header.column.columnDef.header, header.getContext())}
                          {direction === "asc"
                            ? <ArrowUp className="size-3" />
                            : direction === "desc"
                            ? <ArrowDown className="size-3" />
                            : <ChevronsUpDown className="size-3 opacity-40" />}
                        </button>
                      )
                      : typeof header.column.columnDef.header === "string" ? t(header.column.columnDef.header) : flexRender(header.column.columnDef.header, header.getContext())}
                  </SortableTableHead>
                );
              })}
            </TableRow>
          ))}
        </TableHeader>
        <TableBody>
          {rows.length === 0 && loading
            ? Array.from({ length: 3 }, (_, index) => (
              <TableRow key={`loading-${index}`} className="hover:bg-transparent" aria-hidden={index > 0}>
                {Array.from({ length: Math.max(visibleCount, 1) }, (_, cell) => (
                  <TableCell key={cell}>
                    {index === 0 && cell === 0 && <span className="sr-only" role="status">{t("Loading…")}</span>}
                    <span className="skeleton skeletonLine" style={{ width: `${55 + ((index * 7 + cell * 13) % 40)}%` }} />
                  </TableCell>
                ))}
              </TableRow>
            ))
            : rows.length === 0
            ? (
              <TableRow className="hover:bg-transparent">
                <TableCell colSpan={Math.max(visibleCount, 1)} className="py-8 text-center text-muted-foreground">
                  {t(empty)}
                </TableCell>
              </TableRow>
            )
            : rows.map((row) => (
              <TableRow key={row.id}>
                {row.getVisibleCells().map((cell) => (
                  <TableCell key={cell.id} className={cell.column.columnDef.meta?.cellClassName}>
                    {flexRender(cell.column.columnDef.cell, cell.getContext())}
                  </TableCell>
                ))}
              </TableRow>
            ))}
        </TableBody>
      </Table>
      </ColumnDragContext>
      {pageCount > 1 && (
        <div className="flex flex-wrap items-center justify-end gap-2 px-4 text-xs text-muted-foreground">
          <span>
            {t("Page {page} of {count}", { page: pageIndex + 1, count: pageCount })}
          </span>
          <Button
            variant="outline"
            size="xs"
            onClick={() => table.previousPage()}
            disabled={!table.getCanPreviousPage()}
          >
            {t("Previous")}
          </Button>
          <Button
            variant="outline"
            size="xs"
            onClick={() => table.nextPage()}
            disabled={!table.getCanNextPage()}
          >
            {t("Next")}
          </Button>
        </div>
      )}
    </div>
  );
}
