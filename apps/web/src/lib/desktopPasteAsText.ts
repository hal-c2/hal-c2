import type { DesktopBridge } from "@hal-c2/contracts";

export const DESKTOP_PASTE_AS_TEXT_EVENT = "hal-c2:paste-as-text";

/** Arm composer paste handling before Electron delivers the native clipboard event. */
export function installDesktopPasteAsText(
  bridge: Pick<DesktopBridge, "onMenuAction" | "pasteAsText"> | undefined,
  target: EventTarget,
): (() => void) | undefined {
  return bridge?.onMenuAction((action) => {
    if (action !== "paste-as-text") return;
    target.dispatchEvent(new Event(DESKTOP_PASTE_AS_TEXT_EVENT));
    void bridge.pasteAsText?.();
  });
}
