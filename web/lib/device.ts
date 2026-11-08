const storageKey = "hoopreplay.device_id";

/** Stable per-browser id so a tombstone records which device performed the deletion. */
export function deviceId() {
  if (typeof window === "undefined") return "web-unknown";
  try {
    const existing = window.localStorage.getItem(storageKey);
    if (existing) return existing;
    const created = `web-${crypto.randomUUID()}`;
    window.localStorage.setItem(storageKey, created);
    return created;
  } catch {
    // Private modes can block storage; the sync still works without a stable id.
    return "web-ephemeral";
  }
}
