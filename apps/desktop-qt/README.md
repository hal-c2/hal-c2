# @hal-c2/desktop-qt

Qt/QML shell for HAL-C2. Hosts the web app in a `WebEngineView` and lets the
window chrome be rearranged and themed from `~/.config/hal-c2/shell/`.

Architecture, setup, and the QML/theme contracts: `docs/internals/desktop-qt.md`.

```sh
mise run node       # terminal 1: the Elixir node
mise run desktop    # terminal 2: build the web app (apps/web/dist) and the shell, pair with the node, launch
```

`mise run desktop -- --standalone` skips the pairing and lets the shell start its own node,
as the installed app does.

Focused native checks use temporary data and run offscreen:

```sh
vp run --filter @hal-c2/desktop-qt test:qml
cmake -S apps/desktop-qt/tests/native -B apps/desktop-qt/build/tests/native
cmake --build apps/desktop-qt/build/tests/native
ctest --test-dir apps/desktop-qt/build/tests/native --output-on-failure
```

`ShellRuntime` covers reload and theme ownership. `ShellExamples` loads all
the examples at 640, 1000, and 1400 pixels (including `glass-macos` on macOS), checking header text and dashboard
card bounds, long branch names, clipped icons, and scrolling to the last card. It uses a local
view-model fixture and a blank web page; no running server or pairing is needed.
