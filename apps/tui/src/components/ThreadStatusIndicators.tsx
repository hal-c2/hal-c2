import * as React from "react";

import { ansi, type ThreadStatus } from "../theme.ts";

// Status indicators for the sidebar: a single themed glyph (a status "dot")
// where a graphical client draws a coloured pill. These
// return <span> nodes, so they must be composed inside a <text>.

/** A themed status dot — the status glyph in the status' ANSI colour. */
export function StatusDot({ status }: { readonly status: ThreadStatus }): React.ReactNode {
  return <span fg={ansi(status.color)}>{status.glyph}</span>;
}
