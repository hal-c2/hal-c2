import { describe, expect, it } from "vite-plus/test";

import { isLegalDocumentUrl } from "./legal-document-url";

describe("isLegalDocumentUrl", () => {
  it.each([
    "https://github.com/hal-c2/hal-c2/blob/HEAD/LICENSE",
    "https://github.com/hal-c2/hal-c2/blob/HEAD/LICENSE/",
    "https://github.com/hal-c2/hal-c2/blob/HEAD/LICENSE?plain=1",
    "https://github.com/hal-c2/hal-c2/blob/HEAD/.github/SECURITY.md#reporting",
  ])("allows a configured legal document: %s", (url) => {
    expect(isLegalDocumentUrl(url)).toBe(true);
  });

  it.each([
    "https://github.com/hal-c2/hal-c2/blob/HEAD/README.md",
    "https://github.com/another/repo/blob/HEAD/LICENSE",
    "https://example.com/legal",
    "javascript:alert(1)",
    "not-a-url",
  ])("rejects a URL outside the legal-document allowlist: %s", (url) => {
    expect(isLegalDocumentUrl(url)).toBe(false);
  });
});
