const REPO = "hal-c2/hal-c2";

export const RELEASES_URL = `https://github.com/${REPO}/releases`;

// The MC publishes its releases as prereleases tagged mc-v<version> (.github/workflows/release-mc.yml),
// which the `latest` endpoint skips. GitHub returns the list newest first, so the first mc-v tag in
// a small page is the current build.
const LIST_API_URL = `https://api.github.com/repos/${REPO}/releases?per_page=10`;
const CACHE_KEY = "hal-c2-mc-release";

export interface ReleaseAsset {
  name: string;
  browser_download_url: string;
}

export interface Release {
  tag_name: string;
  html_url: string;
  published_at: string;
  assets: ReleaseAsset[];
}

export async function fetchLatestRelease(): Promise<Release> {
  const cached = sessionStorage.getItem(CACHE_KEY);
  if (cached) return JSON.parse(cached);

  const list: Release[] = await fetch(LIST_API_URL).then((r) => r.json());
  const release = Array.isArray(list)
    ? list.find((candidate) => candidate.tag_name?.startsWith("mc-v"))
    : undefined;
  if (!release) throw new Error("No MC release in the latest page");

  sessionStorage.setItem(CACHE_KEY, JSON.stringify(release));
  return release;
}
