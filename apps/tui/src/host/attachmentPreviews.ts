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
  readonly get: (attachmentId: string) => AttachmentPreview;
  /**
   * The attachments are being shown anew (another thread opened): forget
   * unavailable links and failed previews, so showing them again retries.
   */
  readonly forgetFailures: () => void;
  /** Resolves once every link and preview requested so far has landed. */
  readonly settled: () => Promise<void>;
}

interface Entry {
  link: AttachmentLink;
  image: ImagePreview | null;
  /** The preview was asked for and did not arrive (network error, too large, undecodable). */
  failed: boolean;
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
  readonly onChange: () => void;
}): AttachmentPreviews {
  const { client } = options;
  const entries = new Map<string, Entry>();
  const inFlight = new Set<Promise<unknown>>();
  const track = <T>(promise: Promise<T>): Promise<T> => {
    inFlight.add(promise);
    const done = () => inFlight.delete(promise);
    promise.then(done, done);
    return promise;
  };

  const start = (attachmentId: string): Entry => {
    const entry: Entry = { link: PENDING, image: null, failed: false };
    entries.set(attachmentId, entry);
    void track(
      (async () => {
        const url = await client.getAttachmentUrl(attachmentId).catch(() => null);
        if (entries.get(attachmentId) !== entry) return;
        entry.link = url ? { state: "ready", url } : { state: "unavailable" };
        options.onChange();
        if (!url || !options.inlineImages) return;
        const image = await client.getAttachmentImage(attachmentId, url).catch(() => null);
        if (entries.get(attachmentId) !== entry) return;
        entry.image = image;
        entry.failed = image === null;
        options.onChange();
      })(),
    );
    return entry;
  };

  return {
    get: (attachmentId) => {
      const entry = entries.get(attachmentId) ?? start(attachmentId);
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
