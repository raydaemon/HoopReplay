"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { User } from "@supabase/supabase-js";
import {
  type DeletableEntity,
  type Deletion,
  emptySnapshot,
  mergeSnapshots,
  type Snapshot,
} from "./types";
import { isConfigured, supabase } from "./supabase";
import { loadSnapshot, saveSnapshot } from "./cloud-data";
import { deviceId } from "./device";

/** Records what was deleted, when, and by which device, so other devices replay the same removal. */
export function tombstones(entity: DeletableEntity, ids: string[]): Deletion[] {
  const deleted_at = Date.now();
  const device_id = deviceId();
  return ids.map((row_id) => ({ entity, row_id, deleted_at, device_id }));
}

/** Wrapping the clock keeps the lint rule against impure calls in render bodies satisfied. */
const stamp = () => Date.now();

export function errorMessage(error: unknown, fallback: string) {
  const message = error instanceof Error
    ? error.message
    : typeof error === "object" && error && "message" in error
    ? String((error as { message: unknown }).message)
    : "";
  return message ? `${fallback}: ${message}` : fallback;
}

/**
 * Shared cloud state for the resource pages. The dashboard owns an equivalent block inline; the
 * REST pages get it as a hook so /games, /teams and /players all sync through the same rules
 * instead of each growing its own copy of the load/merge/save dance.
 */
export function useSnapshot() {
  const [data, setData] = useState<Snapshot>(emptySnapshot);
  const [user, setUser] = useState<User | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [saving, setSaving] = useState(false);
  // True once the first cloud load for the signed-in user has settled, so pages can tell an
  // empty account apart from data that has not arrived yet.
  const [loaded, setLoaded] = useState(false);
  const [status, setStatus] = useState(isConfigured ? "Connecting…" : "Setup required");
  // Bumped on every local edit so an in-flight sync can tell it is about to overwrite newer data.
  const localRevision = useRef(0);

  const reload = useCallback(async () => {
    if (!supabase || !user) return;
    setStatus("Syncing…");
    // Edits made while this request is in flight must survive it, so remember where we started.
    const startedAt = localRevision.current;
    try {
      const snapshot = await loadSnapshot(user);
      const edited = localRevision.current !== startedAt;
      setData((current) => (edited ? mergeSnapshots(current, snapshot) : snapshot));
      setStatus("Synced");
    } catch (error) {
      setStatus(errorMessage(error, "Sync failed"));
    } finally {
      setLoaded(true);
    }
  }, [user]);

  useEffect(() => {
    if (!supabase) return;
    const authTimeout = window.setTimeout(() => {
      setAuthReady(true);
      setStatus((current) => (current === "Connecting…" ? "Sign in to sync" : current));
    }, 5_000);
    supabase.auth.getUser().then(({ data }) => {
      setUser(data.user);
      if (!data.user) setStatus("Sign in to sync");
    }).finally(() => {
      clearTimeout(authTimeout);
      setAuthReady(true);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setUser(session?.user ?? null);
      setAuthReady(true);
      if (!session) {
        setData(emptySnapshot());
        setLoaded(false);
        setStatus("Sign in to sync");
      }
    });
    return () => {
      clearTimeout(authTimeout);
      listener.subscription.unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (!user) return;
    // Deferred a tick so the first sync is a reaction to sign-in rather than a render cascade.
    const initial = window.setTimeout(reload, 0);
    return () => clearTimeout(initial);
  }, [reload, user]);

  const save = useCallback(async (next: Snapshot) => {
    if (!supabase || !user) return;
    setSaving(true);
    setStatus("Saving…");
    const payload = { ...next, updatedAt: stamp() };
    try {
      const deletions = await saveSnapshot(user, payload);
      // Only replace what this save wrote; a newer edit brings its own save along.
      setData((current) => (current === next ? { ...payload, deletions } : current));
      setStatus("Synced");
    } catch (error) {
      setStatus(errorMessage(error, "Save failed"));
    } finally {
      setSaving(false);
    }
  }, [user]);

  // The recipe runs here rather than inside a state updater: updaters must stay pure, and React
  // re-invokes them in development, which would fire every save twice.
  const mutate = useCallback((recipe: (draft: Snapshot) => Snapshot) => {
    const next = recipe(data);
    localRevision.current += 1;
    setData(next);
    if (user) void save(next);
    return next;
  }, [data, save, user]);

  // Loading until auth settles, and then until the signed-in user's first snapshot lands.
  const loading = !authReady || (user !== null && !loaded);

  return { data, user, authReady, loading, saving, status, mutate, reload };
}
