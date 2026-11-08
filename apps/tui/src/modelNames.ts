// The names a model goes by (upstream #24205), as the desktop's modelPicker.js
// works them out: the picker lists the full name, the composer's model control
// the name the user would say. Pure.

const FAMILY_PREFIXES = ["Claude ", "GPT-", "GPT ", "Gemini ", "Muse ", "Grok "];
const NATIVE_FAMILIES: Readonly<Record<string, ReadonlyArray<string>>> = {
  codex: ["GPT-", "GPT "],
  claudeAgent: ["Claude "],
  claude: ["Claude "],
  antigravity: ["Gemini "],
  cursor: ["Grok "],
  grok: ["Grok "],
  muse: ["Muse "],
};
const VARIANT_WORDS = new Set([
  "pro",
  "flash",
  "mini",
  "max",
  "lite",
  "nano",
  "ultra",
  "plus",
  "fast",
  "turbo",
  "preview",
  "latest",
  "thinking",
  "reasoning",
  "build",
  "code",
  "image",
  "vision",
  "audio",
  "live",
  "custom",
  "tools",
  "exp",
  "experimental",
  "chat",
  "tts",
  "stt",
  "non",
  "transcribe",
]);

const nonVersionWords = (text: string) =>
  text
    .replace(/\(.*?\)/g, " ")
    .split(/[\s-]+/)
    .filter((word) => word.length > 0 && !/^v?\d+(\.\d+)*[a-z]?$/i.test(word));

const namesModel = (text: string) =>
  nonVersionWords(text).some((word) => !VARIANT_WORDS.has(word.toLowerCase()));

/**
 * The name the user would say, worked out when the manifest gives no short
 * name (upstream modelShortName): a vendor prefix ("NVIDIA: ") goes, then the
 * family prefix the provider already says — on its native provider when the
 * rest names more than a version, elsewhere only when the rest still names a
 * model rather than a variant. Null when that is the full name.
 */
export function modelShortName(name: string, driver: string | null | undefined): string | null {
  const unprefixed = name.replace(/^[A-Z][\w.&\- ]{0,24}: (?=\S)/, "");
  const prefix = FAMILY_PREFIXES.find((candidate) => unprefixed.startsWith(candidate));
  let short: string | null = null;
  if (prefix !== undefined) {
    const rest = unprefixed.slice(prefix.length).trim();
    const native = (NATIVE_FAMILIES[driver ?? ""] ?? []).includes(prefix);
    if (native ? nonVersionWords(rest).length > 0 : namesModel(rest)) {
      short = /\s/.test(rest) ? rest : rest.replace(/-/g, " ");
    }
  }
  short ??= namesModel(unprefixed) ? unprefixed : name;
  return short === name ? null : short;
}

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** `value` without a leading `qualifier` (the aggregator's sub-provider). */
function stripLeadingQualifier(value: string, qualifier: string | undefined): string {
  const trimmed = qualifier?.trim() ?? "";
  if (!trimmed) return value;
  const pattern = new RegExp(`^${escapeRegExp(trimmed)}(?:\\s*[.:/-]\\s*|\\s+)`, "i");
  return value.replace(pattern, "").trim() || value;
}

interface NamedModel {
  readonly name: string;
  readonly shortName?: string | undefined;
  readonly subProvider?: string | undefined;
}

/** The full name, as the model picker lists it. */
export function modelFullName(model: NamedModel): string {
  return stripLeadingQualifier(model.name, model.subProvider);
}

/** The name the model control shows: the manifest's short name, else the worked-out one. */
export function modelButtonName(model: NamedModel, driver: string | null | undefined): string {
  return stripLeadingQualifier(
    model.shortName ?? modelShortName(model.name, driver) ?? model.name,
    model.subProvider,
  );
}
