/** Display helper: "NOT_RECORDING" / "COMPLETED" -> "Not Recording" / "Completed". */
export function titleCase(value: string | null | undefined): string {
  if (!value) return "";
  return value
    .replace(/[_-]+/g, " ")
    .split(/\s+/)
    .filter(Boolean)
    .map((word) => word[0].toUpperCase() + word.slice(1).toLowerCase())
    .join(" ");
}
