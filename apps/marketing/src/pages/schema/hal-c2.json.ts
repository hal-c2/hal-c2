import type { APIRoute } from "astro";

import { buildHalC2ProjectFileJsonSchema } from "@hal-c2/shared/halC2ProjectFile";

// Rendered at build time; published at https://hal-c2.example/schema/hal-c2.json so
// hal-c2.json files can reference it via "$schema" for editor/LSP support.
export const GET: APIRoute = () =>
  new Response(`${JSON.stringify(buildHalC2ProjectFileJsonSchema(), null, 2)}\n`, {
    headers: { "Content-Type": "application/json" },
  });
