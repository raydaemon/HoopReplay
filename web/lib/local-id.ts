import { deviceId } from "./device";

const saltRange = 1000;

/** Stable per-device number in [0, saltRange) that keeps two devices off each other's ids. */
function deviceSalt() {
  const id = deviceId();
  let hash = 0;
  for (let index = 0; index < id.length; index += 1) hash = (hash * 31 + id.charCodeAt(index)) % saltRange;
  return hash;
}

let lastTick = 0;

/**
 * Allocates the device-local integer id for a new row.
 *
 * `max(existing) + 1` looks obvious and is wrong across devices: two devices that loaded the same
 * data both pick the same number for different rows, and whichever saves last silently replaces the
 * other's row. Deriving the id from the clock and a per-device salt keeps every device in its own
 * lane while the ids stay sortable by creation order.
 */
export function nextId(rows: { id: number }[]) {
  const highest = rows.reduce((most, row) => Math.max(most, row.id), 0);
  const tick = Math.max(Date.now(), Math.floor(highest / saltRange) + 1, lastTick + 1);
  lastTick = tick;
  return tick * saltRange + deviceSalt();
}
