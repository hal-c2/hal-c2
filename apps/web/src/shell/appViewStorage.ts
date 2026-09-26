/** Independent Qt clients share authentication, but not whole-store UI snapshots. */
export function appViewStorageKey(key: string): string {
  const id = typeof window === "undefined" ? undefined : window.__halC2AppViewStorageId;
  return typeof id === "string" && id.length > 0
    ? `hal-c2:app-view:${encodeURIComponent(id)}:${key}`
    : key;
}
