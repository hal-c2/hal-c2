// Before the rename to HAL-C2 the web client kept its state under T3 Code
// names. Boot copies it to the new names once so existing users keep their
// settings; the old entries stay behind untouched.

const LEGACY_KEY_PREFIXES: ReadonlyArray<readonly [legacy: string, current: string]> = [
  ["t3code:", "hal-c2:"],
  ["t3code.", "hal-c2."],
];

const LEGACY_KEYS: Readonly<Record<string, string>> = {
  "t3.pullRequests.preferences": "halc2.pullRequests.preferences",
  "t3.backgroundActivity.clientId": "halc2.backgroundActivity.clientId",
};

const LEGACY_DATABASE_NAMES: Readonly<Record<string, string>> = {
  "hal-c2:connection-runtime": "t3code:connection-runtime",
  "hal-c2:cloud-auth": "t3code:cloud-auth",
};

function currentStorageKey(key: string): string | null {
  if (Object.hasOwn(LEGACY_KEYS, key)) return LEGACY_KEYS[key]!;
  for (const [legacy, current] of LEGACY_KEY_PREFIXES) {
    if (key.startsWith(legacy)) return current + key.slice(legacy.length);
  }
  return null;
}

/** Copies every pre-rename key whose new name is still unset. Runs once, at boot. */
export function copyLegacyStorageKeys(storage: Storage): void {
  const copies: Array<readonly [key: string, value: string]> = [];
  for (let index = 0; index < storage.length; index++) {
    const legacyKey = storage.key(index);
    const key = legacyKey === null ? null : currentStorageKey(legacyKey);
    if (key === null || storage.getItem(key) !== null) continue;
    const value = storage.getItem(legacyKey!);
    if (value !== null) copies.push([key, value]);
  }
  for (const [key, value] of copies) storage.setItem(key, value);
}

let existingDatabaseNames: Promise<ReadonlySet<string>> | undefined;

/**
 * The IndexedDB name to open: a database written before the rename keeps its
 * old name until the new one exists, so its data stays reachable.
 */
export function resolveDatabaseName(name: string): Promise<string> {
  const legacy = LEGACY_DATABASE_NAMES[name];
  if (
    legacy === undefined ||
    typeof indexedDB === "undefined" ||
    typeof indexedDB.databases !== "function"
  ) {
    return Promise.resolve(name);
  }
  existingDatabaseNames ??= indexedDB.databases().then(
    (databases) => new Set(databases.flatMap((database) => database.name ?? [])),
    () => new Set<string>(),
  );
  return existingDatabaseNames.then((names) =>
    !names.has(name) && names.has(legacy) ? legacy : name,
  );
}
