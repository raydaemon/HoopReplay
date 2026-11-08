/**
 * The store keeps one player name column (sync and export depend on it), so the UI splits and
 * joins on the first space — the same rule the Android roster editor uses.
 */
export const splitName = (name: string) => {
  const at = name.indexOf(" ");
  return at < 0 ? { first: name, last: "" } : { first: name.slice(0, at), last: name.slice(at + 1) };
};

export const joinName = (first: string, last: string) =>
  [first.trim(), last.trim()].filter(Boolean).join(" ");
