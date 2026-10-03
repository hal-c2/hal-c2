import type { TuiClient } from "../connection.ts";

/** How long the MC keeps a report; it is renewed well inside that. */
export const CLIENT_ACTIVITY_TTL_MS = 45_000;
const RENEW_MS = 30_000;
let clients = 0;

/**
 * Tells the MC what the user is looking at (`server.reportClientActivity`), so
 * it fetches git and checks providers only for what is on screen: the open
 * thread and its checkout's git status. A report lapses unless renewed, so it
 * is sent again every 30 seconds while the thread stays open, and once with
 * nothing in it when the user leaves. A server that does not know the call is
 * left alone.
 */
export function createClientActivity(ctx: {
  readonly client: Pick<TuiClient, "mcCall">;
  /** The open thread and the folder its git status is read from; null when none is open. */
  readonly watching: () => { readonly threadId: string; readonly cwd: string } | null;
  readonly now: () => string;
}) {
  // One lease per running client: the MC keys them by socket and this id.
  const clientId = `tui-${process.pid}-${++clients}`;
  let reported = "";
  const report = (force: boolean) => {
    const watching = ctx.watching();
    const key = watching ? `${watching.threadId}\u0000${watching.cwd}` : "";
    // Nothing was reported and nothing is open: there is no lease to renew or drop.
    if (key === "" && reported === "") return;
    if (!force && key === reported) return;
    reported = key;
    void ctx.client
      .mcCall("server.reportClientActivity", {
        clientId,
        clientKind: "unknown",
        visible: true,
        focused: true,
        recentlyInteracted: true,
        scopes: watching
          ? [
              { type: "thread", threadId: watching.threadId },
              { type: "vcs-status", cwd: watching.cwd },
            ]
          : [],
        ttlMs: CLIENT_ACTIVITY_TTL_MS,
        observedAt: ctx.now(),
      })
      .catch(() => {
        // Not connected yet, or a server without background policy.
      });
  };
  const timer = setInterval(() => report(true), RENEW_MS);
  timer.unref?.();
  return {
    /** The open thread may have changed: report it if it did. */
    sync: () => report(false),
    /** Send the report again now (what the 30-second renewal does). */
    renew: () => report(true),
    dispose: () => clearInterval(timer),
  };
}
