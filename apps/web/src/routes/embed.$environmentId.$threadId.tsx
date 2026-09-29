import { createFileRoute } from "@tanstack/react-router";

import { ThreadTerminalDocument } from "../components/ThreadTerminalDocument";
import { useComposerDraftStore } from "../composerDraftStore";
import { ShellEmbedRouteBridge } from "../shell/lazy";
import { useThreadShell } from "../state/entities";
import { useEnvironmentQuery } from "../state/query";
import { environmentShell } from "../state/shell";
import { resolveThreadRouteRef, resolveThreadRouteRenderState } from "../threadRoutes";

/**
 * The thread's terminal drawer on its own (`?surface=terminal`), for a web
 * view the Qt shell places itself. Same session (cookies), its own
 * WebSocket; the drawer's state converges with the primary document through
 * localStorage (see shell/shellDocumentSync.ts).
 */
function EmbedThreadPanelRouteView() {
  const threadRef = Route.useParams({
    select: (params) => resolveThreadRouteRef(params),
  });

  const shell = useEnvironmentQuery(
    threadRef === null ? null : environmentShell.stateAtom(threadRef.environmentId),
  );
  const serverThreadShell = useThreadShell(threadRef);
  // Drafts persist to localStorage, so a draft the primary document is
  // showing is visible here too (its own store copy, same key).
  const draftThreadExists = useComposerDraftStore((store) =>
    threadRef ? store.getDraftThreadByRef(threadRef) !== null : false,
  );
  const bootstrapComplete = shell.data?.snapshot._tag === "Some";
  const renderState = resolveThreadRouteRenderState({
    bootstrapComplete,
    serverThreadExists: serverThreadShell !== null,
    serverThreadDeleted: serverThreadShell?.deletedAt != null,
    draftThreadExists,
  });

  if (!threadRef) {
    return null;
  }
  return (
    <div className="flex h-svh min-h-0 flex-col overflow-hidden bg-background text-foreground md:h-dvh">
      {/* Follows the primary view's thread instead of the shell reloading this document. */}
      <ShellEmbedRouteBridge threadRef={threadRef} />
      {renderState === "ready" || (renderState === "loading" && serverThreadShell !== null) ? (
        <ThreadTerminalDocument threadRef={threadRef} />
      ) : null}
    </div>
  );
}

export const Route = createFileRoute("/embed/$environmentId/$threadId")({
  validateSearch: (): { surface: "terminal" } => ({ surface: "terminal" }),
  component: EmbedThreadPanelRouteView,
});
