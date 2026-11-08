let lastMs = 0;
let counter = 0;

/**
 * A new row id: a lowercase UUIDv7 (RFC 9562). Every client and the server share one global id
 * space, and the 48-bit millisecond prefix keeps ids sortable by creation order. Ids made in the
 * same millisecond bump a 12-bit counter in rand_a so they still sort in creation order.
 */
export function newId() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let ms = Date.now();
  if (ms <= lastMs) {
    counter += 1;
    if (counter > 0xfff) { lastMs += 1; counter = 0; }
    ms = lastMs;
  } else {
    lastMs = ms;
    counter = bytes[6] & 0x07; // random start, leaves room to count up
  }
  for (let index = 5; index >= 0; index -= 1) { bytes[index] = ms % 256; ms = Math.floor(ms / 256); }
  bytes[6] = 0x70 | (counter >> 8);
  bytes[7] = counter & 0xff;
  bytes[8] = 0x80 | (bytes[8] & 0x3f);
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Orders UUIDv7 ids by creation time (plain code-unit comparison, never locale collation). */
export const compareIds = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
