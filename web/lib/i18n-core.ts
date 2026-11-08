/** Interface languages the catalog ships, in menu order. */
export const LANGUAGES = [
  { code: "en", name: "English" },
  { code: "zh-Hans", name: "简体中文" },
  { code: "zh-Hant", name: "繁體中文" },
  { code: "es", name: "Español" },
  { code: "fr", name: "Français" },
  { code: "de", name: "Deutsch" },
  { code: "pt", name: "Português" },
  { code: "ja", name: "日本語" },
  { code: "ko", name: "한국어" },
  { code: "it", name: "Italiano" },
] as const;

export type Language = (typeof LANGUAGES)[number]["code"];
export const DEFAULT_LANGUAGE: Language = "en";
/** localStorage key and user_metadata field, shared with the Android and iOS apps. */
export const LANGUAGE_KEY = "language";

/** The catalog language a BCP 47 tag (or saved code) maps to, or null when we do not ship it. */
export function matchLanguage(tag: unknown): Language | null {
  if (typeof tag !== "string" || !tag) return null;
  const lower = tag.toLowerCase();
  if (lower.startsWith("zh")) return /hant|tw|hk|mo/.test(lower) ? "zh-Hant" : "zh-Hans";
  const primary = lower.split(/[-_]/)[0];
  return LANGUAGES.find((language) => language.code === primary)?.code ?? null;
}

/** Fills `{name}` placeholders; unknown placeholders stay visible so a missing variable is easy to spot. */
export function format(template: string, vars?: Record<string, string | number>) {
  if (!vars) return template;
  return template.replace(/\{(\w+)\}/g, (match, name: string) => name in vars ? String(vars[name]) : match);
}
