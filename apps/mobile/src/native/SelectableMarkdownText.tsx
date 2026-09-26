import type { SelectableMarkdownTextProps } from "@hal-c2/mobile-markdown-text/renderer";

type MobileSelectableMarkdownTextProps = Omit<SelectableMarkdownTextProps, "highlightCode">;

export type {
  MarkdownFileContextMenu,
  MarkdownFileContextMenuAction,
  MarkdownImageRenderer,
  MarkdownImageRequest,
  NativeMarkdownTextStyle,
  SelectableMarkdownSkill,
} from "@hal-c2/mobile-markdown-text/types";

export function hasNativeSelectableMarkdownText(): boolean {
  return false;
}

export function SelectableMarkdownText(_props: MobileSelectableMarkdownTextProps) {
  return null;
}
