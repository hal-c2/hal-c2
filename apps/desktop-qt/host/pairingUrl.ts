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
