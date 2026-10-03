# @hal-c2/desktop-qt

Qt/QML desktop client for HAL-C2. Its QML chrome talks to the MC over the
shell's own connection and can be rearranged and themed from
`~/.config/hal-c2/shell/`.

Architecture, setup, and the QML/theme contracts: `docs/internals/desktop-qt.md`.

```sh
mise run mc         # terminal 1: the MC
mise run desktop    # terminal 2: build the shell, pair with the MC, launch
```

`mise run desktop -- --standalone` skips the pairing and lets the shell start its own MC,
as the installed app does.

Besides Qt Quick, the shell needs the Qt WebSockets module for its own MC
client: `qt6-websockets` on Arch and Fedora, `qt6-websockets-dev` on Debian and Ubuntu.
The Device tab decodes H.264 with FFmpeg's libavcodec, libavutil and libswscale. Building needs
only their headers, found through `pkg-config`: `ffmpeg` on Arch and Homebrew,
`libavcodec-dev libavutil-dev libswscale-dev` on Debian and Ubuntu, `ffmpeg-free-devel` (or
RPM Fusion's `ffmpeg-devel`) on Fedora. Nothing links or ships FFmpeg: the libraries load when a
Device tab first streams, at the major versions the headers name, so the app starts without them
and the tab says to install them. At run time that is `ffmpeg` on Debian, Ubuntu, Arch and
Homebrew, and RPM Fusion's `ffmpeg-libs` on Fedora (`ffmpeg-free` may lack H.264).

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
lists (`features/desktop/native-*.feature`, cluster, pairing, Connections settings and more)
against a fake MC, skipping `@backlog`,
`@backlog-desktop` and `@dropped`; `HAL_C2_FEATURES="threads/thread-list.feature"` narrows it.
Its steps live in `tests/native/features/`, one self-registering file per domain, each with its
own part of the fake MC (`FakeMc::Extension`).
`ShellRuntime` covers reload and theme ownership. `ShellExamples` loads all
the examples at 640, 1000, and 1400 pixels (including `glass-macos` on macOS), checking header text and dashboard
card bounds, long branch names, clipped icons, and scrolling to the last card. It uses a local
view-model fixture; no running server or pairing is needed.
