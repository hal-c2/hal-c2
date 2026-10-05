import type { QmlObject } from "opentui-qml";

/**
 * Put the prompt's cursor after its text. QML's TextArea has no cursor
 * property and starts over at the first cell when its text is set, so after
 * the host completes what the user typed (a picked "@file") typing would
 * otherwise carry on in front of it. The entry binds this to the shell's root.
 */
export function movePromptCursorToEnd(root: QmlObject, text: string): void {
  const queue: QmlObject[] = [root];
  while (queue.length > 0) {
    const object = queue.shift()!;
    if (object.get("objectName") === "composerInput") {
      const { renderable } = object as unknown as {
        renderable?: {
          plainText: string;
          setText: (text: string) => void;
          gotoBufferEnd: () => void;
        };
      };
      if (!renderable) return;
      // The brick follows the host's text on its next binding pass; set it now so
      // the cursor lands after the completed text, not after the old one.
      if (renderable.plainText !== text) renderable.setText(text);
      renderable.gotoBufferEnd();
      return;
    }
    queue.push(...object.children);
  }
}
