# @hal-c2/desktop-qt

Qt/QML desktop client for HAL-C2. Its QML chrome talks to the node over the
shell's own connection and can be rearranged and themed from
`~/.config/hal-c2/shell/`. What has not moved to QML yet still comes from the
legacy web app in an embedded `WebEngineView`.

Architecture, setup, and the QML/theme contracts: `docs/internals/desktop-qt.md`.

```sh
mise run node       # terminal 1: the Elixir node
mise run desktop    # terminal 2: build the web app (apps/web/dist) and the shell, pair with the node, launch
```

`mise run desktop -- --standalone` skips the pairing and lets the shell start its own node,
as the installed app does.

Besides Qt Quick and WebEngine, the shell needs the Qt WebSockets module for its own node
client: `qt6-websockets` on Arch and Fedora, `qt6-websockets-dev` on Debian and Ubuntu.

The terminal drawer is [qml-ghostty](https://github.com/hal-c2/qml-ghostty), fetched at the
revision pinned in `cmake/QmlGhostty.cmake`. The first configure builds its libghostty-vt from
a Ghostty checkout with Zig 0.15.2 (both downloaded into `~/.cache/qml-ghostty`; needs `bash`,
`curl`, `git` and `tar`), which takes a few minutes. Pass
`-DHAL_C2_GHOSTTY_VT_LIBRARY=/path/to/libghostty-vt.a` to use one already built, or
`-DFETCHCONTENT_SOURCE_DIR_QML_GHOSTTY=/path/to/qml-ghostty` to build against a local checkout.
qml-ghostty's Ghostty pin must equal `native/libghostty-vt/VERSION`; configure stops if it does not.

Focused native checks use temporary data and run offscreen:

```sh
vp run --filter @hal-c2/desktop-qt test:qml
cmake -S apps/desktop-qt/tests/native -B apps/desktop-qt/build/tests/native
cmake --build apps/desktop-qt/build/tests/native
ctest --test-dir apps/desktop-qt/build/tests/native --output-on-failure
```

`Features` runs the `@desktop` and `@shared` scenarios in the feature files `tst_Features.cpp`
lists (`features/desktop/native-*.feature`, cluster, links, pairing, Connections settings and more)
against a fake node, skipping `@backlog`,
`@backlog-desktop` and `@dropped`; `HAL_C2_FEATURES="desktop/native-sidebar.feature"` narrows it.
Its steps live in `tests/native/features/`, one self-registering file per domain, each with its
own part of the fake node (`FakeNode::Extension`).
`ShellRuntime` covers reload and theme ownership. `ShellExamples` loads all
the examples at 640, 1000, and 1400 pixels (including `glass-macos` on macOS), checking header text and dashboard
card bounds, long branch names, clipped icons, and scrolling to the last card. It uses a local
view-model fixture and a blank web page; no running server or pairing is needed.
