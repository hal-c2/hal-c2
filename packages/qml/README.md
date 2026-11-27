# Shared QML

The neutral home of the QML every client shares, so no client reads another
client's tree. This directory is a QML import root: point an engine's import
path at it and the module URIs are the directories under it.

- `HalC2/Bricks/` — the bricks (`import HalC2.Bricks`): the pure-QML chrome
  the desktop and phone shells compose, with a hand-written `qmldir` so the
  same directory works compiled in and as a disk import path.
- `themes.json` — the built-in theme palettes the shells resolve a theme
  from. Regenerated from `packages/shared` by
  `node packages/qml/scripts/gen-themes.mjs`; the icon paths in
  `HalC2/Bricks/js/lucide.js` by `packages/qml/scripts/gen-icons.mjs`.
- `cmake/QmldirCheck.cmake` — the qmldir/module cross-check the Qt builds
  include.

Readers: desktop-ljos and mobile-ljos compile this tree into their packs;
mobile-qt compiles `HalC2.Bricks` as a Qt QML module and loads
it from here in development builds. A user's `shell.qml` imports the same
`HalC2.Bricks` URI wherever the tree lives in a checkout.
