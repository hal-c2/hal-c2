const REPOSITORY_URL = "https://github.com/hal-c2/hal-c2";

// HAL-C2 publishes no hosted terms or privacy policy. Its legal documents are
// the license and security policy in the repository.
export const LEGAL_URL = `${REPOSITORY_URL}/blob/HEAD/LICENSE`;
export const SECURITY_POLICY_URL = `${REPOSITORY_URL}/blob/HEAD/.github/SECURITY.md`;

export const ALLOWED_LEGAL_DOCUMENT_URLS = [LEGAL_URL, SECURITY_POLICY_URL] as const;

function webDocumentIdentity(value: string): string | null {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;

    const pathname = url.pathname.replace(/\/+$/, "") || "/";
    return `${url.origin}${pathname}`;
  } catch {
    return null;
  }
}

const ALLOWED_LEGAL_DOCUMENT_IDENTITIES = new Set(
  ALLOWED_LEGAL_DOCUMENT_URLS.map(webDocumentIdentity).filter(
    (value): value is string => value !== null,
  ),
);

export function isLegalDocumentUrl(value: string): boolean {
  const identity = webDocumentIdentity(value);
  return identity !== null && ALLOWED_LEGAL_DOCUMENT_IDENTITIES.has(identity);
}
