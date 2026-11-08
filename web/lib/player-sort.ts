import type { Player } from "@/lib/types";
import { splitName } from "@/lib/player-name";

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

/** Numbered players first by jersey number; unnumbered players then by first name. */
export type PlayerSort = "first" | "last" | "number";
export function getPlayerSort(): PlayerSort {
  if (typeof window === "undefined") return "number";
  const value = window.localStorage.getItem("player_sort");
  return value === "first" || value === "last" || value === "number" ? value : "number";
}

export function comparePlayers(a: Player, b: Player) {
  const sort = getPlayerSort();
  const aName = splitName(a.name);
  const bName = splitName(b.name);
  if (sort === "first") return collator.compare(aName.first, bName.first) || collator.compare(a.name, b.name);
  if (sort === "last") return collator.compare(aName.last, bName.last) || collator.compare(aName.first, bName.first) || collator.compare(a.name, b.name);
  const aNumber = a.number.trim();
  const bNumber = b.number.trim();
  if (aNumber && bNumber) return collator.compare(aNumber, bNumber) || collator.compare(splitName(a.name).first, splitName(b.name).first);
  if (aNumber) return -1;
  if (bNumber) return 1;
  return collator.compare(splitName(a.name).first, splitName(b.name).first) || collator.compare(a.name, b.name);
}

export function playerSelectionLabel(player: Player, players: Player[]) {
  const name = player.name.trim();
  if (!name) return player.number ? `#${player.number}` : "—";
  const { first, last } = splitName(name);
  const sameFirst = players.filter((item) => splitName(item.name).first.localeCompare(first, undefined, { sensitivity: "base" }) === 0);
  if (sameFirst.length <= 1) return `#${player.number || "—"} ${first}`;
  if (!last) return `#${player.number || "—"} ${name}`;
  const initial = last[0].toLocaleUpperCase();
  const sameInitial = sameFirst.filter((item) => splitName(item.name).last[0]?.toLocaleUpperCase() === initial).length;
  const display = sameInitial > 1 ? name : `${first} ${initial}.`;
  return `#${player.number || "—"} ${display}`;
}
