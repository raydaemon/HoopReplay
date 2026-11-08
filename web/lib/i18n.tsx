"use client";

// Interface language for the Web app. A tiny external store holds the chosen language and its
// dictionary (web/i18n/<code>.json); t() looks every UI string up by its English text.
import { useCallback, useSyncExternalStore } from "react";
import { supabase } from "@/lib/supabase";
import { DEFAULT_LANGUAGE, LANGUAGE_KEY, type Language, format, matchLanguage } from "@/lib/i18n-core";

type Dict = Record<string, string>;
type State = { language: Language; dict: Dict };

const SERVER_STATE: State = { language: DEFAULT_LANGUAGE, dict: {} };
let state: State = SERVER_STATE;
let started = false;
const listeners = new Set<() => void>();

function apply(language: Language) {
  state = { language, dict: language === state.language ? state.dict : {} };
  document.documentElement.lang = language;
  listeners.forEach((listener) => listener());
  if (language === DEFAULT_LANGUAGE) return;
  void import(`../i18n/${language}.json`).then((module: { default: Dict }) => {
    if (state.language !== language) return;
    state = { language, dict: module.default };
    listeners.forEach((listener) => listener());
  });
}

/** Saved choice, then the browser language; later the account's language wins so devices stay in step. */
function start() {
  started = true;
  let saved: string | null = null;
  try { saved = window.localStorage.getItem(LANGUAGE_KEY); } catch {}
  apply(matchLanguage(saved) ?? matchLanguage(navigator.language) ?? DEFAULT_LANGUAGE);
  supabase?.auth.onAuthStateChange((_event, session) => {
    const fromAccount = matchLanguage(session?.user.user_metadata?.[LANGUAGE_KEY]);
    if (!fromAccount || fromAccount === state.language) return;
    try { window.localStorage.setItem(LANGUAGE_KEY, fromAccount); } catch {}
    apply(fromAccount);
  });
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  if (!started) start();
  return () => { listeners.delete(listener); };
}

function setLanguage(next: Language) {
  try { window.localStorage.setItem(LANGUAGE_KEY, next); } catch {}
  apply(next);
  void supabase?.auth.getSession().then(({ data }) => {
    if (data.session) return supabase!.auth.updateUser({ data: { [LANGUAGE_KEY]: next } });
  });
}

/** `t("Sign out")` → the current language's text, or the English key when there is no translation. */
export function useI18n() {
  const { language, dict } = useSyncExternalStore(subscribe, () => state, () => SERVER_STATE);
  const t = useCallback((key: string, vars?: Record<string, string | number>) => format(dict[key] ?? key, vars), [dict]);
  return { t, language, setLanguage };
}
