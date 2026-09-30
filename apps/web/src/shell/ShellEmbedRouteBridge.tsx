import { useAtomValue } from "@effect/atom-react";
import { parseScopedThreadKey } from "@hal-c2/client-runtime/environment";
import type { ScopedThreadRef } from "@hal-c2/contracts";
import { useNavigate } from "@tanstack/react-router";
import * as Schema from "effect/Schema";
import { useEffect } from "react";

import { isPreviewFocused } from "../lib/previewFocus";
import { isTerminalFocused } from "../lib/terminalFocus";
import { primaryServerKeybindingsAtom } from "../state/server";
import { buildThreadRouteParams } from "../threadRoutes";
import { shellKeybindingPressToForward } from "./shellKeybindings";

// Only the thread key is read, so the whole struct is not validated on every
// publish (the workspace entry updates on each git poll).
const hasThreadKey = Schema.is(Schema.Struct({ threadKey: Schema.String }));

/**
 * Mounted by the embed route in the shell's terminal drawer web view.
 * Follows the thread the primary view publishes under `workspace` so the
 * document shows the thread the user is looking at, without the shell having
 * to drive navigation.
 *
 * Also hands the primary document the page keybindings this one cannot act
 * on itself (thread jumps, the sidebar toggle): while this view has focus the
 * shell's own shortcuts are off, and the handlers for those live with the
 * sidebar in the primary.
 */
export function ShellEmbedRouteBridge({ threadRef }: { readonly threadRef: ScopedThreadRef }) {
  const navigate = useNavigate();
  useEffect(() => {
    const shell = window.halC2Shell;
    if (!shell) return;
    let disposed = false;
    let unsubscribe: (() => void) | null = null;
    void shell
      .onState((state) => {
        const entry = state.workspace;
        if (!hasThreadKey(entry)) return;
        const target = parseScopedThreadKey(entry.threadKey);
        if (
          target === null ||
          (target.environmentId === threadRef.environmentId &&
            target.threadId === threadRef.threadId)
        ) {
          return;
        }
        void navigate({
          to: "/embed/$environmentId/$threadId",
          params: buildThreadRouteParams(target),
          search: { surface: "terminal" },
          replace: true,
        });
      })
      .then((dispose) => {
        if (disposed) dispose();
        else unsubscribe = dispose;
      });
    return () => {
      disposed = true;
      unsubscribe?.();
    };
  }, [navigate, threadRef.environmentId, threadRef.threadId]);

  const keybindings = useAtomValue(primaryServerKeybindingsAtom);
  useEffect(() => {
    const shell = window.halC2Shell;
    if (!shell) return;
    // Bubble phase: this document's own handlers (ChatView's, the terminal's)
    // have had the key by now and prevented what they consumed.
    const onWindowKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.repeat) return;
      const press = shellKeybindingPressToForward(event, keybindings, navigator.platform, {
        terminalFocus: isTerminalFocused(),
        previewFocus: isPreviewFocused(),
      });
      if (press === null) return;
      event.preventDefault();
      void shell.dispatch("keybinding.press", press);
    };
    window.addEventListener("keydown", onWindowKeyDown);
    return () => window.removeEventListener("keydown", onWindowKeyDown);
  }, [keybindings]);
  return null;
}
