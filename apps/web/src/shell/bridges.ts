// Everything the page only needs when a native shell hosts it. Imported
// through `./lazy` (components) or a dynamic import (context menu) so none of
// it, nor the shell schemas, lands in the browser bundle.
export { ShellEmbedRouteBridge } from "./ShellEmbedRouteBridge";
export { ShellGitBridge } from "./ShellGitBridge";
export { ShellLayoutBridge } from "./ShellLayoutBridge";
export { ShellSettingsBridge } from "./ShellSettingsBridge";
export { ShellThemeBridge } from "./ShellThemeBridge";
export { ShellToastBridge } from "./ShellToastBridge";
export { ShellWorkspaceBridge } from "./ShellWorkspaceBridge";
export { HalC2ShellBridge } from "./HalC2ShellBridge";
export { closeShellContextMenu, showShellContextMenu } from "./shellContextMenu";
