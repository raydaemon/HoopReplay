import type { User } from "@supabase/supabase-js";

/** Prefers the name the account chose; falls back to a readable form of the email. */
export function accountLabel(user: User | null) {
  const meta = (user?.user_metadata ?? {}) as Record<string, unknown>;
  for (const key of ["display_name", "full_name", "name"]) {
    const value = meta[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  const local = user?.email?.split("@")[0] ?? "";
  return local
    ? local.replace(/[._-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase())
    : "Coach";
}

export function initials(name?: string) {
  if (!name) return "?";
  return name.trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("")
    .toUpperCase();
}
