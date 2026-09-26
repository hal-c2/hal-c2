/**
 * Pairing links the host reads and writes. The token travels in the fragment
 * (`#token=`), the way apps/web's `/pair` route and `@hal-c2/shared/remote`
 * expect, so it never reaches a server log.
 */

/**
 * The app's `/pair` route for a node: pairs with `token`, then (`auto=1`) goes
 * straight to the app instead of stopping on "Backend paired".
 */
export function appPairingUrl(appOrigin: string, nodeOrigin: string, token: string): string {
  const url = new URL("/pair", appOrigin);
  url.searchParams.set("host", nodeOrigin);
  url.searchParams.set("auto", "1");
  url.hash = new URLSearchParams([["token", token]]).toString();
  return url.href;
}

/**
 * The node origin and token of a pairing link such as `mix hal_c2.pair` prints
 * (`http://127.0.0.1:3780/?token=...`), token in the query or the fragment.
 * Undefined for anything that is not an http(s) URL.
 */
export function readPairingLink(
  link: string,
): { readonly origin: string; readonly token: string | undefined } | undefined {
  let url: URL;
  try {
    url = new URL(link);
  } catch {
    return undefined;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return undefined;
  }
  const hashToken = new URLSearchParams(url.hash.replace(/^#/, "")).get("token")?.trim();
  const queryToken = url.searchParams.get("token")?.trim();
  return { origin: url.origin, token: hashToken || queryToken || undefined };
}
