import {
  columnFilteringFeature,
  columnOrderingFeature,
  columnVisibilityFeature,
  createFilteredRowModel,
  createPaginatedRowModel,
  createSortedRowModel,
  filterFn_includesString,
  globalFilteringFeature,
  rowPaginationFeature,
  rowSortingFeature,
  sortFn_alphanumeric,
  sortFn_basic,
  sortFn_datetime,
  sortFn_text,
  tableFeatures,
} from "@tanstack/react-table";
import type { ColumnDef as TanStackColumnDef, RowData } from "@tanstack/react-table";

/**
 * The single TanStack Table feature set every HoopReplay table is built from: sorting, a global
 * search filter, pagination, and column ordering/visibility. Declared once and statically so the features and their row models
 * are shared instead of re-declared (and re-bundled) per page.
 */
export const tableFeaturesSet = tableFeatures({
  columnFilteringFeature,
  columnOrderingFeature,
  columnVisibilityFeature,
  globalFilteringFeature,
  rowPaginationFeature,
  rowSortingFeature,
  filteredRowModel: createFilteredRowModel(),
  paginatedRowModel: createPaginatedRowModel(),
  sortedRowModel: createSortedRowModel(),
  filterFns: { includesString: filterFn_includesString },
  sortFns: {
    alphanumeric: sortFn_alphanumeric,
    basic: sortFn_basic,
    datetime: sortFn_datetime,
    text: sortFn_text,
  },
  columnMeta: {} as { headClassName?: string; cellClassName?: string },
});

export type TableFeaturesSet = typeof tableFeaturesSet;

/** Column definitions for that feature set, so pages never repeat the feature generic. */
export type ColumnDef<TData extends RowData> = TanStackColumnDef<TableFeaturesSet, TData>;
