import { clip } from "../../format.ts";
import { payloadField, type Feature, type FeatureKit } from "./kit.ts";

/** `src/cart.ts:42`, `./lib/a.test.tsx:7:3`: a path with an extension, then a line. */
const FILE_REFERENCE = /(?<![\w/.-])((?:\.{1,2}\/)?[\w@.-]+(?:\/[\w@.-]+)*\.[A-Za-z0-9]+):(\d+)/g;

export interface FileReference {
  readonly path: string;
  readonly line: number;
}

/** The file locations a message names, in order, each once. */
export function fileReferences(text: string): FileReference[] {
  const seen = new Set<string>();
  const references: FileReference[] = [];
  for (const match of text.matchAll(FILE_REFERENCE)) {
    const key = `${match[1]}:${match[2]}`;
    if (seen.has(key)) continue;
    seen.add(key);
    references.push({ path: match[1]!.replace(/^\.\//, ""), line: Number(match[2]) });
  }
  return references;
}

/**
 * What the user takes out of the conversation: a message's text to the
 * clipboard, a link (copied, since a terminal client cannot open a browser on
 * the user's machine) and a file location, opened in their editor.
 */
export function createConversationFeature(kit: FeatureKit): Feature {
  const messages = () => kit.store.getState().detail?.messages ?? [];

  const copyMessage = () => {
    const recent = messages()
      .filter((message) => message.text.trim() !== "")
      .toReversed();
    if (recent.length === 0) {
      kit.status("No message to copy.", "info");
      return;
    }
    kit.menu({
      title: "copy message",
      searchable: true,
      options: recent.map((message) => ({
        label: clip(message.text.trim().split("\n")[0]!, 120),
        description: message.role === "user" ? "you" : "agent",
        value: message.id as string,
      })),
      onChoose: (id) => {
        const message = messages().find((candidate) => candidate.id === id);
        if (!message) return;
        const copied = kit.copy(message.text);
        kit.status(
          copied ? "Message copied." : "This terminal has no clipboard access.",
          copied ? "success" : "error",
        );
      },
    });
  };

  const openLink = (url: string) => {
    if (kit.copy(url)) kit.status("Link copied: open it in your browser.", "success");
    // No clipboard either: the status line shows the link to copy by hand.
    else kit.status(url, "info");
  };

  const openReference = () => {
    const references = messages()
      .toReversed()
      .flatMap((message) => fileReferences(message.text));
    const unique = references.filter(
      (reference, index) =>
        references.findIndex(
          (other) => other.path === reference.path && other.line === reference.line,
        ) === index,
    );
    if (unique.length === 0) {
      kit.status("The conversation names no file location.", "info");
      return;
    }
    kit.menu({
      title: "open in editor",
      searchable: true,
      options: unique.map((reference) => ({
        label: `${reference.path}:${reference.line}`,
        value: JSON.stringify(reference),
      })),
      onChoose: (value) => kit.dispatch("file.edit", JSON.parse(value) as FileReference),
    });
  };

  return {
    commands: () =>
      kit.store.getState().detail
        ? [
            {
              id: "message.copy",
              title: "Copy a message…",
              keywords: "clipboard reply text",
              action: "message.copy",
            },
            {
              id: "reference.open",
              title: "Open a file reference in $EDITOR…",
              keywords: "file location line editor",
              action: "reference.open",
            },
          ]
        : [],
    dispatch: (action, payload) => {
      switch (action) {
        case "message.copy":
          copyMessage();
          return true;
        case "reference.open":
          openReference();
          return true;
        case "link.open": {
          const url = payloadField(payload, "url");
          if (typeof url === "string") openLink(url);
          return true;
        }
        default:
          return false;
      }
    },
  };
}
