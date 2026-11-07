import type { ImagePreview } from "@hal-c2/opentui-image";

import type { TuiClient } from "../connection.ts";

/** Where an attachment's link stands: resolving, resolved to a URL, or unavailable. */
export type AttachmentLink =
  | { readonly state: "pending" }
  | { readonly state: "ready"; readonly url: string }
  | { readonly state: "unavailable" };

export interface AttachmentPreview {
  readonly link: AttachmentLink;
  /** The decoded preview, once loaded; null while loading, refused, failed or not drawn. */
  readonly image: ImagePreview | null;
}

export interface AttachmentPreviews {
  /** What the timeline shows for an attachment; starts resolving it the first time. */
  readonly get: (attachmentId: string, kind?: "image" | "file") => AttachmentPreview;
  /**
   * The attachments are being shown anew (another thread opened): forget
   * unavailable links and failed previews, so showing them again retries.
   */
  readonly forgetFailures: () => void;
  /** Resolves once every link and preview requested so far has landed. */
  readonly settled: () => Promise<void>;
}

/**
 * The MC's attachment links last an hour; a link older than this is asked for
 * again, a little early so a click never meets a dead one.
 */
export const ATTACHMENT_LINK_TTL_MS = 50 * 60_000;

/** A refresh that failed keeps the link it had and is tried again this much later. */
const REFRESH_RETRY_MS = 60_000;

interface Entry {
  link: AttachmentLink;
  /** When the link was resolved (epoch ms); null while it is still being asked for. */
  resolvedAt: number | null;
  image: ImagePreview | null;
  /** The preview was asked for and did not arrive (network error, too large, undecodable). */
  failed: boolean;
  /** A file has a link to open but no preview to draw. */
  readonly kind: "image" | "file";
}

const PENDING: AttachmentLink = { state: "pending" };

/**
 * The timeline's image attachments (port of MessagesTimeline's
 * AttachmentPreview effect): resolve each attachment's link once, then load
 * its preview when the terminal draws inline images. `onChange` republishes
 * the timeline when a link or preview lands.
 */
export function createAttachmentPreviews(options: {
  readonly client: Pick<TuiClient, "getAttachmentUrl" | "getAttachmentImage">;
  readonly inlineImages: boolean;
  /** The clock links age by (default: the real one). */
  readonly nowMs?: () => number;
  readonly onChange: () => void;
}): AttachmentPreviews {
  const { client } = options;
  const nowMs = options.nowMs ?? Date.now;
  const entries = new Map<string, Entry>();
  const inFlight = new Set<Promise<unknown>>();
  const track = <T>(promise: Promise<T>): Promise<T> => {
    inFlight.add(promise);
    const done = () => inFlight.delete(promise);
    promise.then(done, done);
    return promise;
  };

  const start = (attachmentId: string, kind: "image" | "file"): Entry => {
    const entry: Entry = { link: PENDING, resolvedAt: null, image: null, failed: false, kind };
    entries.set(attachmentId, entry);
    resolve(attachmentId, entry);
    return entry;
  };

  /**
   * Ask for the link (again); an image already drawn stays drawn meanwhile. A refresh
   * that fails keeps the link, which may still work, and tries again shortly.
   */
  const resolve = (attachmentId: string, entry: Entry): void => {
    const previous = entry.link;
    entry.resolvedAt = null;
    void track(
      (async () => {
        const url = await client.getAttachmentUrl(attachmentId).catch(() => null);
        if (entries.get(attachmentId) !== entry) return;
        if (!url && previous.state === "ready") {
          entry.resolvedAt = nowMs() - ATTACHMENT_LINK_TTL_MS + REFRESH_RETRY_MS;
          return;
        }
        entry.link = url ? { state: "ready", url } : { state: "unavailable" };
        entry.resolvedAt = nowMs();
        options.onChange();
        if (!url || !options.inlineImages || entry.kind === "file" || entry.image) return;
        const image = await client.getAttachmentImage(attachmentId, url).catch(() => null);
        if (entries.get(attachmentId) !== entry) return;
        entry.image = image;
        entry.failed = image === null;
        options.onChange();
      })(),
    );
  };

  return {
    get: (attachmentId, kind = "image") => {
      const entry = entries.get(attachmentId) ?? start(attachmentId, kind);
      if (entry.resolvedAt !== null && nowMs() - entry.resolvedAt >= ATTACHMENT_LINK_TTL_MS) {
        resolve(attachmentId, entry);
      }
      return { link: entry.link, image: entry.image };
    },
    forgetFailures: () => {
      for (const [id, entry] of entries) {
        if (entry.failed || entry.link.state === "unavailable") entries.delete(id);
      }
    },
    settled: async () => {
      while (inFlight.size > 0) await Promise.allSettled(inFlight);
    },
  };
}
